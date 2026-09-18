"""AutoFlow pipeline - Apply business rules step.
Simple, explainable rules against the transformed JSON: not empty, and (for
CSV/XML-derived data) has at least one record/child. Real-world version
would load rules from a config table; kept simple here on purpose.
"""
import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
jobs_table = dynamodb.Table(os.environ["JOBS_TABLE"])


class RulesError(Exception):
    pass


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


def _check_rules(data, file_type):
    violations = []
    if file_type == "csv":
        records = data.get("records", [])
        if not records:
            violations.append("CSV has no data rows")
    elif file_type == "xml":
        if not data.get("children") and not data.get("text"):
            violations.append("XML root element has no content")
    elif file_type == "json":
        if data in (None, {}, []):
            violations.append("JSON document is empty")
    return violations


def handler(event, context):
    bucket = event["bucket"]
    user_id = event["user_id"]
    job_id = event["job_id"]
    file_type = event["file_type"]
    transformed_key = event["transformed_key"]

    logger.info("Applying rules to s3://%s/%s", bucket, transformed_key)
    _update_job(user_id, job_id, status="RUNNING", stage="apply_rules")

    obj = s3.get_object(Bucket=bucket, Key=transformed_key)
    data = json.loads(obj["Body"].read())

    violations = _check_rules(data, file_type)
    if violations:
        message = "; ".join(violations)
        _update_job(user_id, job_id, status="FAILED", stage="apply_rules", message=message)
        raise RulesError(message)

    _update_job(user_id, job_id, status="RUNNING", stage="apply_rules", message="all rules passed")

    event["rules_passed"] = True
    return event
