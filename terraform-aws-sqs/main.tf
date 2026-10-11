################################################################################
# Dead-letter queue (created first so the main queue can reference it)
################################################################################

resource "aws_sqs_queue" "dlq" {
  count = var.create_dlq ? 1 : 0

  name       = local.dlq_name
  fifo_queue = var.fifo_queue

  # DLQ keeps the same type & limits as the source queue.
  content_based_deduplication = var.fifo_queue ? var.content_based_deduplication : null
  deduplication_scope         = local.deduplication_scope
  fifo_throughput_limit       = local.fifo_throughput_limit

  message_retention_seconds  = var.dlq_message_retention_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds
  max_message_size           = var.max_message_size
  receive_wait_time_seconds  = var.receive_wait_time_seconds

  kms_master_key_id                 = local.kms_enabled ? local.kms_key_arn : null
  kms_data_key_reuse_period_seconds = local.kms_enabled ? var.kms_data_key_reuse_period_seconds : null
  sqs_managed_sse_enabled           = local.kms_enabled ? null : true

  tags = merge(local.tags, { queue-role = "dead-letter" })
}

################################################################################
# Main queue
################################################################################

resource "aws_sqs_queue" "this" {
  name       = local.queue_name
  fifo_queue = var.fifo_queue

  content_based_deduplication = var.fifo_queue ? var.content_based_deduplication : null
  deduplication_scope         = local.deduplication_scope
  fifo_throughput_limit       = local.fifo_throughput_limit

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  delay_seconds              = var.delay_seconds
  max_message_size           = var.max_message_size
  receive_wait_time_seconds  = var.receive_wait_time_seconds

  kms_master_key_id                 = local.kms_enabled ? local.kms_key_arn : null
  kms_data_key_reuse_period_seconds = local.kms_enabled ? var.kms_data_key_reuse_period_seconds : null
  sqs_managed_sse_enabled           = local.kms_enabled ? null : true

  redrive_policy = var.create_dlq ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[0].arn
    maxReceiveCount     = var.dlq_max_receive_count
  }) : null

  tags = merge(local.tags, { queue-role = "primary" })

  lifecycle {
    precondition {
      condition     = length(local.queue_name) <= 80 && length(local.dlq_name) <= 80
      error_message = "Queue name \"${local.dlq_name}\" exceeds the SQS limit of 80 characters. Shorten application/name."
    }

    precondition {
      condition     = length(local.missing_tag_keys) == 0
      error_message = "Missing required tags: ${join(", ", local.missing_tag_keys)}."
    }

    precondition {
      condition     = var.fifo_queue || (!var.content_based_deduplication && !var.high_throughput_fifo)
      error_message = "content_based_deduplication and high_throughput_fifo are only valid when fifo_queue = true."
    }

    precondition {
      condition     = !var.create_dlq || var.dlq_message_retention_seconds >= var.message_retention_seconds
      error_message = "dlq_message_retention_seconds must be >= message_retention_seconds, otherwise messages can expire as soon as they land in the DLQ."
    }

    precondition {
      condition     = !var.fifo_queue || alltrue([for arn in local.sns_topic_arns : endswith(arn, ".fifo")])
      error_message = "A FIFO queue can only subscribe to FIFO SNS topics (ARN ending in .fifo)."
    }
  }
}

################################################################################
# Only the main queue may move messages into this DLQ
################################################################################

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  count = var.create_dlq ? 1 : 0

  queue_url = aws_sqs_queue.dlq[0].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.this.arn]
  })
}
