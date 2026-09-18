"""AutoFlow pipeline - Failure handler (Step Functions Catch target).
Marks the job FAILED, publishes an SNS failure alert, and pushes the failed
job onto the SQS dead-letter queue for operator review/reprocessing.
"""
import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client("sns")
sqs = boto3.client("sqs")
dynamodb = boto3.resource("dynamodb")
jobs_table = dynamodb.Table(os.environ["JOBS_TABLE"])
TOPIC_ARN = os.environ["NOTIFY_TOPIC_ARN"]
DLQ_URL = os.environ["DLQ_URL"]


def handler(event, context):
    # Step Functions Catch wraps the original input under "error" plus the
    # last known state input; be defensive about what's present.
    user_id = event.get("user_id", "unknown")
    job_id = event.get("job_id", "unknown")
    error = event.get("error", {})
    error_message = json.dumps(error)[:500]

    now = datetime.now(timezone.utc).isoformat()
    try:
        jobs_table.update_item(
            Key={"user_id": user_id, "job_id": job_id},
            UpdateExpression="SET #status = :status, message = :message, updated_at = :updated_at",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":status": "FAILED",
                ":message": error_message,
                ":updated_at": now,
            },
        )
    except Exception:
        logger.exception("Could not update job status for %s/%s", user_id, job_id)

    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject=f"AutoFlow job FAILED: {job_id}",
        Message=f"Job {job_id} for user {user_id} failed.\nError: {error_message}",
    )

    sqs.send_message(
        QueueUrl=DLQ_URL,
        MessageBody=json.dumps({
            "user_id": user_id, "job_id": job_id, "error": error, "failed_at": now,
        }),
    )

    logger.info("Job %s/%s FAILED: %s", user_id, job_id, error_message)
    event["status"] = "FAILED"
    return event
