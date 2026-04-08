param (
    [Parameter(Mandatory=$true)] [string]$S3Folder,
    [Parameter(Mandatory=$true)] [string]$LocalPath,
    [Parameter(Mandatory=$true)] [string[]]$FileMasks,
    [Parameter(Mandatory=$false)] [int]$LoopDelaySeconds = 0
)

# --- НАСТРОЙКИ ---
$FunctionUrl = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
$LogFile = Join-Path $LocalPath "download_worker_log.txt"
$LockFile = Join-Path $LocalPath "download_script.lock"

# Очистка URL и настройка безопасности
$CleanUrl = $FunctionUrl -replace '[^\x20-\x7E]', ''
$CleanUrl = $CleanUrl.Trim()

# --- SSL & TLS CONFIGURATION ---
$CsharpCode = @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy {
    public static bool Check(object sender, X509Certificate certificate, X509Chain chain, System.Net.Security.SslPolicyErrors sslPolicyErrors) {
        return true;
    }
    public static void SetPolicy() {
        ServicePointManager.ServerCertificateValidationCallback = Check;
    }
}
"@
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
    Add-Type -TypeDefinition $CsharpCode
}
[TrustAllCertsPolicy]::SetPolicy()

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

# --- Внутренняя функция скачивания ---
function Download-S3File($Item, $Url, $UserAgent) {
    $S3Key = $Item.name
    $FileName = $S3Key.Split('/')[-1]
    $TargetFile = Join-Path $LocalPath $FileName

    Write-Log "Скачивание файла: ${FileName} (S3 Key: $S3Key)"
    try {
        # 1. Установка статуса 'downloading'
        $BodySet = @{ set_tag = $S3Key; tag_key = "downloadStatus"; tag_value = "downloading" }
        Invoke-RestMethod -Method Post -Uri $Url -Body ($BodySet | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent | Out-Null

        # 2. Получение ссылки
        $BodyDown = @{ download = $S3Key }
        $DownloadResponse = Invoke-RestMethod -Method Post -Uri $Url -Body ($BodyDown | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent
        $DownloadUrl = $DownloadResponse.download_url
        if (!$DownloadUrl) { throw "API не вернуло ссылку на скачивание." }

        # 3. Физическое скачивание
        $MaxRetries = 3
        $RetryCount = 0
        $Success = $false
        while (-not $Success -and $RetryCount -lt $MaxRetries) {
            try {
                Invoke-WebRequest -Uri $DownloadUrl -OutFile $TargetFile -UserAgent $UserAgent -ErrorAction Stop
                $Success = $true
            } catch {
                $RetryCount++
                $InnerMsg = if ($_.Exception.InnerException) { " | Inner: " + $_.Exception.InnerException.Message } else { "" }
                Write-Log "Попытка $RetryCount не удалась для ${FileName}: $($_.Exception.Message)$InnerMsg" "WARN"
                Start-Sleep -Seconds 2
            }
        }
        if (-not $Success) { throw "Не удалось скачать файл после $MaxRetries попыток." }

        # 4. Установка статуса 'downloaded'
        $BodySetEnd = @{ set_tag = $S3Key; tag_key = "downloadStatus"; tag_value = "downloaded" }
        Invoke-RestMethod -Method Post -Uri $Url -Body ($BodySetEnd | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent | Out-Null

        Write-Log "Успешно скачано и статус обновлен: ${FileName}"
        return $true
    } catch {
        $ErrMsg = $_.Exception.Message
        if ($_.Exception.InnerException) { $ErrMsg += " | Inner: " + $_.Exception.InnerException.Message }
        Write-Log "Ошибка при скачивании ${FileName} : $ErrMsg" "ERROR"
        try {
            $BodyReset = @{ remove_tag = $S3Key; tag_key = "downloadStatus" }
            Invoke-RestMethod -Method Post -Uri $Url -Body ($BodyReset | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent | Out-Null
        } catch {}
        return $false
    }
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

# Функция извлечения UUID из имени файла
function Get-FileUuid($FileName) {
    if ($FileName -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        return $Matches[1]
    }
    return $null
}

try {
    if ($LoopDelaySeconds -gt 0) {
        Write-Log "Старт мониторинга S3 (цикл $LoopDelaySeconds сек). Папка: '$S3Folder'. Локальный путь: '$LocalPath'"
    } else {
        Write-Log "Однократный запуск S3. Папка: '$S3Folder'. Локальный путь: '$LocalPath'"
    }
    $Url = [Uri]$CleanUrl

    do {
        try {
            if (!(Test-Path $LocalPath)) { New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null }

            # 1. Получаем список файлов из S3
            $Body = @{ list = "true"; folder = $S3Folder.Trim() }
            $RawItems = Invoke-RestMethod -Method Post -Uri $Url -Body ($Body | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" -UserAgent $UserAgent

            if ($null -ne $RawItems) {
                $S3ItemsMap = @{}
                foreach ($item in $RawItems) { $S3ItemsMap[$item.name] = $item }

                $CsvUuidMap = @{}
                foreach ($item in $RawItems) {
                    if ($item.type -eq "file" -and $item.name.EndsWith(".csv", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $uuid = Get-FileUuid ($item.name.Split('/')[-1])
                        if ($uuid) { $CsvUuidMap[$uuid] = $item }
                    }
                }

                $SortedKeys = $S3ItemsMap.Keys | Sort-Object
                $MissingCsvUuidCache = @{}

                foreach ($S3Key in $SortedKeys) {
                    $Item = $S3ItemsMap[$S3Key]
                    if ($Item.type -ne "file") { continue }

                    $FileName = $S3Key.Split('/')[-1]
                    if ([string]::IsNullOrWhiteSpace($FileName)) { continue }

                    # 1. Фильтр по маске
                    $Match = $false
                    foreach ($Mask in $FileMasks) { if ($FileName -like $Mask) { $Match = $true; break } }
                    if (-not $Match) { continue }

                    # 2. Стандартная проверка тега (скипаем если уже скачано)
                    $DownloadStatus = if ($Item.tags -and $Item.tags.downloadStatus) { [string]$Item.tags.downloadStatus } else { $null }
                    if ($DownloadStatus -eq "downloaded" -or $DownloadStatus -eq "downloading") {
                        continue
                    }

                    # 3. Логика зависимостей: VDF требует наличия локального CSV (по UUID)
                    if ($FileName.EndsWith(".vdf", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $Uuid = Get-FileUuid $FileName
                        if ($Uuid) {
                            $LocalCsvs = Get-ChildItem -Path $LocalPath -Filter "*${Uuid}*.csv" -ErrorAction SilentlyContinue

                            if ($null -eq $LocalCsvs -or $LocalCsvs.Count -eq 0) {
                                if ($MissingCsvUuidCache.ContainsKey($Uuid)) { continue }

                                $CsvItem = $CsvUuidMap[$Uuid]
                                if ($CsvItem) {
                                    Write-Log "VDF ${FileName} требует CSV. Принудительное скачивание CSV с UUID ${Uuid}: $($CsvItem.name)"
                                    Download-S3File -Item $CsvItem -Url $Url -UserAgent $UserAgent | Out-Null
                                    # После скачивания CSV, статус локального файла изменился
                                } else {
                                    Write-Log "CSV файл для UUID ${Uuid} (VDF ${FileName}) не найден в S3! Пропуск." "WARN"
                                    $MissingCsvUuidCache[$Uuid] = $true
                                    continue
                                }

                                $LocalCsvsCheck = Get-ChildItem -Path $LocalPath -Filter "*${Uuid}*.csv" -ErrorAction SilentlyContinue
                                if ($null -eq $LocalCsvsCheck -or $LocalCsvsCheck.Count -eq 0) {
                                    Write-Log "Не удалось получить CSV для UUID ${Uuid}. Пропуск VDF ${FileName}." "WARN"
                                    continue
                                }
                            }
                        }
                    }

                    # Скачиваем основной файл
                    Download-S3File -Item $Item -Url $Url -UserAgent $UserAgent | Out-Null
                }
            }
        } catch {
            Write-Log "Ошибка в основном цикле скачивания: $($_.Exception.Message)" "ERROR"
        }

        if ($LoopDelaySeconds -gt 0) {
            Start-Sleep -Seconds $LoopDelaySeconds
        }
    } while ($LoopDelaySeconds -gt 0)

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
