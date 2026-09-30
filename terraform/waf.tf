# =============================================================================
# terraform/waf.tf
# AWS WAF v2 Web ACL — protects CloudFront and ALB from common attacks.
#
# Design decisions:
# - AWS Managed Rule Groups handle OWASP Top 10 and known bad actors.
# - Rate limiting prevents brute-force and DDoS attacks at the edge.
# - WAF is applied to CloudFront (us-east-1 scope) for global protection.
# - A regional WAF can also be applied directly to the ALB.
#
# Cost note:
# - WAF web ACL: $5/month per ACL
# - Rule groups: $1/month per rule group used
# - Requests: $0.60 per million requests
# =============================================================================

# ---------------------------------------------------------------------------
# CloudFront WAF (scope = CLOUDFRONT — must be in us-east-1)
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.us_east_1 # CloudFront WAF must be in us-east-1
  name        = "${local.name_prefix}-waf-cf"
  description = "WAF Web ACL for CloudFront distribution"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # ----- Rate Limiting -----
  rule {
    name     = "RateLimitRule"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000 # Max 2000 requests per 5-minute window per IP
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-waf-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # ----- AWS Managed Rules: Common Rule Set (OWASP Top 10) -----
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {} # Use the managed rule's default action (block)
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-waf-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # ----- AWS Managed Rules: Known Bad Inputs -----
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-waf-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ----- AWS Managed Rules: SQL Injection -----
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-waf-sqli"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf-cf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.name_prefix}-waf-cf"
  }
}

# ---------------------------------------------------------------------------
# Regional WAF — attached directly to the ALB (eu-west-3)
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "regional" {
  name        = "${local.name_prefix}-waf-regional"
  description = "Regional WAF Web ACL for ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimitRule"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-regional-waf-rate"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-regional-waf-common"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf-regional"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.name_prefix}-waf-regional"
  }
}

# Associate regional WAF with the ALB
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.regional.arn
}
