# Run with: terraform init && terraform test
# Uses a mocked AWS provider (Terraform >= 1.7): no credentials, nothing created.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:eu-west-2:111111111111:key/mock" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-west-2:111111111111:mock" }
  }
}

variables {
  application = "camunda"
  environment = "dev"
  name        = "jobs"
  tags = {
    owner               = "platform-team"
    cost-centre         = "CC1234"
    data-classification = "internal"
  }
}

run "secure_defaults" {
  command = apply

  assert {
    condition     = aws_sqs_queue.this.name == "camunda-dev-jobs"
    error_message = "Queue name does not follow <application>-<environment>-<name>."
  }

  assert {
    condition     = aws_sqs_queue.dlq[0].name == "camunda-dev-jobs-dlq"
    error_message = "DLQ should be created by default."
  }

  assert {
    condition     = length(aws_kms_key.this) == 1 && aws_kms_key.this[0].enable_key_rotation
    error_message = "A rotating customer-managed KMS key should be created by default."
  }

  assert {
    condition     = aws_sqs_queue.this.kms_master_key_id == aws_kms_key.this[0].arn
    error_message = "Queue must be encrypted with the module's KMS key."
  }

  assert {
    condition     = aws_sqs_queue.this.receive_wait_time_seconds == 20
    error_message = "Long polling should be on by default."
  }

  assert {
    condition     = length(aws_sqs_queue_policy.this) == 2
    error_message = "Both the queue and DLQ need a resource policy."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.dlq_messages) == 1
    error_message = "DLQ alarm should exist by default."
  }

  assert {
    condition     = aws_sqs_queue.this.tags["environment"] == "dev" && aws_sqs_queue.this.tags["managed-by"] == "terraform"
    error_message = "Standard tags are missing."
  }
}

run "fifo_high_throughput" {
  command = plan

  variables {
    fifo_queue           = true
    high_throughput_fifo = true
  }

  assert {
    condition     = aws_sqs_queue.this.name == "camunda-dev-jobs.fifo" && aws_sqs_queue.dlq[0].name == "camunda-dev-jobs-dlq.fifo"
    error_message = "FIFO suffix must be added to queue and DLQ."
  }

  assert {
    condition     = aws_sqs_queue.this.deduplication_scope == "messageGroup" && aws_sqs_queue.this.fifo_throughput_limit == "perMessageGroupId"
    error_message = "High-throughput FIFO settings not applied."
  }
}

run "sse_sqs_has_no_cmk" {
  command = plan

  variables {
    encryption_type = "sqs"
  }

  assert {
    condition     = length(aws_kms_key.this) == 0 && aws_sqs_queue.this.sqs_managed_sse_enabled == true
    error_message = "SSE-SQS should be used and no KMS key created."
  }
}

run "dlq_can_be_disabled" {
  command = plan

  variables {
    create_dlq = false
  }

  assert {
    condition     = length(aws_sqs_queue.dlq) == 0 && length(aws_sqs_queue_redrive_allow_policy.dlq) == 0 && length(aws_cloudwatch_metric_alarm.dlq_messages) == 0
    error_message = "No DLQ, redrive-allow policy or DLQ alarm expected."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "test"
  }

  expect_failures = [var.environment]
}

run "rejects_missing_required_tags" {
  command = plan

  variables {
    tags = { owner = "platform-team" }
  }

  expect_failures = [aws_sqs_queue.this]
}

run "rejects_short_dlq_retention" {
  command = plan

  variables {
    message_retention_seconds     = 1209600
    dlq_message_retention_seconds = 86400
  }

  expect_failures = [aws_sqs_queue.this]
}

run "fifo_queue_requires_fifo_topic" {
  command = plan

  variables {
    fifo_queue = true
    sns_subscriptions = {
      orders = { topic_arn = "arn:aws:sns:eu-west-2:111111111111:orders" }
    }
  }

  expect_failures = [aws_sqs_queue.this]
}
