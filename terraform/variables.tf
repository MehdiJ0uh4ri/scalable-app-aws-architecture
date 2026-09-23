# =============================================================================
# terraform/variables.tf
# All input variables for the root module.
# =============================================================================

# ----- Global -----

variable "aws_region" {
  description = "AWS region for the deployment."
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Short name used to prefix resource names."
  type        = string
  default     = "manara-task-app"
}

variable "environment" {
  description = "Deployment environment label (dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "owner" {
  description = "Owner tag value — identifies the responsible engineer."
  type        = string
  default     = "manara-student"
}

# ----- Networking -----

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of Availability Zones to use (must have at least 2)."
  type        = list(string)
  default     = ["eu-west-3a", "eu-west-3b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for the private application subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "CIDR blocks for the private database subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

# ----- Compute -----

variable "ec2_instance_type" {
  description = "EC2 instance type for application servers."
  type        = string
  default     = "t3.micro"
}

variable "ec2_ami_id" {
  description = "AMI ID for EC2 instances. Leave empty to use the latest Amazon Linux 2023."
  type        = string
  default     = ""
}

variable "app_port" {
  description = "Port on which Gunicorn listens inside the EC2 instance."
  type        = number
  default     = 5000
}

# ----- Auto Scaling -----

variable "asg_min_size" {
  description = "Minimum number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 6
}

variable "asg_desired_capacity" {
  description = "Initial desired number of EC2 instances."
  type        = number
  default     = 2
}

variable "asg_target_cpu" {
  description = "Target CPU utilisation percentage for target tracking scaling."
  type        = number
  default     = 60
}

# ----- Database -----

variable "db_engine" {
  description = "RDS database engine."
  type        = string
  default     = "postgres"
}

variable "db_engine_version" {
  description = "RDS PostgreSQL engine version."
  type        = string
  default     = "16.3"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the application database."
  type        = string
  default     = "taskdb"
}

variable "db_username" {
  description = "Master username for the RDS instance."
  type        = string
  default     = "taskadmin"
  sensitive   = true
}

variable "db_password" {
  description = "Master password for the RDS instance. Use Secrets Manager in production."
  type        = string
  sensitive   = true
  # No default — must be provided via terraform.tfvars or environment variable.
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS. Set false for dev/cost savings."
  type        = bool
  default     = false # Set to true for Profile B (production)
}

# ----- DNS / TLS -----

variable "domain_name" {
  description = "Route 53 hosted zone domain name (e.g. example.com). Leave empty to skip DNS."
  type        = string
  default     = ""
}

variable "app_subdomain" {
  description = "Subdomain for the application (e.g. tasks → tasks.example.com)."
  type        = string
  default     = "tasks"
}

# ----- Monitoring -----

variable "alarm_email" {
  description = "Email address for CloudWatch alarm SNS notifications."
  type        = string
  default     = ""
}

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log group retention in days."
  type        = number
  default     = 7
}
