terraform {
  required_version = ">= 1.7.0"

  # Partial configuration: values come from env/<env>/backend.tfvars
  #   terraform init -backend-config=../env/dev/backend.tfvars
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 7.0.0"
    }
  }
}
