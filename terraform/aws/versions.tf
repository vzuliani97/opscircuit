terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  # For a real deployment, keep state remotely with locking (the bucket must exist first):
  # backend "s3" {
  #   bucket       = "my-terraform-state-bucket"
  #   key          = "platformops/aws/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "platformops"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
