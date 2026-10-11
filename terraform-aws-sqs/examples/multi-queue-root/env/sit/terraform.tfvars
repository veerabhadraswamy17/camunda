environment     = "sit"
alarm_topic_arn = null

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
