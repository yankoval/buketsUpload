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

# Пропускать ошибки SSL
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

function Write-Log($Message, $Level = "INFO") {
    $Stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$Stamp - $Level - $Message"
    Write-Host $LogEntry -ForegroundColor ([ConsoleColor]::White)
    try {
        Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
    } catch {}
}

# --- ПРОВЕРКА LOCK-ФАЙЛА ---
if (Test-Path $LockFile) {
    Write-Log "Скрипт уже запущен или заблокирован файлом $LockFile" "WARN"
    exit
}

try {
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

            # 2. Подготовка тела запроса с принудительной кодировкой UTF-8
            $Payload = @{
                file_name = $OriginalName
                folder    = $S3Folder
            }
            # Преобразуем в JSON и затем В БАЙТЫ UTF-8
            $JsonString = $Payload | ConvertTo-Json -Compress
            $Utf8Body = [System.Text.Encoding]::UTF8.GetBytes($JsonString)

            # 3. Запрос ссылки (передаем байты вместо строки)
            $Response = Invoke-RestMethod -Method Post `
                                         -Uri $FunctionUrl `
                                         -Body $Utf8Body `
                                         -ContentType "application/json; charset=utf-8"
            $UploadUrl = $Response.upload_url

            # 4. Загрузка в S3 (здесь файл передается как поток байтов, кодировка не важна)
            # ВАЖНО: Добавляем заголовок If-None-Match для работы с новой логикой гарантированной загрузки
            $S3Headers = @{
                "If-None-Match" = "*"
            }
            Invoke-RestMethod -Method Put -Uri $UploadUrl -InFile $ProcessingFile -ContentType "application/json" -Headers $S3Headers

            # 5. Финализация
            if (Test-Path $UploadedFile) { Remove-Item $UploadedFile -Force } # Удаляем старый, если есть
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
