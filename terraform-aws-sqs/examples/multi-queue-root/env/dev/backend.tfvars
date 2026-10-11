bucket       = "my-org-tfstate-dev" # replace
key          = "camunda-infra/sqs/terraform.tfstate"
region       = "eu-west-2"
encrypt      = true
use_lockfile = true # S3-native locking (Terraform 1.10+); use dynamodb_table on older versions
