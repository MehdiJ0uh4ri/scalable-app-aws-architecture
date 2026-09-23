# =============================================================================
# terraform/nat_gateway.tf
# NAT Gateway — provides outbound internet access for private subnets.
#
# Cost note (IMPORTANT — Profile A vs Profile B):
# -----------------------------------------------
# A NAT Gateway costs approximately $0.045/hour (~$32/month) PLUS
# $0.045 per GB of data processed.
#
# Profile A (dev/zero-budget):
#   - nat_gateway_enabled = false → NO NAT Gateway is created.
#   - EC2 instances in private subnets cannot reach the internet.
#   - Use SSM VPC endpoints instead of NAT GW for Session Manager access.
#
# Profile B (full architecture):
#   - Two NAT Gateways (one per AZ) for high availability.
#   - Each AZ's private route table routes 0.0.0.0/0 through its own NAT GW.
#   - If one AZ fails, the other AZ's NAT GW is unaffected.
#
# Single NAT GW is a common cost-saving compromise for non-prod.
# =============================================================================

variable "nat_gateway_enabled" {
  description = <<-EOT
    Whether to create NAT Gateways.
    Set false for Profile A (zero-budget dev) — private subnets lose internet access.
    Set true for Profile B (full architecture) — creates one NAT GW per AZ.
    CAUTION: each NAT GW costs ~$32/month + data charges.
  EOT
  type        = bool
  default     = false # Safe default — does not create chargeable resources
}

variable "single_nat_gateway" {
  description = <<-EOT
    When nat_gateway_enabled=true, use a single NAT GW (cost saving) instead of
    one per AZ. Acceptable for dev/staging; use false for production HA.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Elastic IPs for NAT Gateways
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  # Create one EIP per NAT GW (1 if single, az_count if HA)
  count  = var.nat_gateway_enabled ? (var.single_nat_gateway ? 1 : local.az_count) : 0
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------------------
# NAT Gateways (placed in public subnets)
# ---------------------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  count = var.nat_gateway_enabled ? (var.single_nat_gateway ? 1 : local.az_count) : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.name_prefix}-nat-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.main]
}
