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

    # Extract folder from query params or request body
    folder = query_params.get('folder', '')
    file_name = None
    
    if event.get('body'):
        try:
            body_str = event['body']
            if event.get('isBase64Encoded'):
                import base64
                body_str = base64.b64decode(body_str).decode('utf-8')

            body = json.loads(body_str)
            folder = body.get('folder', folder)
            file_name = body.get('file_name')
        except:
            pass

    # Normalize folder prefix:
    # 1. Strip leading slashes
    # 2. Ensure trailing slash if not empty
    prefix = folder.lstrip('/')
    if prefix and not prefix.endswith('/'):
        prefix += '/'

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
        # 1. List files and subfolders
        if 'list' in query_params:
            response = s3_client.list_objects_v2(
                Bucket=bucket,
                Prefix=prefix,
                Delimiter='/'
            )

            items = []
            if 'CommonPrefixes' in response:
                for cp in response['CommonPrefixes']:
                    items.append({
                        'name': cp['Prefix'],
                        'type': 'folder'
                    })

            if 'Contents' in response:
                for obj in response['Contents']:
                    if obj['Key'] == prefix:
                        continue
                    items.append({
                        'name': obj['Key'],
                        'type': 'file',
                        'size': obj['Size'],
                        'last_modified': obj['LastModified']
                    })

            return {
                'statusCode': 200,
                'headers': headers,
                'body': json.dumps(items, default=datetime_handler)
            }

        # 2. Get download URL
        if 'download' in query_params:
            key = query_params['download']
            url = s3_client.generate_presigned_url(
                'get_object',
                Params={
                    'Bucket': bucket,
                    'Key': key,
                    'ResponseContentDisposition': f'attachment; filename="{os.path.basename(key)}"'
                },
                ExpiresIn=3600
            )
            return {
                'statusCode': 200,
                'headers': headers,
                'body': json.dumps({'download_url': url})
            }

        # 3. Default: Generate upload URL
        # Check folder existence if provided
        if prefix:
            check_response = s3_client.list_objects_v2(
                Bucket=bucket,
                Prefix=prefix,
                MaxKeys=1
            )
            if 'Contents' not in check_response and 'CommonPrefixes' not in check_response:
                return {
                    'statusCode': 400,
                    'headers': headers,
                    'body': json.dumps({'error': f"Folder '{folder}' does not exist. Upload denied."})
                }

        # Determine final key
        final_file_name = file_name or str(uuid.uuid4())
        # Strip any leading slashes from the filename to avoid //
        final_file_name = final_file_name.lstrip('/')

        # Prepend prefix if not already part of the filename
        key = final_file_name
        if prefix and not key.startswith(prefix):
            key = prefix + key

        url = s3_client.generate_presigned_url(
            'put_object',
            Params={'Bucket': bucket, 'Key': key},
            ExpiresIn=3600
        )
        return {
            'statusCode': 200,
            'headers': headers,
            'body': json.dumps({'upload_url': url, 'key': key})
        }

    except Exception as e:
        return {
            'statusCode': 500,
            'headers': headers,
            'body': json.dumps({'error': str(e)})
        }
