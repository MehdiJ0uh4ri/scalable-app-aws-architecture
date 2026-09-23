# =============================================================================
# terraform/vpc.tf
# Virtual Private Cloud — the network container for all resources.
#
# Design decisions:
# - Single VPC with a /16 CIDR gives 65 536 IP addresses — plenty for scaling.
# - DNS hostnames enabled so EC2 instances get resolvable names (required for
#   SSM Session Manager and some service-discovery patterns).
# - DNS support enabled (required for Route 53 resolver).
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true # Required for SSM Session Manager
  enable_dns_support   = true # Required for Route 53 private hosted zones

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# ---------------------------------------------------------------------------
# Network ACLs (stateless, subnet-level firewall)
# ---------------------------------------------------------------------------
# Default NACL behaviour is to allow all traffic. We define explicit NACLs for
# each subnet tier to add a defence-in-depth layer on top of Security Groups.

# Public subnets NACL — allows inbound HTTP/HTTPS from the internet
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id

  # Inbound
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # Ephemeral ports — required for return traffic from internet (TCP stateless)
  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Outbound — allow all (ALB and NAT GW need to reach various destinations)
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name = "${local.name_prefix}-nacl-public"
  }
}

# Private application subnets NACL
resource "aws_network_acl" "private_app" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private_app[*].id

  # Allow inbound traffic from VPC CIDR only (ALB to app instances)
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = var.vpc_cidr
    from_port  = var.app_port
    to_port    = var.app_port
  }

  # Ephemeral ports (return traffic from outbound connections via NAT GW)
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Allow all outbound (instances need internet access via NAT GW for packages)
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name = "${local.name_prefix}-nacl-private-app"
  }
}

# Private database subnets NACL
resource "aws_network_acl" "private_db" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private_db[*].id

  # Allow PostgreSQL connections from the private app subnets only
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = var.vpc_cidr
    from_port  = 5432
    to_port    = 5432
  }

  # Ephemeral ports for return traffic
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = var.vpc_cidr
    from_port  = 1024
    to_port    = 65535
  }

  # Outbound — only back to VPC
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = var.vpc_cidr
    from_port  = 1024
    to_port    = 65535
  }

  tags = {
    Name = "${local.name_prefix}-nacl-private-db"
  }
}
