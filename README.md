# buketsUpload

Get presigned links to bukets upload and get list of bukets to download.

## Настройка CI/CD для Yandex Cloud Functions

Этот репозиторий настроен на автоматический деплой функции `bukupl` в Yandex Cloud при пуше в ветку `main`.

### Предварительные требования

1.  **Workload Identity Federation**: В Yandex Cloud должна быть настроена федерация удостоверений для GitHub Actions.
2.  **Сервисный аккаунт для деплоя**: Сервисный аккаунт, который связан с федерацией и имеет роль `functions.admin` в каталоге (ID: `ajerpra4fh6o6p6kqe9e`).

### Настройка GitHub Secrets

Для работы Workflow необходимо добавить следующие секреты в настройках репозитория (**Settings -> Secrets and variables -> Actions**):

1.  `YC_FOLDER_ID`: Идентификатор каталога Yandex Cloud (`b1g66di24cjhduu1tdoc`).
2.  `YC_DEPLOY_SA_ID`: Идентификатор сервисного аккаунта для деплоя, настроенного для федерации (`ajerpra4fh6o6p6kqe9e`).
3.  `YC_EXECUTION_SA_ID`: Идентификатор сервисного аккаунта, от имени которого будет работать функция (`aje3k28skhmb9e8eev6q`).
4.  `YC_BUCKET_NAME`: Имя бакета для генерации ссылок (`20ab2a0c-2726-4ba1-9c7c-7deae82941ff`).

### Параметры функции

*   **Имя функции**: `bukupl`
*   **Среда выполнения**: Python 3.12 (настроено в `.github/workflows/cd.yml`)
