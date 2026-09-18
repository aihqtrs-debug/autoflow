"""AutoFlow pipeline - Transform step.
Converts the source file (XML/CSV/JSON) into a canonical JSON representation
and writes it to results/{user_id}/{job_id}/transformed.json.
"""
import csv
import io
import json
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


class TransformError(Exception):
    pass


def _xml_to_dict(elem):
    d = {"_tag": elem.tag}
    if elem.attrib:
        d["_attrib"] = dict(elem.attrib)
    children = list(elem)
    if children:
        d["children"] = [_xml_to_dict(c) for c in children]
    text = (elem.text or "").strip()
    if text:
        d["text"] = text
    return d


def _transform_xml(body):
    root = ET.fromstring(body)
    return _xml_to_dict(root)


def _transform_csv(body):
    text = body.decode("utf-8")
    reader = csv.DictReader(io.StringIO(text))
    return {"records": list(reader)}


def _transform_json(body):
    return json.loads(body)


TRANSFORMERS = {"xml": _transform_xml, "csv": _transform_csv, "json": _transform_json}


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
    bucket = event["bucket"]
    key = event["key"]
    user_id = event["user_id"]
    job_id = event["job_id"]
    file_type = event["file_type"]

    logger.info("Transforming s3://%s/%s (%s)", bucket, key, file_type)
    _update_job(user_id, job_id, status="RUNNING", stage="transform")

    transformer = TRANSFORMERS.get(file_type)
    if transformer is None:
        raise TransformError(f"no transformer for file type: {file_type}")

    obj = s3.get_object(Bucket=bucket, Key=key)
    body = obj["Body"].read()

    try:
        transformed = transformer(body)
    except Exception as e:
        raise TransformError(f"transform failed: {e}") from e

    result_key = f"results/{user_id}/{job_id}/transformed.json"
    s3.put_object(
        Bucket=bucket,
        Key=result_key,
        Body=json.dumps(transformed, indent=2).encode("utf-8"),
        ContentType="application/json",
    )

    _update_job(user_id, job_id, status="RUNNING", stage="transform", message="transform complete")

    event["transformed_key"] = result_key
    return event
