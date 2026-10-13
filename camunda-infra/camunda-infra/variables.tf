################################################################################
# Environment
################################################################################

variable "environment" {
  description = "Environment name (dev, sit, prod)."
  type        = string

  validation {
    condition     = contains(["dev", "sit", "prod"], var.environment)
    error_message = "environment must be dev, sit or prod."
  }
}

variable "region" {
  description = "AWS region. Story requires eu-west-2."
  type        = string
  default     = "eu-west-2"
}

variable "expected_account_id" {
  description = "AWS account ID this environment must deploy into (safety check). Null disables the check."
  type        = string
  default     = null
}

variable "team" {
  description = "Value of the mandatory 'team' tag."
  type        = string
  default     = "mso-modernization"
}

variable "project" {
  description = "Value of the mandatory 'project' tag."
  type        = string
  default     = "camunda-orchestrator"
}

################################################################################
# Queue
################################################################################

variable "queue_name" {
  description = "Queue name without .fifo (the module adds it). Set in env/<env>/terraform.tfvars."
  type        = string
}

variable "dlq_name" {
  description = "DLQ name without .fifo (the module adds it). Set in env/<env>/terraform.tfvars."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "NFR: >= 60 s. Must exceed the listener's worst-case processing time."
  type        = number
  default     = 120

  validation {
    condition     = var.visibility_timeout_seconds >= 60
    error_message = "visibility_timeout_seconds must be >= 60 (non-functional requirement)."
  }
}

variable "max_receive_count" {
  description = "Receives before a message is moved to the DLQ. Story: 3."
  type        = number
  default     = 3
}

variable "encryption_type" {
  description = "\"kms\" (module-created CMK, default) or \"sqs\" (SSE-SQS). Follow your org's standard."
  type        = string
  default     = "kms"
}

variable "kms_key_arn" {
  description = "Existing CMK to use instead of a module-created key. Its policy must allow sns.amazonaws.com."
  type        = string
  default     = null
}

################################################################################
# SNS subscription & filter
################################################################################

variable "sns_topic_arn" {
  description = "ARN of the source SNS FIFO topic (mae_apptracking_event_log.fifo), same account."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:.+\\.fifo$", var.sns_topic_arn))
    error_message = "sns_topic_arn must be an SNS FIFO topic ARN (ending in .fifo)."
  }
}

variable "filter_policy_scope" {
  description = "Where the publisher puts section/action: \"MessageAttributes\" (SNS message attributes) or \"MessageBody\" (top-level JSON fields)."
  type        = string
  default     = "MessageAttributes"

  validation {
    condition     = contains(["MessageAttributes", "MessageBody"], var.filter_policy_scope)
    error_message = "filter_policy_scope must be MessageAttributes or MessageBody."
  }
}

variable "section_key" {
  description = "Attribute / JSON key holding the section name (exact, case-sensitive)."
  type        = string
  default     = "section"
}

variable "action_key" {
  description = "Attribute / JSON key holding the action (exact, case-sensitive)."
  type        = string
  default     = "action"
}

variable "action_values" {
  description = "Allowed action values. Story: COMPLETED."
  type        = list(string)
  default     = ["COMPLETED"]
}

variable "section_names" {
  description = "Section names to let through (story: 14). Exact, case-sensitive."
  type        = list(string)

  validation {
    condition     = length(var.section_names) > 0 && length(var.section_names) == length(distinct(var.section_names))
    error_message = "section_names must be non-empty and contain no duplicates."
  }

}

################################################################################
# Alarm
################################################################################

variable "ops_alarm_topic_arn" {
  description = "SNS topic for the team ops channel. NFR: DLQ alarm must notify here. If it uses a CMK, the key policy must allow cloudwatch.amazonaws.com."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:sns:", var.ops_alarm_topic_arn))
    error_message = "ops_alarm_topic_arn must be an SNS topic ARN."
  }
}

variable "enable_backlog_alarms" {
  description = "Also create oldest-message-age and backlog alarms. Off for this story (only DLQ alarm in scope); turn on once the listener (S1-04) runs."
  type        = bool
  default     = false
}
