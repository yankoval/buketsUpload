import boto3
import json
import os
import uuid
from botocore.config import Config

# Настройки берутся из переменных окружения функции для безопасности
BUCKET_NAME = os.getenv('BUCKET_NAME')
# Используем Service Account для авторизации (рекомендуется)
# Если запускать внутри YC с привязанным сервисным аккаунтом, ключи не нужны

def handler(event, context):
    # Получаем имя файла из параметров запроса или генерируем UUID
    try:
        body = json.loads(event.get('body', '{}'))
        file_name = body.get('file_name', f"upload_{uuid.uuid4()}.pdf")
        content_type = body.get('content_type', 'application/pdf')
    except Exception:
        file_name = f"upload_{uuid.uuid4()}.pdf"
        content_type = 'application/pdf'

    # Настройка клиента S3
    s3_client = boto3.client(
        's3',
        endpoint_url='https://storage.yandexcloud.net',
        region_name='ru-central1',
        config=Config(signature_version='s3v4')
    )

    try:
        # Генерация URL для метода PUT
        url = s3_client.generate_presigned_url(
            'put_object',
            Params={
                'Bucket': BUCKET_NAME,
                'Key': file_name,
                'ContentType': content_type
            },
            ExpiresIn=600  # Ссылка живет 10 минут
        )
        
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'upload_url': url,
                'file_key': file_name
            })
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }
