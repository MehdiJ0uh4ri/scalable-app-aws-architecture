# =============================================================================
# terraform/autoscaling.tf
# Auto Scaling Group and scaling policies.
#
# Design decisions:
# - ASG distributes instances across private app subnets in both AZs.
# - Target tracking scaling policy adjusts capacity based on CPU utilisation.
# - Instance refresh enables rolling deployments of new Launch Template versions.
# - Lifecycle hooks allow graceful draining before termination.
# =============================================================================

resource "aws_autoscaling_group" "app" {
  name                = "${local.name_prefix}-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = aws_subnet.private_app[*].id

  # Attach to the ALB target group for health checks and traffic routing
  target_group_arns = [aws_lb_target_group.app.arn]

  # Use ELB health checks (not just EC2 status checks) so the ASG replaces
  # instances that fail the ALB /health check
  health_check_type         = "ELB"
  health_check_grace_period = 120 # Seconds to wait before first health check

  # Terminate unhealthy instances and replace them first during scale-in
  default_instance_warmup = 60

  # Launch Template reference
  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # Termination policy: OldestLaunchTemplate ensures newer instances survive
  termination_policies = ["OldestLaunchTemplate", "OldestInstance"]

  # Enable metrics collection for CloudWatch
  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
  ]

  # Instance refresh — enables rolling updates when the Launch Template changes
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50 # Keep at least half the instances healthy during update
      instance_warmup        = 60
    }
    triggers = []
  }

  dynamic "tag" {
    for_each = {
      Name        = "${local.name_prefix}-app-instance"
      Application = "task-manager"
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    # Ignore desired_capacity changes made by scaling policies
    ignore_changes = [desired_capacity]
  }
}

# ---------------------------------------------------------------------------
# Target Tracking Scaling Policy — CPU Utilisation
# ---------------------------------------------------------------------------
# When average CPU across the ASG exceeds the target, AWS automatically
# adds instances. When CPU drops well below the target, instances are removed.
# AWS recommends starting with 60% CPU as the target for web applications.
resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "${local.name_prefix}-asg-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = var.asg_target_cpu
    disable_scale_in = false # Allow scale-in (cost saving)
  }
}

# ---------------------------------------------------------------------------
# Target Tracking Scaling Policy — Request Count Per Target
# ---------------------------------------------------------------------------
# Scale based on ALB requests per target — catches traffic spikes even if
# CPU hasn't responded yet (e.g. for I/O-bound workloads).
resource "aws_autoscaling_policy" "alb_request_tracking" {
  name                   = "${local.name_prefix}-asg-alb-request-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
    target_value = 1000 # 1000 requests per target per minute
  }
}
