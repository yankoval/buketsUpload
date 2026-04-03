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

    # 1. Получаем список файлов из S3
    $Body = @{
        list = "true"
        folder = $S3Folder.Trim()
    }
    try {
        Write-Log "Запрос списка файлов из S3..."
        $Items = Invoke-RestMethod -Method Post -Uri $CleanUrl -Body ($Body | ConvertTo-Json) -ContentType "application/json; charset=utf-8"
    } catch {
        Write-Log "Ошибка получения списка файлов: $($_.Exception.Message)" "ERROR"
        exit
    }

    if ($null -eq $Items -or $Items.Count -eq 0) {
        Write-Log "Файлов в S3 не найдено."
        exit
    }

    foreach ($Item in $Items) {
        if ($Item.type -ne "file") { continue }

        $FileName = [System.IO.Path]::GetFileName($Item.name)
        $S3Key = $Item.name

        # 2. Фильтр по маске
        $Match = $false
        foreach ($Mask in $FileMasks) {
            if ($FileName -like $Mask) { $Match = $true; break }
        }
        if (-not $Match) { continue }

        # 3. Фильтр по тегам
        $DownloadStatus = $null
        if ($Item.tags -and $Item.tags.downloadStatus) {
            $DownloadStatus = $Item.tags.downloadStatus
        }

        if ($DownloadStatus -eq "downloaded" -or $DownloadStatus -eq "downloading") {
            continue
        }

        Write-Log "Найдено для скачивания: $FileName (S3 Key: $S3Key, Status: $($DownloadStatus -or 'None'))"

        try {
            # 4. Устанавливаем статус 'downloading'
            Write-Log "Установка статуса 'downloading'..."
            $BodySet = @{
                set_tag = $S3Key
                tag_key = "downloadStatus"
                tag_value = "downloading"
            }
            Invoke-RestMethod -Method Post -Uri $CleanUrl -Body ($BodySet | ConvertTo-Json) -ContentType "application/json; charset=utf-8" | Out-Null

            # 5. Получаем ссылку на скачивание
            Write-Log "Получение ссылки скачивания..."
            $BodyDown = @{
                download = $S3Key
            }
            $DownloadResponse = Invoke-RestMethod -Method Post -Uri $CleanUrl -Body ($BodyDown | ConvertTo-Json) -ContentType "application/json; charset=utf-8"
            $DownloadUrl = $DownloadResponse.download_url

            # 6. Скачиваем файл
            $TargetFile = Join-Path $LocalPath $FileName
            Write-Log "Скачивание файла..."
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $TargetFile
            Write-Log "Успешно скачано: $FileName"

            # 7. Устанавливаем статус 'downloaded'
            Write-Log "Установка статуса 'downloaded'..."
            $BodySetEnd = @{
                set_tag = $S3Key
                tag_key = "downloadStatus"
                tag_value = "downloaded"
            }
            Invoke-RestMethod -Method Post -Uri $CleanUrl -Body ($BodySetEnd | ConvertTo-Json) -ContentType "application/json; charset=utf-8" | Out-Null
            Write-Log "Статус обновлен на 'downloaded' для: $FileName"

        } catch {
            Write-Log "Ошибка при обработке $FileName : $($_.Exception.Message)" "ERROR"
            try {
                $BodyReset = @{
                    remove_tag = $S3Key
                    tag_key = "downloadStatus"
                }
                Invoke-RestMethod -Method Post -Uri $CleanUrl -Body ($BodyReset | ConvertTo-Json) -ContentType "application/json; charset=utf-8" | Out-Null
            } catch {}
        }
    }

} finally {
    if (Test-Path $LockFile) {
        Remove-Item $LockFile
        Write-Log "Завершение работы, lock-файл удален."
    }
}
