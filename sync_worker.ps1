param (
    [Parameter(Mandatory=$true, HelpMessage="Укажите папку в S3 (для корня введите пустые кавычки '')")]
    [AllowEmptyString()]
    [string]$S3Folder,

    [string]$MonitorPath = "\\10.0.22.248\1c_exchange\BatchPassToPrint\tst",
    [string]$FileMask = "*.json",

    [int]$LoopDelaySeconds = 15
)

# --- НАСТРОЙКИ ---
$FunctionUrl = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
$LogFile = Join-Path $MonitorPath "worker_log.txt"
$LockFile = Join-Path $MonitorPath "script.lock"

# Очистка URL и настройка безопасности
$CleanUrl = $FunctionUrl -replace '[^\x20-\x7E]', ''
$CleanUrl = $CleanUrl.Trim()

# Пропускать ошибки SSL и настраивать протоколы
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

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

# --- ПРОВЕРКА LOCK-ФАЙЛА ---
if (Test-Path $LockFile) {
    Write-Log "Скрипт уже запущен или заблокирован файлом $LockFile" "WARN"
    exit
}

try {
    if (!(Test-Path $MonitorPath)) { New-Item -ItemType Directory -Path $MonitorPath -Force | Out-Null }
    New-Item -Path $LockFile -ItemType File -Force | Out-Null
    Write-Log "Старт мониторинга (цикл $LoopDelaySeconds сек). Целевая папка в S3: '$S3Folder'"

    $Url = [Uri]$CleanUrl

    while ($true) {
        $Files = Get-ChildItem -Path $MonitorPath -Filter $FileMask

        if ($null -ne $Files -and $Files.Count -gt 0) {
            foreach ($File in $Files) {
                $OriginalName = $File.Name
                $BaseName = $File.BaseName
                $ProcessingFile = Join-Path $MonitorPath "$BaseName.processing"
                $UploadedFile = Join-Path $MonitorPath "$BaseName.uploaded"

                try {
                    # 1. Захват файла
                    Rename-Item -Path $File.FullName -NewName "$BaseName.processing" -ErrorAction Stop
                    Write-Log "Обработка: $OriginalName"

                    # 2. Подготовка тела запроса
                    $Payload = @{
                        file_name = $OriginalName
                        folder    = $S3Folder.Trim()
                    }
                    $JsonBody = $Payload | ConvertTo-Json -Compress

                    # 3. Запрос ссылки
                    Write-Log "Запрос ссылки загрузки для $OriginalName..."
                    $Response = Invoke-RestMethod -Method Post `
                                                 -Uri $Url `
                                                 -Body $JsonBody `
                                                 -ContentType "application/json; charset=utf-8" `
                                                 -UserAgent $UserAgent

                    $UploadUrl = $Response.upload_url

                    # 4. Загрузка в S3 с ретраями
                    $S3Headers = @{
                        "If-None-Match" = "*"
                    }

                    $MaxRetries = 3
                    $RetryCount = 0
                    $Success = $false

                    while (-not $Success -and $RetryCount -lt $MaxRetries) {
                        try {
                            Invoke-RestMethod -Method Put -Uri $UploadUrl -InFile $ProcessingFile -ContentType "application/octet-stream" -Headers $S3Headers -UserAgent $UserAgent
                            $Success = $true
                        } catch {
                            if ($_.Exception.InnerException -and $_.Exception.InnerException.Response -and $_.Exception.InnerException.Response.StatusCode -eq 412) {
                                throw "Файл уже существует в S3 (412 Precondition Failed)"
                            }

                            $RetryCount++
                            Write-Log "Попытка загрузки $RetryCount не удалась: $($_.Exception.Message). Ждем 2 сек..." "WARN"
                            Start-Sleep -Seconds 2
                        }
                    }

                    if (-not $Success) { throw "Не удалось загрузить файл после $MaxRetries попыток." }

                    # 5. Финализация
                    if (Test-Path $UploadedFile) { Remove-Item $UploadedFile -Force }
                    Rename-Item -Path $ProcessingFile -NewName "$BaseName.uploaded" -ErrorAction Stop
                    Write-Log "Успешно загружено: $OriginalName (S3 Key: $($Response.key))"

                } catch {
                    $ErrMsg = $_.Exception.Message
                    Write-Log "Ошибка при обработке $OriginalName : $ErrMsg" "ERROR"

                    if (Test-Path $ProcessingFile) {
                        try {
                            if ($ErrMsg -like "*412*") {
                                if (Test-Path $UploadedFile) { Remove-Item $UploadedFile -Force }
                                Rename-Item -Path $ProcessingFile -NewName "$BaseName.uploaded" -ErrorAction SilentlyContinue
                            } else {
                                Rename-Item -Path $ProcessingFile -NewName $OriginalName -ErrorAction SilentlyContinue
                            }
                        } catch {}
                    }
                }
            }
        }

        Start-Sleep -Seconds $LoopDelaySeconds
    }

} finally {
    if (Test-Path $LockFile) {
        Remove-Item $LockFile
        Write-Log "Завершение работы, lock-файл удален."
    }
}
