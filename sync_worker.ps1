﻿param (
    [Parameter(Mandatory=$true)] [string]$S3Folder,
    [Parameter(Mandatory=$true)] [string]$MonitorPath,
    [Parameter(Mandatory=$true)] [string]$FileMask,
    [Parameter(Mandatory=$false)] [int]$LoopDelaySeconds = 0
)

# --- НАСТРОЙКИ ---
$FunctionUrl = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
$LogFile = Join-Path $MonitorPath "worker_log.txt"
$LockFile = Join-Path $MonitorPath "script.lock"

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
        if (!(Test-Path $MonitorPath)) { New-Item -ItemType Directory -Path $MonitorPath -Force | Out-Null }
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
    if ($LoopDelaySeconds -gt 0) {
        Write-Log "Старт мониторинга (цикл $LoopDelaySeconds сек). Целевая папка в S3: '$S3Folder'"
    } else {
        Write-Log "Однократный запуск. Целевая папка в S3: '$S3Folder'"
    }
    $Url = [Uri]$CleanUrl

    do {
        try {
            $Files = Get-ChildItem -Path $MonitorPath -Filter $FileMask

            if ($null -ne $Files -and $Files.Count -gt 0) {
                foreach ($File in $Files) {
                    $OriginalName = $File.Name
                    $BaseName = $File.BaseName
                    $ProcessingFile = Join-Path $MonitorPath "$BaseName.processing"
                    $UploadedFile = Join-Path $MonitorPath "$BaseName.uploaded"
                    $ErrorFile = Join-Path $MonitorPath "$BaseName.error"

                    try {
                        Rename-Item -Path $File.FullName -NewName "$BaseName.processing" -ErrorAction Stop
                        Write-Log "Обработка: $OriginalName"

                        $Payload = @{
                            file_name = $OriginalName
                            folder    = $S3Folder.Trim()
                        }
                        $JsonBody = $Payload | ConvertTo-Json -Compress

                        Write-Log "Запрос ссылки загрузки для $OriginalName..."
                        $Response = Invoke-RestMethod -Method Post `
                                                     -Uri $Url `
                                                     -Body $JsonBody `
                                                     -ContentType "application/json; charset=utf-8" `
                                                     -UserAgent $UserAgent

                        $UploadUrl = $Response.upload_url

                        $S3Headers = @{ "If-None-Match" = "*" }

                        $MaxRetries = 3
                        $RetryCount = 0
                        $Success = $false

                        while (-not $Success -and $RetryCount -lt $MaxRetries) {
                            try {
                                Invoke-RestMethod -Method Put -Uri $UploadUrl -InFile $ProcessingFile -ContentType "application/octet-stream" -Headers $S3Headers -UserAgent $UserAgent
                                $Success = $true
                            } catch {
                                # Проверка на 412 (уже есть в S3)
                                if ($_.Exception.InnerException -and $_.Exception.InnerException.Response -and $_.Exception.InnerException.Response.StatusCode -eq 412) {
                                    Write-Log "Файл уже существует в S3 (412 Precondition Failed). Переименование в .error" "WARN"
                                    if (Test-Path $ErrorFile) { Remove-Item $ErrorFile -Force }
                                    Rename-Item -Path $ProcessingFile -NewName "$BaseName.error" -ErrorAction Stop
                                    $Success = $true # Помечаем как "успех" чтобы выйти из цикла ретраев
                                    continue # Переходим к следующему файлу в foreach
                                }

                                $RetryCount++
                                $InnerMsg = ""
                                if ($_.Exception.InnerException) { $InnerMsg = " | Inner: " + $_.Exception.InnerException.Message }
                                Write-Log "Попытка загрузки $RetryCount не удалась: $($_.Exception.Message)$InnerMsg. Ждем 2 сек..." "WARN"
                                Start-Sleep -Seconds 2
                            }
                        }

                        if (-not $Success) { throw "Не удалось загрузить файл после $MaxRetries попыток." }

                        # Если файл все еще .processing (не был переименован в .error выше)
                        if (Test-Path $ProcessingFile) {
                            if (Test-Path $UploadedFile) { Remove-Item $UploadedFile -Force }
                            Rename-Item -Path $ProcessingFile -NewName "$BaseName.uploaded" -ErrorAction Stop
                            Write-Log "Успешно загружено: $OriginalName (S3 Key: $($Response.key))"
                        }

                    } catch {
                        $ErrMsg = $_.Exception.Message
                        if ($_.Exception.InnerException) { $ErrMsg += " | Inner: " + $_.Exception.InnerException.Message }
                        Write-Log "Ошибка при обработке $OriginalName : $ErrMsg" "ERROR"

                        if (Test-Path $ProcessingFile) {
                            try {
                                Rename-Item -Path $ProcessingFile -NewName $OriginalName -ErrorAction SilentlyContinue
                            } catch {}
                        }
                    }
                }
            }
        } catch {
            $ErrMsgMain = $_.Exception.Message
            if ($_.Exception.InnerException) { $ErrMsgMain += " | Inner: " + $_.Exception.InnerException.Message }
            Write-Log "Ошибка в основном цикле обработки: $ErrMsgMain" "ERROR"
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
