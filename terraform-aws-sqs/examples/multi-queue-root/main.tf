# Root module layout that mirrors a camunda-infra style repo:
#   terraform init -backend-config=env/dev/backend.tfvars
#   terraform plan  -var-file=env/dev/terraform.tfvars

terraform {
  required_version = ">= 1.7.0"

  backend "s3" {} # values come from env/<env>/backend.tfvars

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.common_tags
  }
}
