# =============================================================================
# terraform/rds.tf
# Amazon RDS PostgreSQL instance with optional Multi-AZ.
#
# Design decisions:
# - Multi-AZ is controlled by var.db_multi_az (false for dev, true for prod).
# - Password is provided via variable and stored in Secrets Manager.
# - Automated backups retained for 7 days.
# - Encryption at rest using AWS-managed KMS key.
# - Performance Insights enabled for query analysis.
# - Database is in isolated private subnets — no public access.
# =============================================================================

# ---------------------------------------------------------------------------
# DB Password Secret (Secrets Manager)
# ---------------------------------------------------------------------------
# Store the master password in Secrets Manager so EC2 instances can retrieve
# it at runtime. This avoids storing the password in the launch template,
# user-data, or any configuration file.
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${local.name_prefix}-db-credentials"
  description = "RDS master credentials for the Task Manager application"

  # Automatically rotate the secret (optional — requires a rotation Lambda)
  # rotation_lambda_arn = ""
  # rotation_rules { automatically_after_days = 30 }

  tags = {
    Name = "${local.name_prefix}-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
    engine   = "postgresql"
  })

  # Depends on RDS being created first (we need the endpoint)
  depends_on = [aws_db_instance.main]
}

# ---------------------------------------------------------------------------
# RDS Parameter Group
# ---------------------------------------------------------------------------
resource "aws_db_parameter_group" "postgres" {
  family      = "postgres16"
  name        = "${local.name_prefix}-pg16-params"
  description = "Custom parameter group for Task Manager PostgreSQL 16"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = {
    Name = "${local.name_prefix}-pg16-params"
  }
}

# ---------------------------------------------------------------------------
# RDS Instance
# ---------------------------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-postgres"

  # Engine
  engine               = var.db_engine
  engine_version       = var.db_engine_version
  instance_class       = var.db_instance_class
  parameter_group_name = aws_db_parameter_group.postgres.name

  # Storage
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = 100 # Enable storage autoscaling up to 100 GiB
  storage_type          = "gp3"
  storage_encrypted     = true # Encryption at rest

  # Credentials — NEVER hardcode, always use variables
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false # Must never be publicly accessible

  # High availability
  multi_az = var.db_multi_az # false for dev, true for Profile B

  # Backups
  backup_retention_period  = 7             # Days
  backup_window            = "02:00-03:00" # UTC — low-traffic window
  maintenance_window       = "sun:04:00-sun:05:00"
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  # Monitoring
  monitoring_interval                   = 60 # Enhanced monitoring every 60 seconds
  monitoring_role_arn                   = aws_iam_role.rds_monitoring_role.arn
  performance_insights_enabled          = true
  performance_insights_retention_period = 7 # Days (free tier)

  # Logging
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Deletion protection — set true for production
  deletion_protection = false

  # Skip final snapshot for dev (saves storage costs)
  skip_final_snapshot = true
  # final_snapshot_identifier = "${local.name_prefix}-final-snapshot" # Uncomment for prod

  apply_immediately = true

  tags = {
    Name = "${local.name_prefix}-postgres"
  }
}

# ---------------------------------------------------------------------------
# IAM Role for RDS Enhanced Monitoring
# ---------------------------------------------------------------------------
resource "aws_iam_role" "rds_monitoring_role" {
  name = "${local.name_prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "monitoring.rds.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
