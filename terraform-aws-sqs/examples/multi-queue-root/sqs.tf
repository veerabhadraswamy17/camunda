module "sqs" {
  source   = "../../" # in real use: "git::https://<your-git>/terraform-aws-sqs.git?ref=v1.0.0"
  for_each = var.queues

  application = "camunda"
  environment = var.environment
  name        = each.key

  fifo_queue                 = each.value.fifo_queue
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  dlq_max_receive_count      = each.value.dlq_max_receive_count
  consumer_arns              = each.value.consumer_arns
  producer_arns              = each.value.producer_arns

  alarm_actions = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
  tags          = var.common_tags
}
