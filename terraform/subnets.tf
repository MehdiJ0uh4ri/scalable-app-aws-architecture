# =============================================================================
# terraform/subnets.tf
# Subnet definitions across two Availability Zones.
#
# Subnet tier design:
#
#   PUBLIC (10.0.1.0/24, 10.0.2.0/24)
#     → Internet Gateway route
#     → Hosts: ALB, NAT Gateways
#
#   PRIVATE APP (10.0.11.0/24, 10.0.12.0/24)
#     → NAT Gateway route (outbound internet for package installs)
#     → Hosts: EC2 application instances (NO public IPs)
#
#   PRIVATE DB (10.0.21.0/24, 10.0.22.0/24)
#     → No internet route (fully isolated)
#     → Hosts: RDS Multi-AZ
#
# Using count = length(var.availability_zones) means adding a third AZ
# only requires updating the variables — no code changes needed.
# =============================================================================

# ----- Public Subnets -----
resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true # ALB and NAT GW need public IPs

  tags = {
    Name = "${local.name_prefix}-public-${var.availability_zones[count.index]}"
    Tier = "public"
    # EKS tag (not used here but good practice for future compatibility)
    "kubernetes.io/role/elb" = "1"
  }
}

# ----- Private Application Subnets -----
resource "aws_subnet" "private_app" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_app_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false # EC2 instances must NOT have public IPs

  tags = {
    Name                              = "${local.name_prefix}-private-app-${var.availability_zones[count.index]}"
    Tier                              = "private-app"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ----- Private Database Subnets -----
resource "aws_subnet" "private_db" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_db_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false # Database must never be publicly accessible

  tags = {
    Name = "${local.name_prefix}-private-db-${var.availability_zones[count.index]}"
    Tier = "private-db"
  }
}

# ---------------------------------------------------------------------------
# RDS Subnet Group (requires the DB subnets to exist first)
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name        = "${local.name_prefix}-db-subnet-group"
  description = "Subnet group for RDS Multi-AZ deployment"
  subnet_ids  = aws_subnet.private_db[*].id

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}
