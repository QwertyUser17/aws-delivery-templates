# Minimal target for deploy-ec2: one instance reachable only through SSM, an ECR
# repository, the log group for the deploy output and a role for GitHub Actions.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "aws-delivery-templates"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# The default VPC keeps this example small. The instance has a public IP for
# outbound traffic (SSM, ECR, CloudWatch) and accepts nothing inbound.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  log_group  = "/aws-delivery/ec2/${var.container_name}"
}
