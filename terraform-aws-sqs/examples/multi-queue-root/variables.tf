variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "environment" {
  type = string
}

variable "common_tags" {
  description = "Tags applied to every resource via provider default_tags and passed to the module."
  type        = map(string)
}

variable "alarm_topic_arn" {
  type    = string
  default = null
}

variable "queues" {
  description = "Queues to create. Key = queue purpose (used in the name)."
  type = map(object({
    fifo_queue                 = optional(bool, false)
    visibility_timeout_seconds = optional(number, 60)
    dlq_max_receive_count      = optional(number, 5)
    consumer_arns              = optional(list(string), [])
    producer_arns              = optional(list(string), [])
  }))
}
