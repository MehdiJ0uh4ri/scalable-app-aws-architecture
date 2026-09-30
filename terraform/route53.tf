# =============================================================================
# terraform/route53.tf
# Route 53 DNS configuration.
#
# PREREQUISITE:
#   A Route 53 hosted zone for your domain must exist.
#   Either purchase a domain via Route 53 (~$12/year) or transfer one.
#   A hosted zone itself costs $0.50/month.
#
# This file is conditionally applied based on var.domain_name.
# If domain_name = "" (default), no Route 53 resources are created.
# =============================================================================

# ---------------------------------------------------------------------------
# Look up the existing hosted zone (must already exist)
# ---------------------------------------------------------------------------
data "aws_route53_zone" "main" {
  count        = local.dns_enabled ? 1 : 0
  name         = var.domain_name
  private_zone = false
}

# ---------------------------------------------------------------------------
# ACM Certificate (us-east-1 — required for CloudFront)
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "app" {
  count    = local.dns_enabled ? 1 : 0
  provider = aws.us_east_1

  domain_name               = local.full_domain
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-acm-cert"
  }
}

# ---------------------------------------------------------------------------
# ACM DNS Validation Records
# ---------------------------------------------------------------------------
resource "aws_route53_record" "acm_validation" {
  for_each = local.dns_enabled ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "app" {
  count           = local.dns_enabled ? 1 : 0
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [
    for record in aws_route53_record.acm_validation : record.fqdn
  ]
}

# ---------------------------------------------------------------------------
# A Record — CloudFront alias
# ---------------------------------------------------------------------------
resource "aws_route53_record" "app" {
  count   = local.dns_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = local.full_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
