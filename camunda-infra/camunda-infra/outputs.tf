# Story: "Queue ARN, subscription ARN, and DLQ ARN documented"
output "queue_arn" {
  description = "ARN of camunda-orchestrator-replay-queue.fifo."
  value       = module.replay_queue.queue_arn
}

output "queue_url" {
  description = "URL the listener (S1-04) polls."
  value       = module.replay_queue.queue_url
}

output "dlq_arn" {
  description = "ARN of camunda-orchestrator-replay-dlq.fifo."
  value       = module.replay_queue.dlq_arn
}

output "dlq_url" {
  description = "URL of the DLQ (for inspection/redrive)."
  value       = module.replay_queue.dlq_url
}

output "subscription_arn" {
  description = "ARN of the mae_apptracking_event_log.fifo -> replay queue subscription."
  value       = module.replay_queue.sns_subscription_arns["mae_apptracking"]
}

output "kms_key_arn" {
  description = "KMS key encrypting the queue and DLQ."
  value       = module.replay_queue.kms_key_arn
}

output "dlq_alarm_arn" {
  description = "CloudWatch alarm on DLQ depth > 0."
  value       = module.replay_queue.alarm_arns
}

output "filter_policy" {
  description = "Filter policy applied to the subscription (for documentation)."
  value       = local.filter_policy
}

output "consumer_policy_json" {
  description = "IAM policy for the listener's task role (S1-04): receive/delete on queue + DLQ and kms:Decrypt."
  value       = module.replay_queue.consumer_policy_json
}

output "queue_settings" {
  description = "Effective queue settings (acceptance evidence)."
  value       = module.replay_queue.queue_settings
}
