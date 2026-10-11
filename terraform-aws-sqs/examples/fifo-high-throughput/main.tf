# FIFO queue with high-throughput mode and content-based deduplication.
# Name becomes: payments-prod-ledger-events.fifo (DLQ: ...-dlq.fifo)

provider "aws" {
  region = "eu-west-2"
}

module "ledger_events" {
  source = "../../"

  application = "payments"
  environment = "prod"
  name        = "ledger-events"

  fifo_queue                  = true
  high_throughput_fifo        = true
  content_based_deduplication = true

  # Bring your own key (e.g. a shared, centrally managed CMK).
  kms_key_arn = "arn:aws:kms:eu-west-2:111111111111:key/00000000-0000-0000-0000-000000000000"

  organization_id = "o-abcdefghij"

  oldest_message_age_threshold_seconds = 300
  alarm_actions                        = ["arn:aws:sns:eu-west-2:111111111111:payments-oncall"]

  tags = {
    owner               = "payments-team"
    cost-centre         = "CC9001"
    data-classification = "confidential"
  }
}
