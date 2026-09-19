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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state: an S3 bucket + DynamoDB lock table, bootstrapped once by
  # hand (see docs/ci-cd-setup.md) so CloudShell and GitHub Actions always
  # read/write the exact same state and can never race each other.
  backend "s3" {
    bucket         = "autoflow-dev-terraform-state-486758670110"
    key            = "autoflow/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "autoflow-dev-terraform-locks"
    encrypt        = true
  }
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
