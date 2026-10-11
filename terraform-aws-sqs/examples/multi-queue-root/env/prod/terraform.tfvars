environment     = "prod"
alarm_topic_arn = "arn:aws:sns:eu-west-2:111111111111:prod-alerts"

common_tags = {
  owner               = "platform-team"
  cost-centre         = "CC1234"
  data-classification = "internal"
}

queues = {
  "connector-inbound" = {
    visibility_timeout_seconds = 120
  }
  "process-events" = {
    fifo_queue = true
  }
}
