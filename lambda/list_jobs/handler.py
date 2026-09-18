"""AutoFlow API - GET /jobs
Returns the authenticated user's job history, newest first.
"""
import json
import os

import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
jobs_table = dynamodb.Table(os.environ["JOBS_TABLE"])

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Allow-Methods": "OPTIONS,POST,GET",
}


def _decimal_default(o):
    return int(o) if o % 1 == 0 else float(o)


def handler(event, context):
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    user_id = claims["sub"]

    resp = jobs_table.query(
        KeyConditionExpression=Key("user_id").eq(user_id),
        ScanIndexForward=False,
        Limit=50,
    )
    items = resp.get("Items", [])

    return {
        "statusCode": 200,
        "headers": {**CORS_HEADERS, "Content-Type": "application/json"},
        "body": json.dumps(items, default=_decimal_default),
    }
