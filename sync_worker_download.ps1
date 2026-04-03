param (
    [Parameter(Mandatory=$true, HelpMessage="Укажите папку в S3 (например 'docs/')")]
    [string]$S3Folder,

    [string]$LocalPath = "C:\Downloads\S3Sync",
    [string[]]$FileMasks = @("*.vdf", "*.csv")
)

# --- НАСТРОЙКИ ---
$FunctionUrl = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
$LogFile = Join-Path $LocalPath "download_worker_log.txt"
$LockFile = Join-Path $LocalPath "download_script.lock"

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
        if (!(Test-Path $LocalPath)) { New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null }
        Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
    } catch {}
}

# --- ПРОВЕРКА LOCK-ФАЙЛА ---
if (Test-Path $LockFile) {
    Write-Log "Скрипт уже запущен или заблокирован файлом $LockFile" "WARN"
    exit
}

try {
    if (!(Test-Path $LocalPath)) { New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null }
    New-Item -Path $LockFile -ItemType File -Force | Out-Null
    Write-Log "Старт мониторинга S3. Папка: '$S3Folder'. Локальный путь: '$LocalPath'"

    $Url = [Uri]$CleanUrl

    # 1. Получаем список файлов из S3
    $Body = @{
        list = "true"
        folder = $S3Folder.Trim()
    }
    try {
        Write-Log "Запрос списка файлов из S3..."
        $RawItems = Invoke-RestMethod -Method Post -Uri $Url -Body ($Body | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8"
    } catch {
        Write-Log "Ошибка получения списка файлов: $($_.Exception.Message)" "ERROR"
        exit
    }

    if ($null -eq $RawItems) {
        Write-Log "Ответ от S3 пуст (null)."
        exit
    }

    # Обеспечиваем массив
    $Items = @($RawItems)
    Write-Log "Получено объектов из S3: $($Items.Count)"

    foreach ($Item in $Items) {
        $S3Key = $Item.name
        $Type = $Item.type

        Write-Log "Объект в S3: $S3Key (Тип: $Type)"

        if ($Type -ne "file") {
            continue
        }

        # Получаем имя файла (последняя часть после слеша)
        $FileName = $S3Key.Split('/')[-1]
        if ([string]::IsNullOrWhiteSpace($FileName)) {
            Write-Log "Не удалось извлечь имя файла из ключа $S3Key" "WARN"
            continue
        }

        # 2. Фильтр по маске
        $Match = $false
        foreach ($Mask in $FileMasks) {
            if ($FileName -like $Mask) { $Match = $true; break }
        }

        if (-not $Match) {
            Write-Log "Файл $FileName не соответствует маскам: $($FileMasks -join ', ')"
            continue
        }

        # 3. Фильтр по тегам
        $DownloadStatus = $null
        if ($Item.tags -and $Item.tags.downloadStatus) {
            $DownloadStatus = $Item.tags.downloadStatus
        }

        if ($DownloadStatus -eq "downloaded" -or $DownloadStatus -eq "downloading") {
            Write-Log "Файл $FileName уже в процессе или скачан (Статус: $DownloadStatus)"
            continue
        }

        Write-Log "Найдено для скачивания: $FileName (S3 Key: $S3Key, Текущий статус: $($DownloadStatus -or 'нет'))"

        try {
            # 4. Устанавливаем статус 'downloading'
            Write-Log "Установка статуса 'downloading' для $FileName..."
            $BodySet = @{
                set_tag = $S3Key
                tag_key = "downloadStatus"
                tag_value = "downloading"
            }
            Invoke-RestMethod -Method Post -Uri $Url -Body ($BodySet | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" | Out-Null

            # 5. Получаем ссылку на скачивание
            Write-Log "Получение ссылки скачивания для $FileName..."
            $BodyDown = @{
                download = $S3Key
            }
            $DownloadResponse = Invoke-RestMethod -Method Post -Uri $Url -Body ($BodyDown | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8"
            $DownloadUrl = $DownloadResponse.download_url

            if (!$DownloadUrl) {
                throw "API не вернуло ссылку на скачивание (download_url)."
            }

            # 6. Скачиваем файл
            $TargetFile = Join-Path $LocalPath $FileName
            Write-Log "Скачивание файла..."
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $TargetFile
            Write-Log "Успешно скачано в $TargetFile"

            # 7. Устанавливаем статус 'downloaded'
            Write-Log "Установка статуса 'downloaded' для $FileName..."
            $BodySetEnd = @{
                set_tag = $S3Key
                tag_key = "downloadStatus"
                tag_value = "downloaded"
            }
            Invoke-RestMethod -Method Post -Uri $Url -Body ($BodySetEnd | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" | Out-Null
            Write-Log "Статус успешно обновлен."

        } catch {
            Write-Log "Ошибка при обработке $FileName : $($_.Exception.Message)" "ERROR"
            try {
                # Сброс статуса для возможности повторной попытки
                $BodyReset = @{
                    remove_tag = $S3Key
                    tag_key = "downloadStatus"
                }
                Invoke-RestMethod -Method Post -Uri $Url -Body ($BodyReset | ConvertTo-Json -Compress) -ContentType "application/json; charset=utf-8" | Out-Null
            } catch {}
        }
    }

} finally {
    if (Test-Path $LockFile) {
        Remove-Item $LockFile
        Write-Log "Завершение работы, lock-файл удален."
    }
}
