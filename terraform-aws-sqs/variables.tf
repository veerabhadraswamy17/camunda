################################################################################
# Naming & tagging
################################################################################

variable "application" {
  description = "Application / product the queue belongs to (e.g. \"camunda\"). Used as the first part of the queue name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.application))
    error_message = "application must be 2-25 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment. Used in the queue name and tags."
  type        = string

  validation {
    condition     = contains(["dev", "sit", "uat", "preprod", "prod"], var.environment)
    error_message = "environment must be one of: dev, sit, uat, preprod, prod."
  }
}

variable "name" {
  description = "Purpose of the queue (e.g. \"order-events\"). Final name = <application>-<environment>-<name>[.fifo]."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,49}$", var.name))
    error_message = "name must be 1-50 chars, lowercase letters, digits and hyphens."
  }
}

variable "name_override" {
  description = "Use this exact queue name instead of the naming convention (without .fifo; the suffix is added automatically). Use only for importing legacy queues."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource. Must contain all keys listed in required_tag_keys."
  type        = map(string)
  default     = {}
}

variable "required_tag_keys" {
  description = "Tag keys that must be present (and non-empty) in var.tags. Align with your organisation's tagging policy."
  type        = list(string)
  default     = ["owner", "cost-centre", "data-classification"]
}

################################################################################
# Queue type & behaviour
################################################################################

variable "fifo_queue" {
  description = "Create a FIFO queue (exactly-once, ordered per message group). The .fifo suffix is added automatically."
  type        = bool
  default     = false
}

variable "content_based_deduplication" {
  description = "FIFO only. Use a SHA-256 hash of the body as the deduplication ID."
  type        = bool
  default     = false
}

variable "high_throughput_fifo" {
  description = "FIFO only. Enables high-throughput mode (dedup scope = messageGroup, throughput limit = perMessageGroupId)."
  type        = bool
  default     = false
}

variable "visibility_timeout_seconds" {
  description = "How long a received message stays hidden. Set it higher than the consumer's worst-case processing time (AWS suggests ~6x the Lambda timeout for Lambda consumers)."
  type        = number
  default     = 60

  validation {
    condition     = var.visibility_timeout_seconds >= 0 && var.visibility_timeout_seconds <= 43200
    error_message = "visibility_timeout_seconds must be between 0 and 43200 (12 hours)."
  }
}

variable "message_retention_seconds" {
  description = "How long SQS keeps an unconsumed message. Default 4 days."
  type        = number
  default     = 345600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 and 1209600 (14 days)."
  }
}

variable "delay_seconds" {
  description = "Delivery delay applied to every new message."
  type        = number
  default     = 0

  validation {
    condition     = var.delay_seconds >= 0 && var.delay_seconds <= 900
    error_message = "delay_seconds must be between 0 and 900."
  }
}

variable "max_message_size" {
  description = "Maximum message size in bytes. 262144 (256 KiB) is the long-standing default; newer AWS provider versions accept up to 1048576 (1 MiB)."
  type        = number
  default     = 262144

  validation {
    condition     = var.max_message_size >= 1024 && var.max_message_size <= 1048576
    error_message = "max_message_size must be between 1024 and 1048576 bytes."
  }
}

variable "receive_wait_time_seconds" {
  description = "Long-polling wait time. 20 (the max) reduces empty receives and cost."
  type        = number
  default     = 20

  validation {
    condition     = var.receive_wait_time_seconds >= 0 && var.receive_wait_time_seconds <= 20
    error_message = "receive_wait_time_seconds must be between 0 and 20."
  }
}

################################################################################
# Dead-letter queue
################################################################################

variable "create_dlq" {
  description = "Create a dead-letter queue and attach a redrive policy. Strongly recommended; disable only with a documented reason."
  type        = bool
  default     = true
}

variable "dlq_max_receive_count" {
  description = "Number of receives before a message is moved to the DLQ."
  type        = number
  default     = 5

  validation {
    condition     = var.dlq_max_receive_count >= 1 && var.dlq_max_receive_count <= 1000
    error_message = "dlq_max_receive_count must be between 1 and 1000."
  }
}

variable "dlq_message_retention_seconds" {
  description = "Retention on the DLQ. Must be >= the main queue's retention (for standard queues the original enqueue time is kept when a message moves to the DLQ). Default 14 days."
  type        = number
  default     = 1209600

  validation {
    condition     = var.dlq_message_retention_seconds >= 60 && var.dlq_message_retention_seconds <= 1209600
    error_message = "dlq_message_retention_seconds must be between 60 and 1209600."
  }
}

################################################################################
# Encryption
################################################################################

