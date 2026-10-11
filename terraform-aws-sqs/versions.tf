terraform {
  # 1.7+ is needed for mock providers used by `terraform test` (tests/).
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 7.0.0"
    }
  }
}

# NOTE: no provider block here on purpose. The calling (root) module owns
# provider configuration, region, assume_role and default_tags.
