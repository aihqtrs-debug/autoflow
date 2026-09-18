"""AutoFlow pipeline - Validate step.
Input:  {"bucket": {"name": str}, "object": {"key": str}}
Output: merged dict with is_valid/message, passed to the next state.
Raises ValidationError on a malformed file so Step Functions' Catch fires.
"""
import json
import csv
import io
import logging
import os
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
jobs_table = dynamodb.Table(os.environ["JOBS_TABLE"])


class ValidationError(Exception):
    pass


def _validate_xml(body):
    try:
        ET.fromstring(body)
        return True, "well-formed XML"
    except ET.ParseError as e:
        return False, f"invalid XML: {e}"


def _validate_json(body):
    try:
        json.loads(body)
        return True, "well-formed JSON"
    except json.JSONDecodeError as e:
        return False, f"invalid JSON: {e}"


def _validate_csv(body):
    try:
        text = body.decode("utf-8")
        rows = list(csv.reader(io.StringIO(text)))
        if not rows:
            return False, "empty CSV"
        width = len(rows[0])
        for i, row in enumerate(rows[1:], start=2):
            if len(row) != width:
                return False, f"row {i} has {len(row)} columns, expected {width}"
        return True, f"valid CSV: {len(rows)} rows, {width} columns"
    except Exception as e:
        return False, f"invalid CSV: {e}"


VALIDATORS = {".xml": _validate_xml, ".json": _validate_json, ".csv": _validate_csv}


def _update_job(user_id, job_id, **fields):
    now = datetime.now(timezone.utc).isoformat()
    expr_names = {f"#{k}": k for k in fields}
    expr_values = {f":{k}": v for k, v in fields.items()}
    expr_values[":updated_at"] = now
    set_clause = ", ".join(f"#{k} = :{k}" for k in fields) + ", updated_at = :updated_at"
    jobs_table.update_item(
        Key={"user_id": user_id, "job_id": job_id},
        UpdateExpression=f"SET {set_clause}",
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values,
    )


def handler(event, context):
    bucket = event["bucket"]["name"]
    key = event["object"]["key"]
    logger.info("Validating s3://%s/%s", bucket, key)

    parts = key.split("/")
    if len(parts) < 4:
        raise ValidationError(f"unexpected key shape: {key}")
    user_id, job_id, filename = parts[1], parts[2], parts[3]
    ext = os.path.splitext(filename)[1].lower()

    now = datetime.now(timezone.utc).isoformat()
    jobs_table.put_item(Item={
        "user_id": user_id, "job_id": job_id, "filename": filename,
        "file_type": ext.lstrip("."), "status": "RUNNING", "stage": "validate",
        "created_at": now, "updated_at": now,
    })

    validator = VALIDATORS.get(ext)
    obj = s3.get_object(Bucket=bucket, Key=key)
    body = obj["Body"].read()

    if validator is None:
        is_valid, message = False, f"unsupported file type: {ext or 'none'}"
    else:
        is_valid, message = validator(body)

    if not is_valid:
        _update_job(user_id, job_id, status="FAILED", stage="validate", message=message)
        raise ValidationError(message)

    _update_job(user_id, job_id, status="RUNNING", stage="validate", message=message)

    return {
        "bucket": bucket, "key": key, "user_id": user_id, "job_id": job_id,
        "filename": filename, "file_type": ext.lstrip("."),
        "is_valid": is_valid, "message": message, "size_bytes": len(body),
    }
