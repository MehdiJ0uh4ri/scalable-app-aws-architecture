# =============================================================================
# terraform/alb.tf
# Application Load Balancer, Target Group, and Listeners.
#
# Design decisions:
# - ALB is internet-facing and placed in public subnets.
# - Target Group uses the Flask /health endpoint for health checks.
# - HTTP listener redirects to HTTPS (production pattern).
# - HTTPS listener requires an ACM certificate (documented as prerequisite).
# - Access logs are written to S3 (optional — requires a bucket).
# =============================================================================

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false # Internet-facing
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Drop invalid HTTP headers for security
  drop_invalid_header_fields = true

  # Enable deletion protection in production
  enable_deletion_protection = false # Set to true for prod

  # Enable cross-zone load balancing (default for ALB — included for clarity)
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# ---------------------------------------------------------------------------
# Target Group — routes traffic to EC2 instances
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "app" {
  name        = "${local.name_prefix}-tg-app"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # Health check — mirrors the Flask /health endpoint
  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  # Deregistration delay — allow in-flight requests to complete before
  # the instance is removed from the target group during scale-in
  deregistration_delay = 30

  stickiness {
    type    = "lb_cookie"
    enabled = false # Stateless app — no sticky sessions needed
  }

  tags = {
    Name = "${local.name_prefix}-tg-app"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# HTTP Listener — redirects all traffic to HTTPS
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name = "${local.name_prefix}-listener-http"
  }
}

# ---------------------------------------------------------------------------
# HTTPS Listener — forwards to Target Group (requires ACM certificate)
# ---------------------------------------------------------------------------
# PREREQUISITE: An ACM certificate must exist for your domain.
# See documentation/deployment-guide.md for setup instructions.
# This resource is commented out until a domain and certificate are available.
#
# resource "aws_lb_listener" "https" {
#   load_balancer_arn = aws_lb.main.arn
#   port              = 443
#   protocol          = "HTTPS"
#   ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
#   certificate_arn   = aws_acm_certificate_validation.app.certificate_arn
#
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.app.arn
#   }
#
#   tags = {
#     Name = "${local.name_prefix}-listener-https"
#   }
# }

# ---------------------------------------------------------------------------
# HTTP Listener Rule — forward directly (dev mode without HTTPS)
# ---------------------------------------------------------------------------
# In development (no ACM cert), forward HTTP directly to the target group.
resource "aws_lb_listener_rule" "http_forward_dev" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  # Remove this rule when HTTPS listener is active
  tags = {
    Name = "${local.name_prefix}-rule-http-dev"
    Note = "Replace with HTTPS listener for production"
  }
}
