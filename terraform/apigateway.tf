locals {
  api_functions = {
    get_upload_url = "../lambda/get_upload_url/handler.py"
    list_jobs       = "../lambda/list_jobs/handler.py"
  }
}

data "archive_file" "api" {
  for_each    = local.api_functions
  type        = "zip"
  source_file = "${path.module}/${each.value}"
  output_path = "${path.module}/build/${each.key}.zip"
}

resource "aws_lambda_function" "get_upload_url" {
  function_name    = "${local.name_prefix}-get-upload-url"
  role             = aws_iam_role.pipeline_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 10
  memory_size      = 128
  filename         = data.archive_file.api["get_upload_url"].output_path
  source_code_hash = data.archive_file.api["get_upload_url"].output_base64sha256
  tracing_config {
    mode = "Active"
  }
  environment {
    variables = { UPLOADS_BUCKET = aws_s3_bucket.uploads.bucket }
  }
}

resource "aws_lambda_function" "list_jobs" {
  function_name    = "${local.name_prefix}-list-jobs"
  role             = aws_iam_role.pipeline_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 10
  memory_size      = 128
  filename         = data.archive_file.api["list_jobs"].output_path
  source_code_hash = data.archive_file.api["list_jobs"].output_base64sha256
  tracing_config {
    mode = "Active"
  }
  environment {
    variables = { JOBS_TABLE = aws_dynamodb_table.jobs.name }
  }
}

resource "aws_cloudwatch_log_group" "api" {
  for_each          = local.api_functions
  name              = "/aws/lambda/${local.name_prefix}-${replace(each.key, "_", "-")}"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# HTTP API, protected by a Cognito JWT authorizer. CORS handled at the API
# level so the browser dashboard can call it directly.
# -----------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${local.name_prefix}-cognito-authorizer"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.users.id}"
  }
}

resource "aws_apigatewayv2_integration" "get_upload_url" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.get_upload_url.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_upload_url" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /upload-url"
  target             = "integrations/${aws_apigatewayv2_integration.get_upload_url.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_integration" "list_jobs" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.list_jobs.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "list_jobs" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /jobs"
  target             = "integrations/${aws_apigatewayv2_integration.list_jobs.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  # API governance: a sane default throttle so one client (or one bug) can't
  # exhaust the account's Lambda concurrency or run up an unexpected bill.
  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip              = "$context.identity.sourceIp"
      requestTime     = "$context.requestTime"
      httpMethod      = "$context.httpMethod"
      routeKey        = "$context.routeKey"
      status          = "$context.status"
      integrationErr  = "$context.integrationErrorMessage"
      responseLatency = "$context.responseLatency"
    })
  }
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name_prefix}-access-logs"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_resource_policy" "api_gateway" {
  policy_name = "${local.name_prefix}-apigw-logs-policy"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowAPIGatewayAccessLogging"
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.api_access.arn}:*"
    }]
  })
}

resource "aws_lambda_permission" "apigw_upload_url" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_upload_url.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_list_jobs" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.list_jobs.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
