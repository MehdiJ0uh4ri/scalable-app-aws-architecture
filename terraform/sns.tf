# =============================================================================
# terraform/sns.tf
# Amazon SNS topics for CloudWatch alarm notifications.
# =============================================================================

resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = "alias/aws/sns" # Server-side encryption

  tags = {
    Name = "${local.name_prefix}-alerts"
  }
}

# Email subscription — confirm via email after deployment
resource "aws_sns_topic_subscription" "email_alert" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
