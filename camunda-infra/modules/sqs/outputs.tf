output "queue_name" {
  description = "Name of the main queue."
  value       = aws_sqs_queue.this.name
}

output "queue_arn" {
  description = "ARN of the main queue."
  value       = aws_sqs_queue.this.arn
}

output "queue_url" {
  description = "URL of the main queue (what SDKs and Camunda connectors use)."
  value       = aws_sqs_queue.this.id
}

output "dlq_name" {
  description = "Name of the dead-letter queue (null if disabled)."
  value       = try(aws_sqs_queue.dlq[0].name, null)
}

output "dlq_arn" {
  description = "ARN of the dead-letter queue (null if disabled)."
  value       = try(aws_sqs_queue.dlq[0].arn, null)
}

output "dlq_url" {
  description = "URL of the dead-letter queue (null if disabled)."
  value       = try(aws_sqs_queue.dlq[0].id, null)
}

output "kms_key_arn" {
  description = "KMS key used for encryption (null when encryption_type = \"sqs\")."
  value       = local.kms_enabled ? local.kms_key_arn : null
}

output "kms_alias_name" {
  description = "Alias of the module-created KMS key (null if an external key or SSE-SQS is used)."
  value       = try(aws_kms_alias.this[0].name, null)
}

output "producer_policy_json" {
  description = "IAM policy JSON granting send access (incl. KMS). Attach to producer roles."
  value       = data.aws_iam_policy_document.producer.json
}

output "consumer_policy_json" {
  description = "IAM policy JSON granting receive/delete on the queue and DLQ (incl. KMS). Attach to consumer roles, e.g. the ECS task role."
  value       = data.aws_iam_policy_document.consumer.json
}

output "sns_subscription_arns" {
  description = "Map of subscription key => SNS subscription ARN."
  value       = { for k, s in aws_sns_topic_subscription.this : k => s.arn }
}

output "alarm_arns" {
  description = "ARNs of the CloudWatch alarms created."
  value = compact([
    try(aws_cloudwatch_metric_alarm.oldest_message_age[0].arn, ""),
    try(aws_cloudwatch_metric_alarm.visible_messages[0].arn, ""),
    try(aws_cloudwatch_metric_alarm.dlq_messages[0].arn, ""),
  ])
}

output "queue_settings" {
  description = "Effective queue settings (for documentation, tests and acceptance evidence)."
  value = {
    fifo_queue                  = aws_sqs_queue.this.fifo_queue
    content_based_deduplication = aws_sqs_queue.this.content_based_deduplication
    visibility_timeout_seconds  = aws_sqs_queue.this.visibility_timeout_seconds
    message_retention_seconds   = aws_sqs_queue.this.message_retention_seconds
    max_receive_count           = var.create_dlq ? var.dlq_max_receive_count : null
    encryption                  = local.kms_enabled ? "SSE-KMS" : "SSE-SQS"
  }
}
