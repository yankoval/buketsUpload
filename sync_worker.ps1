param (
    [Parameter(Mandatory=$true, HelpMessage="Укажите папку в S3 (для корня введите пустые кавычки '')")]
    [AllowEmptyString()]
    [string]$S3Folder,

    [string]$MonitorPath = "\\10.0.22.248\1c_exchange\BatchPassToPrint\tst",
    [string]$FileMask = "*.json"
)

# --- НАСТРОЙКИ ---
$FunctionUrl = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
$LogFile = Join-Path $MonitorPath "worker_log.txt"
$LockFile = Join-Path $MonitorPath "script.lock"

# Очистка URL от возможных скрытых символов и пробелов
$CleanUrl = $FunctionUrl -replace '[^\x20-\x7E]', ''
$CleanUrl = $CleanUrl.Trim()

# Пропускать ошибки SSL и форсировать TLS 1.2
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
    Write-Log "Старт мониторинга. Целевая папка в S3: '$S3Folder'"

    $Files = Get-ChildItem -Path $MonitorPath -Filter $FileMask

    if ($null -eq $Files -or $Files.Count -eq 0) {
        Write-Log "Новых файлов для обработки нет."
        exit
    }

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
            Write-Log "Запрос ссылки загрузки..."
            $Response = Invoke-RestMethod -Method Post `
                                         -Uri $CleanUrl `
                                         -Body $JsonBody `
                                         -ContentType "application/json; charset=utf-8"

            $UploadUrl = $Response.upload_url

            # 4. Загрузка в S3
            $S3Headers = @{
                "If-None-Match" = "*"
            }
            Invoke-RestMethod -Method Put -Uri $UploadUrl -InFile $ProcessingFile -ContentType "application/json" -Headers $S3Headers

            # 5. Финализация
            if (Test-Path $UploadedFile) { Remove-Item $UploadedFile -Force }
            Rename-Item -Path $ProcessingFile -NewName "$BaseName.uploaded" -ErrorAction Stop
            Write-Log "Успешно загружено: $OriginalName (S3 Key: $($Response.key))"

        } catch {
            $ErrMsg = $_.Exception.Message
            if ($_.Exception.InnerException -and $_.Exception.InnerException.Response) {
                if ($_.Exception.InnerException.Response.StatusCode -eq 412) {
                    $ErrMsg = "Файл уже существует в S3 (412 Precondition Failed)"
                }
            }
            Write-Log "Ошибка при обработке $OriginalName : $ErrMsg" "ERROR"

            if (Test-Path $ProcessingFile) {
                try {
                    Rename-Item -Path $ProcessingFile -NewName $OriginalName -ErrorAction SilentlyContinue
                } catch {}
            }
        }
    }

} finally {
    if (Test-Path $LockFile) {
        Remove-Item $LockFile
        Write-Log "Завершение работы, lock-файл удален."
    }
}
