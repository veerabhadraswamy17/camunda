# Checks the story's acceptance criteria against the plan, with a mocked AWS provider.
#   cd camunda-infra && terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "221402696565" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:eu-west-2:221402696565:key/mock" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-west-2:221402696565:mock.fifo" }
  }
}

variables {
  environment         = "dev"
  queue_name          = "camunda-orchestrator-replay-queue"
  dlq_name            = "camunda-orchestrator-replay-dlq"
  expected_account_id = "221402696565"
  sns_topic_arn       = "arn:aws:sns:eu-west-2:221402696565:mae_apptracking_event_log.fifo"
  ops_alarm_topic_arn = "arn:aws:sns:eu-west-2:221402696565:ops-alerts"
  section_names       = ["S01", "S02", "S03", "S04", "S05", "S06", "S07", "S08", "S09", "S10", "S11", "S12", "S13", "S14"]
}

run "acceptance_criteria" {
  command = apply

  assert {
    condition     = module.replay_queue.queue_name == "camunda-orchestrator-replay-queue.fifo"
    error_message = "Queue name must be camunda-orchestrator-replay-queue.fifo."
  }

  assert {
    condition     = module.replay_queue.dlq_name == "camunda-orchestrator-replay-dlq.fifo"
    error_message = "DLQ name must be camunda-orchestrator-replay-dlq.fifo."
  }

  assert {
    condition     = module.replay_queue.queue_settings.max_receive_count == 3
    error_message = "maxReceiveCount must be 3."
  }

  assert {
    condition     = module.replay_queue.queue_settings.visibility_timeout_seconds >= 60 && module.replay_queue.queue_settings.message_retention_seconds == 345600
    error_message = "Visibility must be >= 60 s and retention 4 days."
  }

  assert {
    condition = (
      length(jsondecode(output.filter_policy)["section"]) == 14 &&
      jsondecode(output.filter_policy)["action"] == ["COMPLETED"]
    )
    error_message = "Filter policy must allow the 14 sections AND action COMPLETED."
  }

  assert {
    condition     = module.replay_queue.queue_settings.fifo_queue && module.replay_queue.queue_settings.content_based_deduplication
    error_message = "Queue must be FIFO with content-based deduplication."
  }

  assert {
    condition     = length(module.replay_queue.alarm_arns) == 1
    error_message = "Only the DLQ alarm should exist for this story."
  }
}

run "visibility_below_60_rejected" {
  command = plan

  variables {
    visibility_timeout_seconds = 30
  }

  expect_failures = [var.visibility_timeout_seconds]
}

run "standard_topic_rejected" {
  command = plan

  variables {
    sns_topic_arn = "arn:aws:sns:eu-west-2:221402696565:not-fifo"
  }

  expect_failures = [var.sns_topic_arn]
}
