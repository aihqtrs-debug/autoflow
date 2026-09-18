resource "aws_sfn_state_machine" "pipeline" {
  name     = "${local.name_prefix}-pipeline"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "AutoFlow: validate -> transform -> apply rules -> store & notify"
    StartAt = "Validate"
    States = {
      Validate = {
        Type     = "Task"
        Resource = aws_lambda_function.validate.arn
        Retry = [{
          ErrorEquals     = ["Lambda.TooManyRequestsException", "Lambda.ServiceException"]
          IntervalSeconds = 2
          MaxAttempts     = 2
          BackoffRate     = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "HandleFailure"
        }]
        Next = "Transform"
      }
      Transform = {
        Type     = "Task"
        Resource = aws_lambda_function.transform.arn
        Retry = [{
          ErrorEquals     = ["Lambda.TooManyRequestsException", "Lambda.ServiceException"]
          IntervalSeconds = 2
          MaxAttempts     = 2
          BackoffRate     = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "HandleFailure"
        }]
        Next = "ApplyRules"
      }
      ApplyRules = {
        Type     = "Task"
        Resource = aws_lambda_function.apply_rules.arn
        Retry = [{
          ErrorEquals     = ["Lambda.TooManyRequestsException", "Lambda.ServiceException"]
          IntervalSeconds = 2
          MaxAttempts     = 2
          BackoffRate     = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "HandleFailure"
        }]
        Next = "StoreAndNotify"
      }
      StoreAndNotify = {
        Type     = "Task"
        Resource = aws_lambda_function.store_notify.arn
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "HandleFailure"
        }]
        End = true
      }
      HandleFailure = {
        Type     = "Task"
        Resource = aws_lambda_function.handle_failure.arn
        End      = true
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
    include_execution_data = true
    level                   = "ALL"
  }

  tracing_configuration {
    enabled = true
  }
}

resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/vendedlogs/states/${local.name_prefix}-pipeline"
  retention_in_days = 14
}
