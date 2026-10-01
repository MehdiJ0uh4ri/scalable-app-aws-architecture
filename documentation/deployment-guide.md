# Deployment Guide

## Prerequisites

### Required Tools
| Tool | Version | Windows Installation |
|------|---------|---------------------|
| AWS CLI | ≥ 2.x | [installer](https://aws.amazon.com/cli/) |
| Terraform | ≥ 1.9 | `winget install HashiCorp.Terraform` |
| Python | ≥ 3.12 | [installer](https://python.org) |
| Git | ≥ 2.x | [installer](https://git-scm.com) |

### AWS Prerequisites
1. AWS account with appropriate IAM permissions.
2. AWS CLI configured: `aws configure`
3. (Profile B only) A registered domain name in Route 53.
4. (Profile B only) An ACM certificate for your domain.

---

## Profile A — Local Development (Zero Budget)

```powershell
# Clone repository
git clone https://github.com/YOUR_USERNAME/manara-aws-project-app.git
cd manara-aws-project-app\application

# Create virtual environment
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# Install dependencies
pip install -r requirements.txt

# Configure environment (SQLite by default)
Copy-Item .env.example .env

# Start the application
python wsgi.py
```

The application will be available at `http://localhost:5000`.

**API Endpoints:**
```
GET    /                        → Welcome message
GET    /health                  → Health check (ALB-compatible)
GET    /info                    → Instance information
GET    /api/tasks               → List all tasks
POST   /api/tasks               → Create a task
GET    /api/tasks/{id}          → Get a task
PUT    /api/tasks/{id}          → Full update
PATCH  /api/tasks/{id}          → Partial update
DELETE /api/tasks/{id}          → Delete a task
```

---

## Profile B — Full AWS Deployment

> ⚠️ **This will incur AWS charges (~\$5-10/day). Read the cost-estimation.md first.**
> Never run `terraform apply` without reviewing the plan.

### Step 1: Configure AWS credentials
```powershell
aws configure
# Enter: Access Key ID, Secret Access Key, Region (eu-west-3), Output (json)
```

### Step 2: Prepare Terraform variables
```powershell
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set db_password, alarm_email, domain_name
```

### Step 3: Initialise Terraform
```powershell
terraform init
```

### Step 4: Review the plan
```powershell
terraform plan -var-file="terraform.tfvars" -out=plan.out
# REVIEW CAREFULLY — check resource count and estimated cost
```

### Step 5: Apply (requires explicit confirmation)
```powershell
terraform apply plan.out
# Type "yes" when prompted
```

### Step 6: Verify deployment
```powershell
# Get ALB DNS name
terraform output alb_dns_name

# Test the health endpoint
$ALB = terraform output -raw alb_dns_name
Invoke-RestMethod "http://$ALB/health"

# Test the API
Invoke-RestMethod "http://$ALB/api/tasks"
```

### Step 7: Confirm SNS email subscription
Check your email for an SNS confirmation message and click "Confirm subscription".

---

## Connecting to EC2 Instances (SSM Session Manager)

No SSH required. Access via AWS Console or CLI:

```powershell
# List running instances
aws ec2 describe-instances `
  --filters "Name=tag:Application,Values=task-manager" `
  --query "Reservations[].Instances[].[InstanceId,State.Name]" `
  --output table

# Start a session
aws ssm start-session --target <INSTANCE_ID>
```

---

## Post-Deployment: Enable HTTPS

1. Ensure your domain has a hosted zone in Route 53.
2. Uncomment the `aws_acm_certificate` block in `route53.tf`.
3. Set `domain_name` in `terraform.tfvars`.
4. Run `terraform apply` again.
5. Uncomment the HTTPS listener block in `alb.tf`.
6. Run `terraform apply` a final time.

---

## Cleanup — CRITICAL

Always destroy resources after your demo to avoid ongoing charges:

```powershell
cd terraform
terraform destroy -var-file="terraform.tfvars"
# Type "yes" when prompted
```

**Manual verification checklist:**
- [ ] EC2 instances terminated
- [ ] ASG deleted
- [ ] RDS instance deleted (no snapshots)
- [ ] NAT Gateways deleted
- [ ] Elastic IPs released
- [ ] ALB deleted
- [ ] CloudFront distribution disabled and deleted
- [ ] VPC deleted
- [ ] Check AWS Billing Dashboard for unexpected charges
