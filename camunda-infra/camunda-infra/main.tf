provider "aws" {
  region = var.region

  # NFR: all resources tagged team=mso-modernization, project=camunda-orchestrator
  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

# Fail fast if the pipeline/credentials point at the wrong account for this environment.
check "correct_account" {
  assert {
    condition     = var.expected_account_id == null || data.aws_caller_identity.current.account_id == var.expected_account_id
    error_message = "Running in account ${data.aws_caller_identity.current.account_id}, but env '${var.environment}' expects ${coalesce(var.expected_account_id, "n/a")}."
  }
}
