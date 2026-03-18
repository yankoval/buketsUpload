import boto3
import os
import json
import uuid
from botocore.config import Config

def handler(event, context):
    # Теперь boto3 сам найдет ключи в переменных окружения
    s3_client = boto3.client(
        's3',
        endpoint_url='https://storage.yandexcloud.net',
        region_name='ru-central1',
        config=Config(signature_version='s3v4')
    )

    bucket = os.getenv('BUCKET_NAME')
    
    # Пытаемся достать имя файла из тела запроса (для Kotlin/Curl)
    file_name = f"{uuid.uuid4()}.pdf"
    if event.get('body'):
        try:
            body = json.loads(event['body'])
            file_name = body.get('file_name', file_name)
        except:
            pass

    try:
        url = s3_client.generate_presigned_url(
            'put_object',
            Params={'Bucket': bucket, 'Key': file_name},
            ExpiresIn=3600
        )
        return {
            'statusCode': 200,
            'body': json.dumps({'upload_url': url, 'key': file_name})
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }
