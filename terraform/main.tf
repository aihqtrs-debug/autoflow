terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Learning-project note: state is local for now (simplest to get moving).
  # A production setup would use an S3 backend + DynamoDB lock table for
  # team collaboration and state locking. We'll add that as a stretch goal.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "AutoFlow"
      ManagedBy = "Terraform"
      Owner     = var.owner_tag
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "autoflow-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
}
