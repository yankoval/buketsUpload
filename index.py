import boto3
import os
import json
import uuid
from botocore.config import Config
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

def datetime_handler(x):
    if isinstance(x, datetime):
        return x.isoformat()
    raise TypeError("Unknown type")

def get_object_tags(s3_client, bucket, key):
    try:
        tagging = s3_client.get_object_tagging(Bucket=bucket, Key=key)
        return key, {t['Key']: t['Value'] for t in tagging.get('TagSet', [])}
    except Exception:
        return key, {}

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

    if event.get('httpMethod') == 'OPTIONS':
        return {'statusCode': 200, 'headers': headers, 'body': ''}

    if not bucket:
        return {
            'statusCode': 500,
            'headers': headers,
            'body': json.dumps({'error': "BUCKET_NAME environment variable is not set."})
        }

    method = event.get('httpMethod', 'GET')

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
        except Exception:
            pass

    try:
        folder = params.get('folder', '')
        file_name = params.get('file_name')
        prefix = str(folder or '').strip().lstrip('/')
        if prefix and not prefix.endswith('/'):
            prefix += '/'

        is_list = str(params.get('list', '')).lower() in ('true', '1', 't', 'yes', 'y')
        if is_list:
            paginator = s3_client.get_paginator('list_objects_v2')
            page_iterator = paginator.paginate(Bucket=bucket, Prefix=prefix, Delimiter='/')

            items = []
            folders = set()
            file_keys = []

            for page in page_iterator:
                if 'CommonPrefixes' in page:
                    for cp in page['CommonPrefixes']:
                        folders.add(cp['Prefix'])

                if 'Contents' in page:
                    for obj in page['Contents']:
                        if obj['Key'] == prefix:
                            continue
                        file_keys.append(obj)

            # Parallel tag fetching
            tags_map = {}
            with ThreadPoolExecutor(max_workers=10) as executor:
                futures = [executor.submit(get_object_tags, s3_client, bucket, obj['Key']) for obj in file_keys]
                for future in futures:
                    key, tags = future.result()
                    tags_map[key] = tags

            for obj in file_keys:
                items.append({
                    'name': obj['Key'],
                    'type': 'file',
                    'size': obj['Size'],
                    'last_modified': obj['LastModified'],
                    'tags': tags_map.get(obj['Key'], {})
                })

            final_items = [{'name': f, 'type': 'folder'} for f in sorted(list(folders))]
            final_items.extend(items)

            return {
                'statusCode': 200,
                'headers': headers,
                'body': json.dumps(final_items, default=datetime_handler)
            }

        if 'set_tag' in params:
            key = params['set_tag']
            tag_key = params.get('tag_key')
            tag_value = params.get('tag_value')
            if not tag_key or tag_value is None:
                return {'statusCode': 400, 'headers': headers, 'body': json.dumps({'error': "tag_key and tag_value required"})}

            tagging = s3_client.get_object_tagging(Bucket=bucket, Key=key)
            new_tag_set = [t for t in tagging.get('TagSet', []) if t['Key'] != tag_key]
            new_tag_set.append({'Key': tag_key, 'Value': str(tag_value)})
            s3_client.put_object_tagging(Bucket=bucket, Key=key, Tagging={'TagSet': new_tag_set})
            return {'statusCode': 200, 'headers': headers, 'body': json.dumps({'success': True})}

        if 'remove_tag' in params:
            key = params['remove_tag']
            tag_to_remove = params.get('tag_key')
            if not tag_to_remove:
                return {'statusCode': 400, 'headers': headers, 'body': json.dumps({'error': "tag_key required"})}

            tagging = s3_client.get_object_tagging(Bucket=bucket, Key=key)
            new_tag_set = [t for t in tagging.get('TagSet', []) if t['Key'] != tag_to_remove]
            s3_client.put_object_tagging(Bucket=bucket, Key=key, Tagging={'TagSet': new_tag_set})
            return {'statusCode': 200, 'headers': headers, 'body': json.dumps({'success': True})}

        if 'download' in params:
            key = params['download']
            import urllib.parse
            filename = os.path.basename(key)
            encoded_filename = urllib.parse.quote(filename)
            url = s3_client.generate_presigned_url(
                'get_object',
                Params={
                    'Bucket': bucket,
                    'Key': key,
                    'ResponseContentDisposition': f"attachment; filename=\"{encoded_filename}\"; filename*=UTF-8''{encoded_filename}"
                },
                ExpiresIn=3600
            )
            return {'statusCode': 200, 'headers': headers, 'body': json.dumps({'download_url': url})}

        if method == 'POST':
            if prefix:
                check_response = s3_client.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=1)
                if 'Contents' not in check_response and 'CommonPrefixes' not in check_response:
                    return {'statusCode': 400, 'headers': headers, 'body': json.dumps({'error': f"Folder '{folder}' not found"})}

            final_file_name = str(file_name or uuid.uuid4()).strip().lstrip('/')
            key = prefix + final_file_name if prefix and not final_file_name.startswith(prefix) else final_file_name
            url = s3_client.generate_presigned_url('put_object', Params={'Bucket': bucket, 'Key': key, 'IfNoneMatch': '*'}, ExpiresIn=3600)
            return {'statusCode': 200, 'headers': headers, 'body': json.dumps({'upload_url': url, 'key': key})}

        return {'statusCode': 405, 'headers': headers, 'body': json.dumps({'error': "Method not allowed"})}

    except Exception as e:
        return {'statusCode': 500, 'headers': headers, 'body': json.dumps({'error': str(e)})}
