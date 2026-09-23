# =============================================================================
# terraform/internet_gateway.tf
# Internet Gateway — provides internet access for public subnets.
#
# The IGW is a horizontally scalable, redundant, highly available VPC
# component managed by AWS. There is no instance to manage or scale.
# One IGW per VPC is the standard pattern.
# =============================================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}
