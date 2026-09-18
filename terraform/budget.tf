# -----------------------------------------------------------------------------
# Safety net: alerts (and, at the cap, an email) if account spend crosses
# these thresholds. Cheap insurance for a learning project on real AWS.
# -----------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly_cap" {
  name         = "${local.name_prefix}-monthly-cap"
  budget_type  = "COST"
  limit_amount = "10"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.notification_email == "" ? [] : [1]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.notification_email]
    }
  }

  dynamic "notification" {
    for_each = var.notification_email == "" ? [] : [1]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.notification_email]
    }
  }
}
