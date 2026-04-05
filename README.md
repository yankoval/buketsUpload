# buketsUpload

Get presigned links to bukets upload and get list of bukets to download.

## Настройка CI/CD для Yandex Cloud Functions

Этот репозиторий настроен на автоматический деплой функции `bukupl` в Yandex Cloud при пуше в ветку `main`.

### Предварительные требования

1.  **Workload Identity Federation**: В Yandex Cloud должна быть настроена федерация удостоверений для GitHub Actions.
2.  **Сервисный аккаунт для ДЕПЛОЯ**: Сервисный аккаунт, который связан с федерацией и имеет роль `functions.admin` в каталоге.
    *   **ID**: `aje3k28skhmb9e8eev6q`
3.  **Сервисный аккаунт для ВЫПОЛНЕНИЯ**: Сервисный аккаунт, от имени которого будет работать функция (для доступа к бакету).
    *   **ID**: `aje6tbttepr0ubr1aqdj`

### Настройка GitHub Secrets

Для работы Workflow необходимо добавить следующие секреты в настройках репозитория (**Settings -> Secrets and variables -> Actions**):

1.  `YC_FOLDER_ID`: Идентификатор каталога Yandex Cloud (`b1g66di24cjhduu1tdoc`).
2.  `YC_DEPLOY_SA_ID`: Идентификатор сервисного аккаунта для **деплоя** (`aje3k28skhmb9e8eev6q`).
3.  `YC_EXECUTION_SA_ID`: Идентификатор сервисного аккаунта для **выполнения** функции (`aje6tbttepr0ubr1aqdj`).
4.  `YC_BUCKET_NAME`: Имя бакета для генерации ссылок (`20ab2a0c-2726-4ba1-9c7c-7deae82941ff`).

### Параметры функции

*   **Имя функции**: `bukupl`
*   **Среда выполнения**: Python 3.12 (настроено в `.github/workflows/cd.yml`)
*   **URL функции**: `https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19`

## Примеры использования (Usage Examples)

Все примеры используют URL: `https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19`

### 1. Получение списка файлов и папок (List)

#### cURL
```bash
# Корень
curl "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19?list=true"

# Конкретная папка
curl "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19?list=true&folder=myfolder/"
```

#### Python
```python
import requests

url = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
params = {"list": "true", "folder": "docs/"}
response = requests.get(url, params=params)
print(response.json())
```

### 2. Скачивание файла (Download)

#### cURL
```bash
# 1. Получаем подписанную ссылку
DOWNLOAD_URL=$(curl -s "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19?download=docs/file.pdf" | jq -r .download_url)

# 2. Скачиваем файл
curl -L -o "downloaded_file.pdf" "$DOWNLOAD_URL"
```

#### Python
```python
import requests

url = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
# Получаем ссылку
response = requests.get(url, params={"download": "docs/file.pdf"})
download_url = response.json()["download_url"]

# Скачиваем
file_data = requests.get(download_url)
with open("downloaded_file.pdf", "wb") as f:
    f.write(file_data.content)
```

### 3. Загрузка файла (Upload)

*Примечание: Загрузка в папку разрешена только если папка уже существует. Реализована гарантированная однократная загрузка: если файл с таким именем уже существует, S3 вернет ошибку 412 Precondition Failed.*

**Важно:** При загрузке необходимо обязательно передавать заголовок `If-None-Match: *`.

#### cURL
```bash
# 1. Получаем ссылку для загрузки (передаем имя файла и папку в теле JSON)
UPLOAD_INFO=$(curl -s -X POST "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19" \
     -H "Content-Type: application/json" \
     -d '{"file_name": "test.txt", "folder": "uploads/"}')

UPLOAD_URL=$(echo $UPLOAD_INFO | jq -r .upload_url)

# 2. Загружаем файл с проверкой на существование
curl -X PUT -T "local_file.txt" -H "If-None-Match: *" "$UPLOAD_URL"
```

#### Python
```python
import requests

url = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
# 1. Получаем ссылку
payload = {"file_name": "test.txt", "folder": "uploads/"}
response = requests.post(url, json=payload)
upload_url = response.json()["upload_url"]

# 2. Загружаем с заголовком If-None-Match
with open("local_file.txt", "rb") as f:
    headers = {"If-None-Match": "*"}
    requests.put(upload_url, data=f, headers=headers)
```

### 4. Удаление тега объекта (Remove Tag)

#### cURL
```bash
# Удаление тега 'error' у файла 'docs/file.pdf'
curl -X POST "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19?remove_tag=docs/file.pdf&tag_key=error"
```

## Управление тегами и конфигурация (Tags Management)

При выводе списка файлов (`list=true`), функция автоматически возвращает теги для каждого объекта.

### Конфигурация разрешенных тегов

В веб-интерфейсе реализована возможность удаления тегов. Список тегов, которые разрешено удалять через UI, настраивается в файле `config/UI-conf.json` в самом бакете.

#### Пример `config/UI-conf.json`:
```json
{
  "allowed_delete_tags": ["error", "finished", "processed"]
}
```
Если файл отсутствует, по умолчанию разрешено удаление тегов `error` и `finished`.

## Веб-интерфейс (Browsing)

В репозитории есть файл `index.html`, который можно использовать как образец для создания веб-интерфейса.

Особенности:
- **Навигация**: Использует URL hash (`#folder=path/`) для навигации, что предотвращает ошибки доступа (AccessDenied) при обновлении страницы в статическом хостинге S3.
- **Загрузка**: Позволяет загружать файлы с защитой от перезаписи.
- **Теги**: Отображает теги объектов и позволяет удалять разрешенные теги (настраивается через `config/UI-conf.json`).
- **Скачивание**: Позволяет скачивать файлы в один клик.

## Скрипты синхронизации (PowerShell)

В репозитории доступны PowerShell скрипты для автоматической синхронизации локальных файлов с S3. Оба скрипта работают в бесконечном цикле (по умолчанию 15 секунд) и защищены lock-файлом от одновременного запуска.

### 1. `sync_worker.ps1` (Загрузка в S3)

Предназначен для мониторинга локальной папки и загрузки новых файлов в S3.
- **Логика**: Ищет файлы (например, `*.json`). При нахождении переименовывает файл в `.processing`, загружает в S3 с защитой от перезаписи (`If-None-Match: *`) и при успехе переименовывает в `.uploaded`.
- **Параметры**:
  - `S3Folder`: (Обязательно) Целевая папка в S3.
  - `MonitorPath`: Локальный путь для мониторинга (по умолчанию сетевой путь 1C).
  - `FileMask`: Маска файлов (по умолчанию `*.json`).
  - `LoopDelaySeconds`: Интервал проверки в секундах (по умолчанию 15).

### 2. `sync_worker_download.ps1` (Скачивание из S3)

Предназначен для скачивания файлов из S3 на основе их тегов.
- **Логика**: Ищет файлы в S3 по маске (например, `*.vdf`, `*.csv`). Скачивает только те файлы, у которых нет тега `downloadStatus` со значениями `downloaded` или `downloading`. Перед началом скачивания устанавливает тег `downloading`, после успешного завершения — `downloaded`.
- **Параметры**:
  - `S3Folder`: (Обязательно) Папка в S3 для сканирования.
  - `LocalPath`: Путь для сохранения файлов (по умолчанию `C:\Downloads\S3Sync`).
  - `FileMasks`: Массив масок (по умолчанию `*.vdf`, `*.csv`).
  - `LoopDelaySeconds`: Интервал проверки в секундах (по умолчанию 15).
