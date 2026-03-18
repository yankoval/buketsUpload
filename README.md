# buketsUpload

Get presigned links to bukets upload and get list of bukets to download.

## Настройка CI/CD для Yandex Cloud Functions

Этот репозиторий настроен на автоматический деплой функции `bukupl` в Yandex Cloud при пуше в ветку `main`.

### Предварительные требования

1.  **Workload Identity Federation**: В Yandex Cloud должна быть настроена федерация удостоверений для GitHub Actions (ID: `ajerpra4fh6o6p6kqe9e`).
2.  **Сервисный аккаунт для ДЕПЛОЯ**: Сервисный аккаунт, который связан с федерацией и имеет роль `functions.admin` в каталоге.
    *   **ID**: `aje3k28skhmb9e8eev6q`
3.  **Сервисный аккаунт для ВЫПОЛНЕНИЯ**: Сервисный аккаунт, от имени которого будет работать функция (для доступа к бакету).
    *   **ID**: `aje6tbttepr0ubr1aqdj`

### Настройка GitHub Secrets

Добавьте следующие секреты в настройках репозитория (**Settings -> Secrets and variables -> Actions**):

*   `YC_FOLDER_ID`: `b1g66di24cjhduu1tdoc`
*   `YC_DEPLOY_SA_ID`: `aje3k28skhmb9e8eev6q`
*   `YC_EXECUTION_SA_ID`: `aje6tbttepr0ubr1aqdj`
*   `YC_BUCKET_NAME`: `20ab2a0c-2726-4ba1-9c7c-7deae82941ff`

---

### Решение проблем

#### 1. Ошибка 401 (AxiosError: Request failed) при обмене токена
Проверьте настройки федерации `ajerpra4fh6o6p6kqe9e`:
*   **Issuer (Эмитент)**: должен быть `https://token.actions.githubusercontent.com`.
*   **Audiences**: должен содержать URL репозитория `https://github.com/<OWNER>/<REPO>`.
*   **Права доступа**: Аккаунту `aje3k28skhmb9e8eev6q` нужна роль `iam.workloadIdentityUser`.

**Команда для предоставления прав (через YC CLI):**
```bash
yc iam service-account add-access-binding aje3k28skhmb9e8eev6q \
    --role iam.workloadIdentityUser \
    --subject federation:ajerpra4fh6o6p6kqe9e:repo:<OWNER>/<REPO>:ref:refs/heads/main
```

#### 2. Ошибка "Service account is not available"
Если деплой падает с этой ошибкой при создании версии, значит аккаунт деплоя (`aje3k28skhmb9e8eev6q`) не имеет прав на использование аккаунта выполнения (`aje6tbttepr0ubr1aqdj`).

**Команда для исправления (через YC CLI):**
```bash
yc iam service-account add-access-binding aje6tbttepr0ubr1aqdj \
    --role iam.serviceAccounts.user \
    --subject serviceAccount:aje3k28skhmb9e8eev6q
```
*(Это позволит аккаунту деплоя назначать аккаунт выполнения на создаваемую функцию).*
