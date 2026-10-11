locals {
  # Queues that get a resource policy. Keys are known at plan time.
  policy_targets = merge(
    { main = { arn = aws_sqs_queue.this.arn, url = aws_sqs_queue.this.id } },
    var.create_dlq ? { dlq = { arn = aws_sqs_queue.dlq[0].arn, url = aws_sqs_queue.dlq[0].id } } : {}
  )

  producer_actions = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
  consumer_actions = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:ChangeMessageVisibility",
    "sqs:GetQueueAttributes",
    "sqs:GetQueueUrl",
  ]
}

################################################################################
# Queue resource policies (main + DLQ)
################################################################################

data "aws_iam_policy_document" "queue" {
  for_each = local.policy_targets

  # Extra org-specific statements only apply to the main queue.
  source_policy_documents = each.key == "main" ? var.source_policy_documents : []

  # 1. Encryption in transit is mandatory.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # 2. Optional data perimeter: deny principals outside the organisation,
  #    but never block AWS service principals (SNS, EventBridge).
  dynamic "statement" {
    for_each = var.organization_id != null ? [1] : []
    content {
      sid       = "DenyOutsideOrganization"
      effect    = "Deny"
      actions   = ["sqs:*"]
      resources = [each.value.arn]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEqualsIfExists"
        variable = "aws:PrincipalOrgID"
        values   = [var.organization_id]
      }

      condition {
        test     = "BoolIfExists"
        variable = "aws:PrincipalIsAWSService"
        values   = ["false"]
      }
    }
  }

  # 3. Producers (main queue only).
  dynamic "statement" {
    for_each = each.key == "main" && length(var.producer_arns) > 0 ? [1] : []
    content {
      sid       = "AllowProducers"
      effect    = "Allow"
      actions   = local.producer_actions
      resources = [each.value.arn]

      principals {
        type        = "AWS"
        identifiers = var.producer_arns
      }
    }
  }

  # 4. Consumers (main queue and DLQ, so they can inspect/redrive failures).
  dynamic "statement" {
    for_each = length(var.consumer_arns) > 0 ? [1] : []
    content {
      sid       = "AllowConsumers"
      effect    = "Allow"
      actions   = local.consumer_actions
      resources = [each.value.arn]

      principals {
        type        = "AWS"
        identifiers = var.consumer_arns
      }
    }
  }

  # 5. SNS fan-out delivery, scoped to the exact topics.
  dynamic "statement" {
    for_each = each.key == "main" && length(local.sns_topic_arns) > 0 ? [1] : []
    content {
      sid       = "AllowSnsTopics"
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = [each.value.arn]

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

  # 6. EventBridge rule targets.
  dynamic "statement" {
    for_each = each.key == "main" && length(var.eventbridge_rule_arns) > 0 ? [1] : []
    content {
      sid       = "AllowEventBridgeRules"
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = [each.value.arn]

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

resource "aws_sqs_queue_policy" "this" {
  for_each = local.policy_targets

  queue_url = each.value.url
  policy    = data.aws_iam_policy_document.queue[each.key].json
}

################################################################################
# Identity policies for callers to attach to their own roles
# (e.g. the Camunda ECS task role). The module deliberately does not create
# roles: role ownership stays with the workload.
################################################################################

data "aws_iam_policy_document" "producer" {
  statement {
    sid       = "SendToQueue"
    effect    = "Allow"
    actions   = local.producer_actions
    resources = [aws_sqs_queue.this.arn]
  }

  dynamic "statement" {
    for_each = local.kms_enabled ? [1] : []
    content {
      sid       = "UseQueueKey"
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      resources = [local.kms_key_arn]
    }
  }
}

data "aws_iam_policy_document" "consumer" {
  statement {
    sid       = "ConsumeFromQueue"
    effect    = "Allow"
    actions   = local.consumer_actions
    resources = [for t in values(local.policy_targets) : t.arn]
  }

  dynamic "statement" {
    for_each = local.kms_enabled ? [1] : []
    content {
      sid       = "UseQueueKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [local.kms_key_arn]
    }
  }
}
