# =============================================================================
# terraform/iam.tf
# IAM roles and policies for EC2 instances.
#
# Security design:
# - EC2 instances use an IAM role instead of access keys (never hardcode keys).
# - The role follows least-privilege: only the permissions the application
#   actually needs are granted.
# - SSM policies allow Session Manager access WITHOUT an SSH bastion host.
# - CloudWatch Agent policy allows metric and log publishing.
# - Secrets Manager permission allows the app to retrieve the DB password
#   at startup without storing it in user-data or environment files.
# =============================================================================

# ---------------------------------------------------------------------------
# EC2 Instance Role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ec2_instance_role" {
  name        = "${local.name_prefix}-ec2-role"
  description = "IAM role for Task Manager EC2 instances."

  # Trust policy: only EC2 service can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-ec2-role"
  }
}

# ---------------------------------------------------------------------------
# AWS Managed Policy: SSM Session Manager
# ---------------------------------------------------------------------------
# Allows operators to open a secure shell session via the AWS Console or CLI
# without opening port 22 or deploying a bastion host.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ---------------------------------------------------------------------------
# AWS Managed Policy: CloudWatch Agent
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ---------------------------------------------------------------------------
# Custom Policy: Secrets Manager — read DB credentials
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "secrets_manager_read" {
  name = "${local.name_prefix}-secrets-read"
  role = aws_iam_role.ec2_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadDbSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Restrict to secrets with a known prefix — not all secrets in the account
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.name_prefix}/*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Custom Policy: SSM Parameter Store — read application configuration
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "ssm_parameters_read" {
  name = "${local.name_prefix}-ssm-params-read"
  role = aws_iam_role.ec2_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadAppParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${local.name_prefix}/*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# EC2 Instance Profile — attaches the role to EC2 instances
# ---------------------------------------------------------------------------
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${local.name_prefix}-ec2-instance-profile"
  role = aws_iam_role.ec2_instance_role.name

  tags = {
    Name = "${local.name_prefix}-ec2-instance-profile"
  }
}

# ---------------------------------------------------------------------------
# VPC Interface Endpoints for SSM (required when NAT GW is disabled)
# ---------------------------------------------------------------------------
# Without a NAT GW, EC2 instances in private subnets cannot reach AWS APIs
# over the internet. VPC interface endpoints route that traffic through the
# AWS private network — no internet exposure, no data transfer costs beyond
# the endpoint hourly charge (~$0.01/hr per endpoint).
#
# Required endpoints for SSM Session Manager:
#   - com.amazonaws.<region>.ssm
#   - com.amazonaws.<region>.ssmmessages
#   - com.amazonaws.<region>.ec2messages
#
# Also added:
#   - com.amazonaws.<region>.secretsmanager  (DB password retrieval)
#   - com.amazonaws.<region>.monitoring      (CloudWatch metrics)
#   - com.amazonaws.<region>.logs            (CloudWatch Logs)

locals {
  ssm_endpoints = [
    "ssm",
    "ssmmessages",
    "ec2messages",
    "secretsmanager",
    "monitoring",
    "logs",
  ]
}

resource "aws_vpc_endpoint" "ssm_endpoints" {
  for_each = toset(local.ssm_endpoints)

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private_app[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name_prefix}-endpoint-${each.value}"
  }
}
