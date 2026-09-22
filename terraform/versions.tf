# =============================================================================
# terraform/versions.tf
# Lock Terraform core and provider versions for reproducible builds.
#
# Why pin versions?
# - Prevents breaking changes from new provider releases.
# - Ensures CI/CD pipelines use the same provider as the developer.
# - Required by team collaboration best practices.
# =============================================================================

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state — Profile B (Full Graduation Architecture)
  # ---------------------------------------------------------------------------
  # Uncomment the backend block below when deploying Profile B.
  # S3 backend keeps state in a versioned, encrypted bucket and uses a
  # DynamoDB table for state locking to prevent concurrent `terraform apply`.
  #
  # Prerequisites (create once, manually):
  #   aws s3api create-bucket --bucket <your-bucket> --region eu-west-3 \
  #     --create-bucket-configuration LocationConstraint=eu-west-3
  #   aws s3api put-bucket-versioning --bucket <your-bucket> \
  #     --versioning-configuration Status=Enabled
  #   aws dynamodb create-table --table-name terraform-state-lock \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST --region eu-west-3
  #
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket-name"
  #   key            = "manara-aws-project/terraform.tfstate"
  #   region         = "eu-west-3"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"
  # }
}
