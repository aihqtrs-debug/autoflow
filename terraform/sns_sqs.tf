# -----------------------------------------------------------------------------
# Notifications: one topic for both success and failure emails.
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "notifications" {
  name = "${local.name_prefix}-notifications"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# -----------------------------------------------------------------------------
# Dead-letter queue: failed jobs land here for an operator to inspect or
# reprocess. 14-day retention is the max - plenty to investigate.
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name_prefix}-failed-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days
}
