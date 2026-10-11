data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # ---- Naming ---------------------------------------------------------------
  base_name   = coalesce(var.name_override, "${var.application}-${var.environment}-${var.name}")
  fifo_suffix = var.fifo_queue ? ".fifo" : ""
  queue_name  = "${local.base_name}${local.fifo_suffix}"
  dlq_name    = "${local.base_name}-dlq${local.fifo_suffix}"

  # ---- Encryption -----------------------------------------------------------
  kms_enabled    = var.encryption_type == "kms"
  create_kms_key = local.kms_enabled && var.kms_key_arn == null
  kms_key_arn    = local.create_kms_key ? aws_kms_key.this[0].arn : var.kms_key_arn

  # ---- FIFO tuning (null for standard queues) -------------------------------
  deduplication_scope   = var.fifo_queue ? (var.high_throughput_fifo ? "messageGroup" : "queue") : null
  fifo_throughput_limit = var.fifo_queue ? (var.high_throughput_fifo ? "perMessageGroupId" : "perQueue") : null

  # ---- SNS ------------------------------------------------------------------
  sns_topic_arns = distinct([for s in values(var.sns_subscriptions) : s.topic_arn])
  sns_subscriptions_to_create = {
    for k, s in var.sns_subscriptions : k => s if s.create_subscription
  }

  # ---- Tags -----------------------------------------------------------------
  missing_tag_keys = [
    for k in var.required_tag_keys : k if trimspace(lookup(var.tags, k, "")) == ""
  ]

  tags = merge(
    var.tags,
    {
      application = var.application
      environment = var.environment
      managed-by  = "terraform"
      module      = "terraform-aws-sqs"
    }
  )
}
