################################################################################
# CloudWatch alarms
# SQS publishes no logs; health is observed through these metrics.
################################################################################

locals {
  alarm_name_prefix = "sqs-${local.base_name}"
}

# Consumers are stuck, crashed or too slow.
resource "aws_cloudwatch_metric_alarm" "oldest_message_age" {
  count = var.create_alarms && var.oldest_message_age_threshold_seconds != null ? 1 : 0

  alarm_name          = "${local.alarm_name_prefix}-oldest-message-age"
  alarm_description   = "Oldest message in ${local.queue_name} is older than ${var.oldest_message_age_threshold_seconds}s. Check that consumers are running and keeping up."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.this.name }
  statistic           = "Maximum"
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.oldest_message_age_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.ok_actions

  tags = local.tags
}

# Backlog is building up.
resource "aws_cloudwatch_metric_alarm" "visible_messages" {
  count = var.create_alarms && var.visible_messages_threshold != null ? 1 : 0

  alarm_name          = "${local.alarm_name_prefix}-backlog"
  alarm_description   = "More than ${var.visible_messages_threshold} messages waiting in ${local.queue_name}."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.this.name }
  statistic           = "Maximum"
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.visible_messages_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.ok_actions

  tags = local.tags
}

# Any message in the DLQ means processing failed repeatedly. Most important alarm.
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  count = var.create_alarms && var.create_dlq ? 1 : 0

  alarm_name          = "${local.alarm_name_prefix}-dlq-not-empty"
  alarm_description   = "Messages in DLQ ${local.dlq_name}. Inspect the failures, fix the cause, then redrive to ${local.queue_name}."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq[0].name }
  statistic           = "Maximum"
  period              = var.alarm_period_seconds
  evaluation_periods  = 1
  threshold           = var.dlq_messages_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.ok_actions

  tags = local.tags
}
