################################################################################
# SNS -> SQS subscriptions (fan-out)
# The queue policy (policy.tf) and KMS key policy (kms.tf) already allow
# these topics to deliver. Created only for entries with create_subscription = true.
################################################################################

resource "aws_sns_topic_subscription" "this" {
  for_each = local.sns_subscriptions_to_create

  topic_arn            = each.value.topic_arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.this.arn
  raw_message_delivery = each.value.raw_message_delivery
  filter_policy        = each.value.filter_policy
  filter_policy_scope  = each.value.filter_policy != null ? each.value.filter_policy_scope : null

  # Create the subscription only after the queue policy allows SNS to deliver,
  # so the first messages are not silently dropped.
  depends_on = [aws_sqs_queue_policy.this]
}
