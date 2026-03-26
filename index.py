import boto3
import os
import json
import uuid
from botocore.config import Config
from datetime import datetime

def datetime_handler(x):
    if isinstance(x, datetime):
        return x.isoformat()
    raise TypeError("Unknown type")

def handler(event, context):
    s3_client = boto3.client(
        's3',
        endpoint_url='https://storage.yandexcloud.net',
        region_name='ru-central1',
        config=Config(signature_version='s3v4')
    )

    bucket = os.getenv('BUCKET_NAME')
    query_params = event.get('queryStringParameters') or {}
    
    headers = {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'GET,POST,OPTIONS'
    }

    # Handle CORS preflight
    if event.get('httpMethod') == 'OPTIONS':
        return {
            'statusCode': 200,
            'headers': headers,
            'body': ''
        }

    try:
        # 1. List files
        if 'list' in query_params:
            response = s3_client.list_objects_v2(Bucket=bucket)
            files = []
            if 'Contents' in response:
                for obj in response['Contents']:
                    files.append({
                        'name': obj['Key'],
                        'size': obj['Size'],
                        'last_modified': obj['LastModified']
                    })
            return {
                'statusCode': 200,
                'headers': headers,
                'body': json.dumps(files, default=datetime_handler)
            }

        # 2. Get download URL
        if 'download' in query_params:
            file_name = query_params['download']
            url = s3_client.generate_presigned_url(
                'get_object',
                Params={
                    'Bucket': bucket,
                    'Key': file_name,
                    'ResponseContentDisposition': f'attachment; filename="{file_name}"'
                },
                ExpiresIn=3600
            )
            return {
                'statusCode': 200,
                'headers': headers,
                'body': json.dumps({'download_url': url})
            }

        # 3. Default: Generate upload URL
        file_name = str(uuid.uuid4())
        if event.get('body'):
            try:
                body_str = event['body']
                if event.get('isBase64Encoded'):
                    import base64
                    body_str = base64.b64decode(body_str).decode('utf-8')

                body = json.loads(body_str)
                file_name = body.get('file_name', file_name)
            except:
                pass

        url = s3_client.generate_presigned_url(
            'put_object',
            Params={'Bucket': bucket, 'Key': file_name},
            ExpiresIn=3600
        )
        return {
            'statusCode': 200,
            'headers': headers,
            'body': json.dumps({'upload_url': url, 'key': file_name})
        }

    except Exception as e:
        return {
            'statusCode': 500,
            'headers': headers,
            'body': json.dumps({'error': str(e)})
        }
