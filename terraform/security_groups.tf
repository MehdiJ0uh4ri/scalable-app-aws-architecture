# =============================================================================
# terraform/security_groups.tf
# Security Groups — stateful firewalls applied at the resource level.
#
# Security Group design (least-privilege):
#
#   ALB SG        → accepts 80/443 from 0.0.0.0/0
#   App SG        → accepts var.app_port ONLY from ALB SG (not from internet)
#   DB SG         → accepts 5432 ONLY from App SG (not from internet or ALB)
#   VPC Endpoint SG → accepts 443 from App SG (for SSM without NAT GW)
#
# Never opening 0.0.0.0/0 to private resources is a core security principle.
# =============================================================================

# ---------------------------------------------------------------------------
# ALB Security Group — internet-facing load balancer
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-sg-alb"
  description = "Allow HTTP and HTTPS from the internet to the ALB."
  vpc_id      = aws_vpc.main.id

  # Inbound HTTP — will redirect to HTTPS in production
  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound HTTPS
  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound — ALB needs to reach app instances
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-sg-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Application (EC2) Security Group
# ---------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-sg-app"
  description = "Allow inbound traffic only from the ALB security group."
  vpc_id      = aws_vpc.main.id

  # Accept app traffic ONLY from the ALB — not from the public internet
  ingress {
    description     = "App port from ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Allow all outbound — instances need to reach RDS and internet (via NAT GW)
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-sg-app"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Database Security Group
# ---------------------------------------------------------------------------
resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-sg-db"
  description = "Allow PostgreSQL connections only from the application security group."
  vpc_id      = aws_vpc.main.id

  # Accept PostgreSQL ONLY from app instances
  ingress {
    description     = "PostgreSQL from app instances"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # No outbound rules needed — RDS doesn't initiate connections

  tags = {
    Name = "${local.name_prefix}-sg-db"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# VPC Endpoint Security Group (for SSM Session Manager without NAT GW)
# ---------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-sg-vpc-endpoints"
  description = "Allow HTTPS from the app SG to reach AWS API VPC endpoints."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTPS from app instances to VPC endpoints"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-sg-vpc-endpoints"
  }
}
