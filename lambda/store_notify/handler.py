"""AutoFlow pipeline - Store & notify step (final, on success).
Marks the job COMPLETE and publishes an SNS notification.
"""
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client("sns")
dynamodb = boto3.resource("dynamodb")
jobs_table = dynamodb.Table(os.environ["JOBS_TABLE"])
TOPIC_ARN = os.environ["NOTIFY_TOPIC_ARN"]


def handler(event, context):
    user_id = event["user_id"]
    job_id = event["job_id"]
    filename = event.get("filename", "unknown")

    now = datetime.now(timezone.utc).isoformat()
    jobs_table.update_item(
        Key={"user_id": user_id, "job_id": job_id},
        UpdateExpression="SET #status = :status, stage = :stage, message = :message, updated_at = :updated_at",
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":status": "COMPLETE",
            ":stage": "complete",
            ":message": "pipeline finished successfully",
            ":updated_at": now,
        },
    )

    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject=f"AutoFlow job complete: {filename}",
        Message=(
            f"Job {job_id} for user {user_id} completed successfully.\n"
            f"File: {filename}\n"
            f"Results: s3://{event.get('bucket')}/{event.get('transformed_key')}"
        ),
    )

    logger.info("Job %s/%s COMPLETE", user_id, job_id)
    event["status"] = "COMPLETE"
    return event
