# SNS fan-out: one "order-created" topic, separate queues per consuming service.
# Each queue gets its own DLQ, alarms and a policy that only accepts this topic.

provider "aws" {
  region = "eu-west-2"
}

resource "aws_sns_topic" "order_created" {
  name              = "orders-dev-order-created"
  kms_master_key_id = "alias/aws/sns"
}

module "consumer_queues" {
  source   = "../../"
  for_each = toset(["billing", "notifications", "audit"])

  application = "orders"
  environment = "dev"
  name        = "${each.key}-order-created"

  sns_subscriptions = {
    order_created = {
      topic_arn            = aws_sns_topic.order_created.arn
      raw_message_delivery = true
      # Only the audit service wants every event; others filter by region.
      filter_policy = each.key == "audit" ? null : jsonencode({ region = ["uk"] })
    }
  }

  tags = {
    owner               = "${each.key}-team"
    cost-centre         = "CC5555"
    data-classification = "internal"
  }
}

output "queue_urls" {
  value = { for k, m in module.consumer_queues : k => m.queue_url }
}
