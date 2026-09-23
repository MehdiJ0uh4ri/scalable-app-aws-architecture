# =============================================================================
# terraform/locals.tf
# Computed local values derived from variables.
#
# locals.tf centralises name-generation logic so resource naming is consistent
# across all Terraform files without repeating the same interpolation logic.
# =============================================================================

locals {
  # Naming prefix: "<project>-<environment>", e.g. "manara-task-app-dev"
  name_prefix = "${var.project_name}-${var.environment}"

  # Number of AZs drives subnet/NAT counts
  az_count = length(var.availability_zones)

  # AMI: use the provided value or look up the latest Amazon Linux 2023
  ami_id = var.ec2_ami_id != "" ? var.ec2_ami_id : data.aws_ami.amazon_linux_2023.id

  # Full domain for the application (e.g. tasks.example.com)
  full_domain = var.domain_name != "" ? "${var.app_subdomain}.${var.domain_name}" : ""

  # Whether DNS is configured
  dns_enabled = var.domain_name != ""

  # Common tags applied to every resource (supplementing provider default_tags)
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ---------------------------------------------------------------------------
# Data sources used in locals
# ---------------------------------------------------------------------------

# Latest Amazon Linux 2023 AMI (x86_64, HVM, GP2 EBS)
# This avoids hardcoding an AMI ID that is region-specific and changes over time.
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Current AWS account ID — used in IAM policies and resource ARNs
data "aws_caller_identity" "current" {}

# Current region — used in resource ARNs
data "aws_region" "current" {}
