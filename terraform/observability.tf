# -----------------------------------------------------------------------------
# Observability: a single-pane-of-glass CloudWatch dashboard for the whole
# pipeline, plus alarms wired into the existing SNS topic so failures surface
# the same way a successful run does - nothing about "is this healthy right
# now" requires opening seven different console pages.
#
# X-Ray active tracing is enabled directly on each Lambda (lambda.tf,
# apigateway.tf) and on the Step Functions state machine (stepfunctions.tf),
# so the full request path - API Gateway -> Lambda -> EventBridge ->
# Step Functions -> Lambda x5 -> DynamoDB/SNS/SQS - is traceable end to end
# in the X-Ray console as a single service map.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-ops"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 1,
        properties = { markdown = "# AutoFlow — Operations Dashboard (${var.environment})" }
      },
      {
        type = "metric", x = 0, y = 1, width = 12, height = 6,
        properties = {
          title = "Pipeline Lambda invocations"
          view  = "timeSeries", stacked = false, region = var.aws_region, period = 300, stat = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.validate.function_name],
            ["...", aws_lambda_function.transform.function_name],
            ["...", aws_lambda_function.apply_rules.function_name],
            ["...", aws_lambda_function.store_notify.function_name],
            ["...", aws_lambda_function.handle_failure.function_name]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 1, width = 12, height = 6,
        properties = {
          title = "Pipeline Lambda errors"
          view  = "timeSeries", stacked = false, region = var.aws_region, period = 300, stat = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.validate.function_name],
            ["...", aws_lambda_function.transform.function_name],
            ["...", aws_lambda_function.apply_rules.function_name],
            ["...", aws_lambda_function.store_notify.function_name],
            ["...", aws_lambda_function.handle_failure.function_name]
          ]
          annotations = {
            horizontal = [{ label = "any error", value = 0 }]
          }
        }
      },
      {
        type = "metric", x = 0, y = 7, width = 12, height = 6,
        properties = {
          title = "Lambda p50 / p99 duration (ms)"
          view  = "timeSeries", stacked = false, region = var.aws_region, period = 300
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.validate.function_name, { stat = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.validate.function_name, { stat = "p99" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.transform.function_name, { stat = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.transform.function_name, { stat = "p99" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 7, width = 12, height = 6,
        properties = {
          title = "Step Functions executions"
          view  = "timeSeries", stacked = false, region = var.aws_region, period = 300, stat = "Sum"
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", aws_sfn_state_machine.pipeline.arn],
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.pipeline.arn],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.pipeline.arn]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 13, width = 8, height = 6,
        properties = {
          title = "DynamoDB consumed capacity"
          view  = "timeSeries", stacked = false, region = var.aws_region, period = 300, stat = "Sum"
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", aws_dynamodb_table.jobs.name],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.jobs.name]
          ]
        }
      },
      {
        type = "metric", x = 8, y = 13, width = 8, height = 6,
        properties = {
          title = "Dead-letter queue depth (failed jobs awaiting review)"
          view  = "timeSeries", stacked = false, region = var.aws_region, period = 300, stat = "Maximum"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.dlq.name]
          ]
        }
      },
      {
        type = "metric", x = 16, y = 13, width = 8, height = 6,
        properties = {
          title = "API Gateway requests / errors"
          view  = "timeSeries", stacked = false, region = var.aws_region, period = 300, stat = "Sum"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.main.id],
            ["AWS/ApiGateway", "4xx", "ApiId", aws_apigatewayv2_api.main.id],
            ["AWS/ApiGateway", "5xx", "ApiId", aws_apigatewayv2_api.main.id]
          ]
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Alarms -> the same SNS topic the pipeline already uses for job
# notifications, so "the system is unhealthy" reaches the same inbox as
# "your file finished processing."
# -----------------------------------------------------------------------------

# HandleFailure only ever runs when a Step Functions Catch fires - so any
# invocation of it *is* a pipeline failure signal, independent of which
# stage caused it.
resource "aws_cloudwatch_metric_alarm" "pipeline_failures" {
  alarm_name          = "${local.name_prefix}-pipeline-failures"
  alarm_description   = "Fires when the pipeline's HandleFailure state has run - i.e. at least one job failed."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.handle_failure.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.notifications.arn]
  ok_actions          = [aws_sns_topic.notifications.arn]
}

resource "aws_cloudwatch_metric_alarm" "stepfunctions_failed" {
  alarm_name          = "${local.name_prefix}-stepfunctions-failed-executions"
  alarm_description   = "Fires when a Step Functions execution fails outright (state machine definition error, not caught by our own Catch)."
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.pipeline.arn }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.notifications.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.name_prefix}-dlq-has-messages"
  alarm_description   = "Fires when failed jobs are sitting on the dead-letter queue awaiting review."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.notifications.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name_prefix}-api-5xx"
  alarm_description   = "Fires on server-side errors from the API - Lambda crashes, timeouts, or misconfiguration, not client mistakes."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.main.id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.notifications.arn]
}
