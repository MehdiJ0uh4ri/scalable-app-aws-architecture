# =============================================================================
# terraform/route_tables.tf
# Route tables control how traffic flows between subnets and gateways.
#
# Three route tables:
#   1. Public     → default route via Internet Gateway
#   2. Private App → default route via NAT Gateway (or no internet route if disabled)
#   3. Private DB  → no internet route (isolated)
# =============================================================================

# ---------------------------------------------------------------------------
# Public route table — routes internet traffic through the IGW
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-rt-public"
  }
}

# Associate all public subnets with the public route table
resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Private application route tables — one per AZ for HA NAT GW routing
# ---------------------------------------------------------------------------
resource "aws_route_table" "private_app" {
  count  = local.az_count
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-rt-private-app-${var.availability_zones[count.index]}"
  }
}

# Add a default route to NAT GW only when NAT GW is enabled
resource "aws_route" "private_app_nat" {
  # Create routes only when NAT GW exists
  count = var.nat_gateway_enabled ? local.az_count : 0

  route_table_id         = aws_route_table.private_app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  # If single_nat_gateway, all AZs route through NAT GW 0; otherwise use the per-AZ GW
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
}

resource "aws_route_table_association" "private_app" {
  count = local.az_count

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# ---------------------------------------------------------------------------
# Private database route table — no internet route
# ---------------------------------------------------------------------------
resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id

  # No routes added → only local VPC traffic is allowed

  tags = {
    Name = "${local.name_prefix}-rt-private-db"
  }
}

resource "aws_route_table_association" "private_db" {
  count = local.az_count

  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db.id
}
