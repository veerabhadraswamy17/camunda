################################################################################
# Customer-managed KMS key (only when encryption_type = "kms" and no key given)
################################################################################

data "aws_iam_policy_document" "kms" {
  count = local.create_kms_key ? 1 : 0

  # Delegate key access to IAM in this account (standard AWS default statement).
  # Producers/consumers then get KMS permissions via the producer/consumer
  # policy outputs attached to their roles.
  statement {
    sid       = "EnableIamPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # Cross-account producers/consumers named in the queue policy also need
  # the key; same-account principals are already covered above.
  dynamic "statement" {
    for_each = length(concat(var.producer_arns, var.consumer_arns)) > 0 ? [1] : []
    content {
      sid       = "AllowNamedQueuePrincipals"
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = distinct(concat(var.producer_arns, var.consumer_arns))
      }

      condition {
        # StringLike avoids the aws_region attribute rename between provider v5 and v6.
        test     = "StringLike"
        variable = "kms:ViaService"
        values   = ["sqs.*.amazonaws.com"]
      }
    }
  }

  # SNS must be able to encrypt messages it delivers into the queue.
  dynamic "statement" {
    for_each = length(local.sns_topic_arns) > 0 ? [1] : []
    content {
      sid       = "AllowSnsToUseKey"
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["sns.amazonaws.com"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:SourceArn"
        values   = local.sns_topic_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.eventbridge_rule_arns) > 0 ? [1] : []
    content {
      sid       = "AllowEventBridgeToUseKey"
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["events.amazonaws.com"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:SourceArn"
        values   = var.eventbridge_rule_arns
      }
    }
  }
}

resource "aws_kms_key" "this" {
  count = local.create_kms_key ? 1 : 0

  description             = "SSE key for SQS queue ${local.queue_name} (and its DLQ)"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_key_deletion_window_in_days
  policy                  = data.aws_iam_policy_document.kms[0].json

  tags = local.tags
}

resource "aws_kms_alias" "this" {
  count = local.create_kms_key ? 1 : 0

  # Alias names cannot contain dots, so strip the .fifo suffix.
  name          = "alias/sqs/${local.base_name}"
  target_key_id = aws_kms_key.this[0].key_id
}
