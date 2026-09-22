# =============================================================================
# terraform/providers.tf
# AWS provider configuration.
#
# Design decisions:
# - Region is parameterised via a variable so the same code can target any
#   AWS region without modification.
# - Default tags are applied at the provider level and inherited by every
#   resource — this prevents missing tags on resources.
# =============================================================================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner
    }
  }
}

# Secondary provider alias for us-east-1.
# Required for ACM certificates used by CloudFront — CloudFront only accepts
# ACM certificates issued in us-east-1 regardless of the deployment region.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner
    }
  }
}
