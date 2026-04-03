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
        'Access-Control-Allow-Headers': 'Content-Type,If-None-Match',
        'Access-Control-Allow-Methods': 'GET,POST,OPTIONS,DELETE',
        'Access-Control-Expose-Headers': 'ETag'
    }

    # Handle CORS preflight
    if event.get('httpMethod') == 'OPTIONS':
        return {
            'statusCode': 200,
            'headers': headers,
            'body': ''
        }

    if not bucket:
        return {
            'statusCode': 500,
            'headers': headers,
            'body': json.dumps({'error': "BUCKET_NAME environment variable is not set."})
        }

    method = event.get('httpMethod', 'GET')

    # Combine all parameters from query string and JSON body
    params = query_params.copy()
    if event.get('body'):
        try:
            body_str = event['body']
            if event.get('isBase64Encoded'):
                import base64
                body_str = base64.b64decode(body_str).decode('utf-8')

            body = json.loads(body_str)
            if isinstance(body, dict):
                params.update(body)
        except Exception as e:
            # Fallback or silent ignore
            pass

    try:
        # Extract common parameters
        folder = params.get('folder', '')
        file_name = params.get('file_name')

        # Normalize folder prefix:
        # 1. Strip leading slashes and whitespace
        # 2. Ensure trailing slash if not empty
        prefix = str(folder or '').strip().lstrip('/')
        if prefix and not prefix.endswith('/'):
            prefix += '/'

        # 1. List files and subfolders
        is_list = str(params.get('list', '')).lower() in ('true', '1', 't', 'yes', 'y')
        if is_list:
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

                    # Fetch tags for each file
                    tagging = s3_client.get_object_tagging(Bucket=bucket, Key=obj['Key'])
                    tags = {t['Key']: t['Value'] for t in tagging.get('TagSet', [])}

                    items.append({
                        'name': obj['Key'],
                        'type': 'file',
                        'size': obj['Size'],
                        'last_modified': obj['LastModified'],
                        'tags': tags
                    })

            return {
                'statusCode': 200,
                'headers': headers,
                'body': json.dumps(items, default=datetime_handler)
            }

        # 2. Set/Update tag
        if 'set_tag' in params:
            key = params['set_tag']
            tag_key = params.get('tag_key')
            tag_value = params.get('tag_value')

            if not tag_key or tag_value is None:
                return {
                    'statusCode': 400,
                    'headers': headers,
                    'body': json.dumps({'error': "tag_key and tag_value parameters are required"})
                }

            tagging = s3_client.get_object_tagging(Bucket=bucket, Key=key)
            current_tags = tagging.get('TagSet', [])

            # Remove if already exists to update
            new_tag_set = [t for t in current_tags if t['Key'] != tag_key]
            new_tag_set.append({'Key': tag_key, 'Value': str(tag_value)})

            s3_client.put_object_tagging(
                Bucket=bucket,
                Key=key,
                Tagging={'TagSet': new_tag_set}
            )

            return {
                'statusCode': 200,
                'headers': headers,
                'body': json.dumps({'success': True, 'message': f"Tag '{tag_key}' set to '{tag_value}' for '{key}'"})
            }

        # 3. Remove tag
        if 'remove_tag' in params:
            key = params['remove_tag']
            tag_to_remove = params.get('tag_key')

            if not tag_to_remove:
                return {
                    'statusCode': 400,
                    'headers': headers,
                    'body': json.dumps({'error': "tag_key parameter is required"})
                }

            tagging = s3_client.get_object_tagging(Bucket=bucket, Key=key)
            current_tags = tagging.get('TagSet', [])
            new_tag_set = [t for t in current_tags if t['Key'] != tag_to_remove]

            s3_client.put_object_tagging(
                Bucket=bucket,
                Key=key,
                Tagging={'TagSet': new_tag_set}
            )

            return {
                'statusCode': 200,
                'headers': headers,
                'body': json.dumps({'success': True, 'message': f"Tag '{tag_to_remove}' removed from '{key}'"})
            }

        # 4. Get download URL
        if 'download' in params:
            key = params['download']
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

        # 5. Default: Generate upload URL (only for POST)
        if method == 'POST':
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
                        'body': json.dumps({
                            'error': f"Folder '{folder}' (normalized to '{prefix}') does not exist in bucket '{bucket}'. Upload denied.",
                            'hint': "Ensure the folder exists and you have provided the correct name."
                        })
                    }

            # Determine final key
            final_file_name = str(file_name or uuid.uuid4()).strip().lstrip('/')

            # Prepend prefix if not already part of the filename
            key = final_file_name
            if prefix and not key.startswith(prefix):
                key = prefix + key

            url = s3_client.generate_presigned_url(
                'put_object',
                Params={
                    'Bucket': bucket,
                    'Key': key,
                    'IfNoneMatch': '*'
                },
                ExpiresIn=3600
            )
            return {
                'statusCode': 200,
                'headers': headers,
                'body': json.dumps({'upload_url': url, 'key': key})
            }

        return {
            'statusCode': 405,
            'headers': headers,
            'body': json.dumps({'error': f"Method {method} not allowed or parameters missing"})
        }

    except Exception as e:
        return {
            'statusCode': 500,
            'headers': headers,
            'body': json.dumps({'error': str(e)})
        }
