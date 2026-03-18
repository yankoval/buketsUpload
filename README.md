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

### Решение проблем (Ошибка 401 при обмене токена)

Если GitHub Action завершается с ошибкой `401: Request failed`, проверьте настройки в Yandex Cloud:

1.  **Настройки Федерации (`ajerpra4fh6o6p6kqe9e`)**:
    *   **Issuer (Эмитент)**: должен быть `https://token.actions.githubusercontent.com`.
    *   **Audiences**: должен содержать URL вашего репозитория `https://github.com/<OWNER>/<REPO>`.

2.  **Права доступа**:
    *   У сервисного аккаунта `aje3k28skhmb9e8eev6q` должна быть роль `iam.workloadIdentityUser` для федерации `ajerpra4fh6o6p6kqe9e`.

**Команда для предоставления прав (через YC CLI):**
```bash
yc iam service-account add-access-binding aje3k28skhmb9e8eev6q \
    --role iam.workloadIdentityUser \
    --subject federation:ajerpra4fh6o6p6kqe9e:repo:<OWNER>/<REPO>:ref:refs/heads/main
```
*(Замените `<OWNER>/<REPO>` на путь к вашему репозиторию в GitHub)*.
