locals {
  pipeline_functions = {
    validate      = "../lambda/validate/handler.py"
    transform     = "../lambda/transform/handler.py"
    apply_rules   = "../lambda/apply_rules/handler.py"
    store_notify  = "../lambda/store_notify/handler.py"
    handle_failure = "../lambda/handle_failure/handler.py"
  }
}

data "archive_file" "pipeline" {
  for_each    = local.pipeline_functions
  type        = "zip"
  source_file = "${path.module}/${each.value}"
  output_path = "${path.module}/build/${each.key}.zip"
}

resource "aws_lambda_function" "validate" {
  function_name    = "${local.name_prefix}-validate"
  role             = aws_iam_role.pipeline_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.pipeline["validate"].output_path
  source_code_hash = data.archive_file.pipeline["validate"].output_base64sha256
  tracing_config {
    mode = "Active"
  }
  environment {
    variables = { JOBS_TABLE = aws_dynamodb_table.jobs.name }
  }
}

resource "aws_lambda_function" "transform" {
  function_name    = "${local.name_prefix}-transform"
  role             = aws_iam_role.pipeline_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.pipeline["transform"].output_path
  source_code_hash = data.archive_file.pipeline["transform"].output_base64sha256
  tracing_config {
    mode = "Active"
  }
  environment {
    variables = { JOBS_TABLE = aws_dynamodb_table.jobs.name }
  }
}

resource "aws_lambda_function" "apply_rules" {
  function_name    = "${local.name_prefix}-apply-rules"
  role             = aws_iam_role.pipeline_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.pipeline["apply_rules"].output_path
  source_code_hash = data.archive_file.pipeline["apply_rules"].output_base64sha256
  tracing_config {
    mode = "Active"
  }
  environment {
    variables = { JOBS_TABLE = aws_dynamodb_table.jobs.name }
  }
}

resource "aws_lambda_function" "store_notify" {
  function_name    = "${local.name_prefix}-store-notify"
  role             = aws_iam_role.pipeline_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.pipeline["store_notify"].output_path
  source_code_hash = data.archive_file.pipeline["store_notify"].output_base64sha256
  tracing_config {
    mode = "Active"
  }
  environment {
    variables = {
      JOBS_TABLE       = aws_dynamodb_table.jobs.name
      NOTIFY_TOPIC_ARN = aws_sns_topic.notifications.arn
    }
  }
}

resource "aws_lambda_function" "handle_failure" {
  function_name    = "${local.name_prefix}-handle-failure"
  role             = aws_iam_role.pipeline_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.pipeline["handle_failure"].output_path
  source_code_hash = data.archive_file.pipeline["handle_failure"].output_base64sha256
  tracing_config {
    mode = "Active"
  }
  environment {
    variables = {
      JOBS_TABLE       = aws_dynamodb_table.jobs.name
      NOTIFY_TOPIC_ARN = aws_sns_topic.notifications.arn
      DLQ_URL          = aws_sqs_queue.dlq.url
    }
  }
}

resource "aws_cloudwatch_log_group" "pipeline" {
  for_each          = local.pipeline_functions
  name              = "/aws/lambda/${local.name_prefix}-${replace(each.key, "_", "-")}"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# S3 -> EventBridge: replaces the old direct S3 -> Lambda trigger now that
# Step Functions orchestrates the pipeline. EventBridge rule + target live in
# eventbridge.tf.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_notification" "uploads" {
  bucket      = aws_s3_bucket.uploads.id
  eventbridge = true
}
