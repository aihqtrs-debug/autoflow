"""AutoFlow API - POST /upload-url
Returns a presigned S3 PUT URL for the authenticated user to upload a file
directly from the browser, plus the job_id the pipeline will use.
"""
import json
import os
import uuid

import boto3

s3 = boto3.client("s3")
BUCKET = os.environ["UPLOADS_BUCKET"]

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Allow-Methods": "OPTIONS,POST,GET",
}


def handler(event, context):
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    user_id = claims["sub"]

    body = json.loads(event.get("body") or "{}")
    filename = body.get("filename", "upload.json")
    ext = os.path.splitext(filename)[1].lower()
    if ext not in (".xml", ".csv", ".json"):
        return {
            "statusCode": 400,
            "headers": CORS_HEADERS,
            "body": json.dumps({"error": "only .xml, .csv, .json files are supported"}),
        }

    job_id = str(uuid.uuid4())[:8]
    key = f"incoming/{user_id}/{job_id}/{filename}"

    url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": key},
        ExpiresIn=300,
    )

    return {
        "statusCode": 200,
        "headers": CORS_HEADERS,
        "body": json.dumps({"upload_url": url, "job_id": job_id, "key": key}),
    }
