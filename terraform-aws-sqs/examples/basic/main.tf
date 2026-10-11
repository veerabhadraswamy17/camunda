# Basic: standard queue for a Camunda connector, consumed by an ECS task role.
# Defaults give you: SSE-KMS (new CMK), DLQ (5 receives, 14-day retention),
# TLS-only policy, long polling and three CloudWatch alarms.

provider "aws" {
  region = "eu-west-2"
}

data "aws_iam_role" "camunda_task" {
  name = "camunda-ecs-task-role" # replace with your task role
}

module "camunda_jobs_queue" {
  source = "../../" # in real use: "git::https://<your-git>/terraform-aws-sqs.git?ref=v1.0.0"

  application = "camunda"
  environment = "dev"
  name        = "connector-jobs"

  visibility_timeout_seconds = 120 # > worst-case processing time

  alarm_actions = ["arn:aws:sns:eu-west-2:111111111111:platform-alerts"]

  tags = {
    owner               = "platform-team"
    cost-centre         = "CC1234"
    data-classification = "internal"
  }
}

# Give the ECS task role exactly the permissions it needs (incl. KMS decrypt).
resource "aws_iam_role_policy" "camunda_consume" {
  name   = "sqs-connector-jobs-consume"
  role   = data.aws_iam_role.camunda_task.id
  policy = module.camunda_jobs_queue.consumer_policy_json
}

output "queue_url" {
  value = module.camunda_jobs_queue.queue_url
}
