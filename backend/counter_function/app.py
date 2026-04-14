"""
app.py — Visitor counter Lambda handler

Atomically increments a counter in DynamoDB and returns the updated
value as JSON. Uses update_item with ADD to prevent race conditions
on concurrent requests.

Environment variables (set by SAM template.yaml):
    TABLE_NAME  — DynamoDB table name

DynamoDB item structure:
    { "id": "visitor_count", "count": <N> }

The item is created automatically on the first invocation — no manual
seeding is required. DynamoDB ADD on a non-existent attribute starts
from zero.
"""

import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ['TABLE_NAME']
COUNTER_ID = 'visitor_count'

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    """
    Increment the visitor counter and return the new count.

    Returns:
        dict: API Gateway proxy response with statusCode, headers, and body.
              body is JSON: {"count": <int>}
    """
    # Determine the allowed origin for CORS.
    # Set CORS_ORIGIN in the SAM template environment variables after
    # your CloudFront domain is known. Falls back to '*' for local testing.
    allowed_origin = os.environ.get('CORS_ORIGIN', '*')

    headers = {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': allowed_origin,
        'Access-Control-Allow-Methods': 'GET,OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
    }

    # Handle preflight OPTIONS request
    http_method = event.get('httpMethod', 'GET')
    if http_method == 'OPTIONS':
        return {'statusCode': 200, 'headers': headers, 'body': ''}

    try:
        response = table.update_item(
            Key={'id': COUNTER_ID},
            # ADD safely creates the attribute if it doesn't exist yet
            # (starts at 0 then adds 1), and increments atomically if it does.
            # 'count' is a DynamoDB reserved word, so ExpressionAttributeNames
            # is required to avoid a syntax error.
            UpdateExpression='ADD #count :increment',
            ExpressionAttributeNames={'#count': 'count'},
            ExpressionAttributeValues={':increment': 1},
            ReturnValues='UPDATED_NEW',
        )

        count = int(response['Attributes']['count'])
        logger.info('Visitor count incremented to %d', count)

        return {
            'statusCode': 200,
            'headers': headers,
            'body': json.dumps({'count': count}),
        }

    except ClientError as error:
        error_code = error.response['Error']['Code']
        logger.error('DynamoDB ClientError [%s]: %s', error_code, error)
        return {
            'statusCode': 500,
            'headers': headers,
            'body': json.dumps({'error': 'Failed to update visitor count'}),
        }

    except Exception as error:
        logger.error('Unexpected error: %s', error)
        return {
            'statusCode': 500,
            'headers': headers,
            'body': json.dumps({'error': 'Internal server error'}),
        }
