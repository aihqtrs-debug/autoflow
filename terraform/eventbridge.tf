# -----------------------------------------------------------------------------
# The automation trigger: every file landing under incoming/ fires this rule,
# which starts a Step Functions execution. This is the "Control-M" piece -
# event-driven automation instead of anyone clicking a button.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "on_upload" {
  name = "${local.name_prefix}-on-upload"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.uploads.bucket] }
      object = { key = [{ prefix = "incoming/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "start_pipeline" {
  rule     = aws_cloudwatch_event_rule.on_upload.name
  arn      = aws_sfn_state_machine.pipeline.arn
  role_arn = aws_iam_role.eventbridge_start_execution.arn

  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = <<EOF
{
  "bucket": {"name": <bucket>},
  "object": {"key": <key>}
}
EOF
  }
}
