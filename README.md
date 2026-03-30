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

*Примечание: Загрузка в папку разрешена только если папка уже существует.*

#### cURL
```bash
# 1. Получаем ссылку для загрузки (передаем имя файла и папку в теле JSON)
UPLOAD_INFO=$(curl -s -X POST "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19" \
     -H "Content-Type: application/json" \
     -d '{"file_name": "test.txt", "folder": "uploads/"}')

UPLOAD_URL=$(echo $UPLOAD_INFO | jq -r .upload_url)

# 2. Загружаем файл
curl -X PUT -T "local_file.txt" "$UPLOAD_URL"
```

#### Python
```python
import requests

url = "https://functions.yandexcloud.net/d4e54fnlggbipdrp6c19"
# 1. Получаем ссылку
payload = {"file_name": "test.txt", "folder": "uploads/"}
response = requests.post(url, json=payload)
upload_url = response.json()["upload_url"]

# 2. Загружаем
with open("local_file.txt", "rb") as f:
    requests.put(upload_url, data=f)
```

## Веб-интерфейс (Browsing)

В репозитории есть файл `index.html`, который можно использовать как образец для создания веб-интерфейса. Он позволяет просматривать содержимое бакета, перемещаться по папкам и скачивать файлы в один клик.
