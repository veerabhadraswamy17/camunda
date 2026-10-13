module "replay_queue" {
  source = "../modules/sqs"

  application = "camunda"
  environment = var.environment

  # Names come from env/<env>/terraform.tfvars (.fifo suffix added by the module)
  queue_name = var.queue_name
  dlq_name   = var.dlq_name

  # FIFO: strict ordering per MessageGroupId (= applicationId, set by the publisher)
  fifo_queue                  = true
  content_based_deduplication = true # topic also has it on; an explicit dedup ID from the publisher still wins
  high_throughput_fifo        = false

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = 345600 # NFR: 4 days (default)

  # DLQ: camunda-orchestrator-replay-dlq.fifo, maxReceiveCount = 3
  create_dlq            = true
  dlq_max_receive_count = var.max_receive_count

  encryption_type = var.encryption_type
  kms_key_arn     = var.kms_key_arn

  # SNS subscription with raw delivery + filter policy.
  # The module adds the matching queue-policy and KMS key-policy statements for SNS.
  sns_subscriptions = {
    mae_apptracking = {
      topic_arn            = var.sns_topic_arn
      raw_message_delivery = true
      filter_policy        = local.filter_policy
      filter_policy_scope  = var.filter_policy_scope
    }
  }

  # Alarms: DLQ depth > 0 -> ops channel (story). Others only when enabled.
  create_alarms                        = true
  alarm_actions                        = [var.ops_alarm_topic_arn]
  ok_actions                           = [var.ops_alarm_topic_arn]
  dlq_messages_threshold               = 0
  oldest_message_age_threshold_seconds = var.enable_backlog_alarms ? 900 : null
  visible_messages_threshold           = var.enable_backlog_alarms ? 1000 : null

  # Enforce the story's tags instead of the module's default tag keys.
  required_tag_keys = ["team", "project"]
  tags              = local.tags
}
