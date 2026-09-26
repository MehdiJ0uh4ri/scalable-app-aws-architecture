# =============================================================================
# terraform/launch_template.tf
# EC2 Launch Template — defines how Auto Scaling Group instances are launched.
#
# Design decisions:
# - IMDSv2 enforced (hop limit=1) — prevents SSRF attacks from reaching IMDS.
# - No SSH key pair — SSM Session Manager is the only access method.
# - EBS volume is encrypted at rest using the AWS-managed key.
# - User-data script installs the application and configures the systemd service.
# - The DB password is retrieved from Secrets Manager at startup — never stored
#   in the launch template or baked into the AMI.
# =============================================================================

resource "aws_launch_template" "app" {
  name_prefix   = "${local.name_prefix}-lt-"
  description   = "Launch template for Task Manager application instances"
  image_id      = local.ami_id
  instance_type = var.ec2_instance_type

  # No key pair — use SSM Session Manager for shell access
  # key_name = ""  # intentionally omitted

  # Attach the IAM instance profile
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  # Network interface — assign to private app subnets (via ASG), no public IP
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
    delete_on_termination       = true
  }

  # Enforce IMDSv2 (session-oriented metadata API)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforce IMDSv2
    http_put_response_hop_limit = 1          # Prevents SSRF from reaching IMDS
    instance_metadata_tags      = "enabled"
  }

  # Encrypted EBS root volume
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Monitoring — enables 1-minute CloudWatch metrics (default is 5-minute)
  monitoring {
    enabled = true
  }

  # User-data script: runs on first boot to install and configure the application
  user_data = base64encode(templatefile("${path.module}/scripts/user_data.sh", {
    db_secret_name = "${local.name_prefix}-db-credentials"
    aws_region     = var.aws_region
    app_port       = var.app_port
    app_version    = "1.0.0"
    name_prefix    = local.name_prefix
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.name_prefix}-app-instance"
      Application = "task-manager"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name_prefix}-app-volume"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
