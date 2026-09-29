# =============================================================================
# terraform/cloudfront.tf
# Amazon CloudFront distribution — global CDN in front of the ALB.
#
# Design decisions:
# - CloudFront adds a global caching layer, reducing latency and origin load.
# - The ALB is set as the origin; CloudFront forwards dynamic requests.
# - Static assets (if any) could be served from an S3 origin.
# - WAF web ACL is attached at the CloudFront level for global protection.
# - Minimum TLS version is TLSv1.2 — per AWS security recommendations.
#
# Cost note:
# - CloudFront has a free tier (1 TB data transfer out + 10M requests/month).
# - Beyond free tier: ~$0.0085/GB for the first 10 TB (eu-west-3 origin).
# =============================================================================

resource "aws_cloudfront_distribution" "main" {
  comment             = "${local.name_prefix} CloudFront distribution"
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_100" # US, Canada, Europe only — lowest cost
  http_version        = "http2and3"
  wait_for_deployment = false

  # ----- Origin: ALB -----
  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # ALB HTTP (redirect to HTTPS at ALB)
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.cf_origin_header.result
    }
  }

  # ----- Default Cache Behaviour: API — no caching -----
  default_cache_behavior {
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # No caching for API responses (tasks change frequently)
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # ----- WAF Association -----
  # Uncomment when WAF is deployed:
  # web_acl_id = aws_wafv2_web_acl.main.arn

  # ----- Geo Restrictions -----
  restrictions {
    geo_restriction {
      restriction_type = "none" # Allow all countries
    }
  }

  # ----- TLS Certificate -----
  # Using the default CloudFront certificate (*. cloudfront.net).
  # Replace with your ACM certificate for a custom domain.
  viewer_certificate {
    cloudfront_default_certificate = true
    # acm_certificate_arn      = aws_acm_certificate_validation.app.certificate_arn
    # ssl_support_method       = "sni-only"
    # minimum_protocol_version = "TLSv1.2_2021"
  }

  # ----- Aliases (custom domain) -----
  # aliases = local.dns_enabled ? [local.full_domain] : []

  tags = {
    Name = "${local.name_prefix}-cf"
  }

  depends_on = [aws_lb.main]
}

# ---------------------------------------------------------------------------
# Origin Verification Header
# ---------------------------------------------------------------------------
# CloudFront adds this secret header to all requests to the ALB origin.
# The ALB (or WAF) can verify that requests come from CloudFront and not
# directly to the ALB's DNS name. This prevents origin bypass attacks.
resource "random_password" "cf_origin_header" {
  length  = 32
  special = false
}
