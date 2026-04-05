param (
    [Parameter(Mandatory=$true, HelpMessage="Укажите папку в S3 (например 'docs/')")]
    [string]$S3Folder,

    [string]$LocalPath = "C:\Downloads\S3Sync",
    [string[]]$FileMasks = @("*.csv", "*.vdf"),

    [int]$LoopDelaySeconds = 15
)

# --- НАСТРОЙКИ ---
$FunctionUrl = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
$LogFile = Join-Path $LocalPath "download_worker_log.txt"
$LockFile = Join-Path $LocalPath "download_script.lock"

# Очистка URL и настройка безопасности
$CleanUrl = $FunctionUrl -replace '[^\x20-\x7E]', ''
$CleanUrl = $CleanUrl.Trim()

# --- SSL & TLS CONFIGURATION ---
# Используем C# для коллбэка SSL, чтобы избежать ошибки "No runspace" в многопоточных вызовах WebClient/WebRequest
$CsharpCode = @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy {
    public static bool Check(object sender, X509Certificate certificate, X509Chain chain, System.Net.Security.SslPolicyErrors sslPolicyErrors) {
        return true;
    }
}
"@
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
    Add-Type -TypeDefinition $CsharpCode
}
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = [System.Net.Security.RemoteCertificateValidationCallback]::new([TrustAllCertsPolicy]::Check)

[Net.SecurityProtocolType]$TlsProtocols = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
[Net.ServicePointManager]::SecurityProtocol = $TlsProtocols

$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"

function Write-Log($Message, $Level = "INFO") {
    $Stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$Stamp - $Level - $Message"
    Write-Host $LogEntry -ForegroundColor ([ConsoleColor]::White)
    try {
        if (!(Test-Path $LocalPath)) { New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null }
        Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
    } catch {}
}

# --- НАДЕЖНАЯ ПРОВЕРКА LOCK-ФАЙЛА ---
$LockStream = $null
try {
    if (Test-Path $LockFile) {
        Remove-Item $LockFile -ErrorAction SilentlyContinue
        if (Test-Path $LockFile) {
            Write-Log "Скрипт уже запущен (лок-файл $LockFile заблокирован другим процессом)." "WARN"
            exit
        }
    }
    $LockStream = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'Read', 'None')
} catch {
    Write-Log "Не удалось захватить лок-файл: $($_.Exception.Message). Возможно, скрипт уже запущен." "WARN"
    exit
}

try {
    Write-Log "Старт мониторинга S3 (цикл $LoopDelaySeconds сек). Папка: '$S3Folder'. Локальный путь: '$LocalPath'"
    $Url = [Uri]$CleanUrl

    while ($true) {
        try {
            if (!(Test-Path $LocalPath)) { New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null }

            $Body = @{
                list = "true"
                folder = $S3Folder.Trim()
            }
            $RawItems = Invoke-RestMethod -Method Post -Uri $Url -Body ($Body | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent

            if ($null -ne $RawItems) {
                $Items = @($RawItems)

                foreach ($Item in $Items) {
                    $S3Key = $Item.name
                    $Type = $Item.type

                    if ($Type -ne "file") { continue }

                    $FileName = $S3Key.Split('/')[-1]
                    if ([string]::IsNullOrWhiteSpace($FileName)) { continue }

                    $Match = $false
                    foreach ($Mask in $FileMasks) {
                        if ($FileName -like $Mask) { $Match = $true; break }
                    }
                    if (-not $Match) { continue }

                    if ($FileName.EndsWith(".vdf", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $BaseName = $FileName.Substring(0, $FileName.Length - 4)
                        $ExpectedCsv = Join-Path $LocalPath "$BaseName.csv"
                        if (-not (Test-Path $ExpectedCsv)) {
                            continue
                        }
                    }

                    $DownloadStatus = $null
                    if ($Item.tags -and $Item.tags.downloadStatus) {
                        $DownloadStatus = [string]$Item.tags.downloadStatus
                    }

                    if ($DownloadStatus -eq "downloaded" -or $DownloadStatus -eq "downloading") {
                        continue
                    }

                    Write-Log "Найдено для скачивания: $FileName (S3 Key: $S3Key, Статус: $($DownloadStatus -or 'нет'))"

                    try {
                        Write-Log "Установка статуса 'downloading' для $FileName..."
                        $BodySet = @{
                            set_tag = $S3Key
                            tag_key = "downloadStatus"
                            tag_value = "downloading"
                        }
                        Invoke-RestMethod -Method Post -Uri $Url -Body ($BodySet | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent | Out-Null

                        Write-Log "Получение ссылки скачивания для $FileName..."
                        $BodyDown = @{ download = $S3Key }
                        $DownloadResponse = Invoke-RestMethod -Method Post -Uri $Url -Body ($BodyDown | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent
                        $DownloadUrl = $DownloadResponse.download_url

                        if (!$DownloadUrl) { throw "API не вернуло ссылку на скачивание." }

                        $TargetFile = Join-Path $LocalPath $FileName
                        Write-Log "Скачивание файла в $TargetFile..."

                        $MaxRetries = 3
                        $RetryCount = 0
                        $Success = $false

                        while (-not $Success -and $RetryCount -lt $MaxRetries) {
                            try {
                                Invoke-WebRequest -Uri $DownloadUrl -OutFile $TargetFile -UserAgent $UserAgent -ErrorAction Stop
                                $Success = $true
                            } catch {
                                $RetryCount++
                                $InnerMsg = ""
                                if ($_.Exception.InnerException) { $InnerMsg = " | Inner: " + $_.Exception.InnerException.Message }
                                Write-Log "Попытка $RetryCount не удалась: $($_.Exception.Message)$InnerMsg. Ждем 2 сек..." "WARN"
                                Start-Sleep -Seconds 2
                            }
                        }

                        if (-not $Success) { throw "Не удалось скачать файл после $MaxRetries попыток." }

                        Write-Log "Успешно скачано: $FileName"

                        Write-Log "Установка статуса 'downloaded' для $FileName..."
                        $BodySetEnd = @{
                            set_tag = $S3Key
                            tag_key = "downloadStatus"
                            tag_value = "downloaded"
                        }
                        Invoke-RestMethod -Method Post -Uri $Url -Body ($BodySetEnd | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent | Out-Null
                        Write-Log "Статус обновлен."

                    } catch {
                        $ErrMsg = $_.Exception.Message
                        if ($_.Exception.InnerException) { $ErrMsg += " | Inner: " + $_.Exception.InnerException.Message }
                        Write-Log "Ошибка при обработке $FileName : $ErrMsg" "ERROR"
                        try {
                            $BodyReset = @{
                                remove_tag = $S3Key
                                tag_key = "downloadStatus"
                            }
                            Invoke-RestMethod -Method Post -Uri $Url -Body ($BodyReset | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent | Out-Null
                        } catch {}
                    }
                }
            }
        } catch {
            Write-Log "Ошибка в основном цикле скачивания: $($_.Exception.Message)" "ERROR"
        }

        Start-Sleep -Seconds $LoopDelaySeconds
    }

} finally {
    if ($null -ne $LockStream) {
        $LockStream.Close()
        $LockStream.Dispose()
    }
    if (Test-Path $LockFile) {
        Remove-Item $LockFile -ErrorAction SilentlyContinue
    }
    Write-Log "Скрипт завершил работу."
}