variable "encryption_type" {
  description = "\"kms\" = SSE-KMS with a customer-managed key (default, recommended). \"sqs\" = SSE-SQS (AWS-owned key) for low-sensitivity data. Unencrypted queues are not supported."
  type        = string
  default     = "kms"

  validation {
    condition     = contains(["kms", "sqs"], var.encryption_type)
    error_message = "encryption_type must be \"kms\" or \"sqs\"."
  }
}

variable "kms_key_arn" {
  description = "Existing customer-managed KMS key ARN. If null and encryption_type = \"kms\", the module creates a dedicated key. An external key's policy must allow your producers/consumers and any SNS/EventBridge publishers."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias name or key ID)."
  }
}

variable "kms_data_key_reuse_period_seconds" {
  description = "How long SQS reuses a data key before calling KMS again. Higher = fewer KMS calls/lower cost."
  type        = number
  default     = 300

  validation {
    condition     = var.kms_data_key_reuse_period_seconds >= 60 && var.kms_data_key_reuse_period_seconds <= 86400
    error_message = "kms_data_key_reuse_period_seconds must be between 60 and 86400."
  }
}

variable "kms_key_deletion_window_in_days" {
  description = "Waiting period before a module-created KMS key is deleted."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_in_days >= 7 && var.kms_key_deletion_window_in_days <= 30
    error_message = "kms_key_deletion_window_in_days must be between 7 and 30."
  }
}

################################################################################
# Access control
################################################################################

variable "producer_arns" {
  description = "IAM role/user ARNs allowed to send to the queue (granted in the queue policy; needed for cross-account access). Same-account principals can instead attach the producer_policy_json output."
  type        = list(string)
  default     = []
}

variable "consumer_arns" {
  description = "IAM role/user ARNs allowed to receive/delete from the queue and its DLQ."
  type        = list(string)
  default     = []
}

variable "organization_id" {
  description = "AWS Organizations ID (o-xxxxxxxxxx). When set, any non-AWS-service principal outside the org is explicitly denied."
  type        = string
  default     = null

  validation {
    condition     = var.organization_id == null || can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must look like o-xxxxxxxxxx."
  }
}

variable "eventbridge_rule_arns" {
  description = "EventBridge rule ARNs allowed to send to the queue."
  type        = list(string)
  default     = []
}

variable "source_policy_documents" {
  description = "Extra IAM policy JSON documents merged into the main queue's policy (escape hatch for org-specific statements)."
  type        = list(string)
  default     = []
}

################################################################################
# SNS fan-out subscriptions
################################################################################

variable "sns_subscriptions" {
  description = <<-EOT
    SNS topics this queue subscribes to. Key = logical name. The queue policy and
    (module-created) KMS key policy automatically allow these topics to deliver.
    Subscriptions must be created in the topic's account; for cross-account topics
    set create_subscription = false and create the subscription on the topic side.
  EOT
  type = map(object({
    topic_arn            = string
    raw_message_delivery = optional(bool, true)
    filter_policy        = optional(string)                      # JSON string
    filter_policy_scope  = optional(string, "MessageAttributes") # or "MessageBody"
    create_subscription  = optional(bool, true)
  }))
  default = {}

  validation {
    condition = alltrue([
      for s in values(var.sns_subscriptions) : can(regex("^arn:aws[a-z-]*:sns:", s.topic_arn))
    ])
    error_message = "Every sns_subscriptions[*].topic_arn must be an SNS topic ARN."
  }

  validation {
    condition = alltrue([
      for s in values(var.sns_subscriptions) : contains(["MessageAttributes", "MessageBody"], s.filter_policy_scope)
    ])
    error_message = "filter_policy_scope must be \"MessageAttributes\" or \"MessageBody\"."
  }
}

################################################################################
# Monitoring
################################################################################

variable "create_alarms" {
  description = "Create CloudWatch alarms for backlog, message age and DLQ depth."
  type        = bool
  default     = true
}

variable "alarm_actions" {
  description = "ARNs (usually SNS topics) notified when an alarm fires."
  type        = list(string)
  default     = []
}

variable "ok_actions" {
  description = "ARNs notified when an alarm returns to OK."
  type        = list(string)
  default     = []
}

variable "alarm_period_seconds" {
  description = "Evaluation period for alarms."
  type        = number
  default     = 300
}

variable "alarm_evaluation_periods" {
  description = "Number of periods the condition must hold before alarming (backlog/age alarms)."
  type        = number
  default     = 3
}

variable "oldest_message_age_threshold_seconds" {
  description = "Alarm when the oldest message is older than this (consumers stuck or too slow). Set null to disable."
  type        = number
  default     = 900
}

variable "visible_messages_threshold" {
  description = "Alarm when visible (waiting) messages exceed this. Set null to disable."
  type        = number
  default     = 1000
}

variable "dlq_messages_threshold" {
  description = "Alarm when DLQ visible messages exceed this. Default 0 = alarm on the first failed message."
  type        = number
  default     = 0
}
