output "uploads_bucket" {
  value = aws_s3_bucket.uploads.bucket
}
output "frontend_bucket" {
  value = aws_s3_bucket.frontend.bucket
}
output "jobs_table" {
  value = aws_dynamodb_table.jobs.name
}
output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline.arn
}
output "notifications_topic_arn" {
  value = aws_sns_topic.notifications.arn
}
output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}
output "api_endpoint" {
  value = aws_apigatewayv2_api.main.api_endpoint
}
output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.users.id
}
output "cognito_client_id" {
  value = aws_cognito_user_pool_client.web.id
}
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.frontend.domain_name
}
output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
output "xray_console_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/xray/home?region=${var.aws_region}#/service-map"
}
output "cloudtrail_bucket" {
  value = aws_s3_bucket.cloudtrail.bucket
}
