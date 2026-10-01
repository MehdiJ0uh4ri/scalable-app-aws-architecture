# Cost Estimation

## AWS Service Cost Analysis

This document provides a cost breakdown for the Scalable Web Application with ALB and Auto Scaling project.

---

## Cost Classification

### No Additional Infrastructure Charge (Free or Minimal)
| Service | Notes |
|---------|-------|
| VPC | No hourly charge for the VPC itself |
| Subnets, Route Tables, NACLs | No charge |
| Internet Gateway | No hourly charge; $0.09/GB data transfer out |
| Security Groups | No charge |
| IAM Roles & Policies | No charge |
| CloudWatch Basic Metrics | 10 metrics free; custom namespace metrics $0.30/metric/month |
| CloudWatch Logs Ingestion | First 5 GB/month free; $0.50/GB after |
| SNS Email Notifications | First 1,000 email notifications free |
| VPC Interface Endpoints | $0.01/hr per endpoint per AZ + $0.01/GB |

---

### Potentially Chargeable (Free Tier May Apply)
| Service | Free Tier | Charge After |
|---------|-----------|-------------|
| EC2 t3.micro | 750 hrs/month (12 months) | $0.0113/hr (~$8.20/month) |
| EBS gp3 20 GiB | 30 GiB/month (12 months) | $0.08/GiB/month |
| CloudFront | 1 TB out + 10M requests/month | $0.0085/GB + $0.0075/10K requests |

---

### Clearly Chargeable
| Service | Hourly Rate | Monthly Estimate |
|---------|-------------|-----------------|
| **NAT Gateway** (×2 for HA) | $0.045/hr + $0.045/GB | **~$65/month** |
| **NAT Gateway** (×1 single) | $0.045/hr + $0.045/GB | **~$33/month** |
| **ALB** | $0.0243/hr + LCU | **~$18-25/month** |
| **RDS db.t3.micro** (single-AZ) | $0.019/hr | **~$14/month** |
| **RDS db.t3.micro** (Multi-AZ) | $0.038/hr | **~$28/month** |
| **WAF** (CloudFront + Regional) | $5/ACL + $1/rule group | **~$10/month** |
| **Route 53** (hosted zone) | $0.50/zone | **~$0.50/month** |

---

## Profile A — Development (Zero Budget)

**Monthly cost: \$0**

No AWS resources are deployed. All development and testing happens locally using:
- Flask dev server (local)
- SQLite database (local)
- Terraform plan/validate only (no apply)

---

## Profile B — Full Graduation Architecture

**Estimated monthly cost (eu-west-3, Paris):**

| Resource | Config | Monthly |
|----------|--------|---------|
| EC2 t3.micro × 2 | 24×7, beyond free tier | \$16.40 |
| EBS gp3 20 GiB × 2 | beyond free tier | \$3.20 |
| ALB | 1 ACU average | \$18.00 |
| NAT Gateway × 2 (HA) | 24×7 + 10 GB | \$65.00 |
| RDS db.t3.micro Multi-AZ | 24×7 + 20 GiB | \$28.00 + \$2.30 |
| RDS storage | 20 GiB gp3 | \$2.30 |
| CloudFront | < free tier | \$0 |
| WAF (2 ACLs + rules) | | \$10.00 |
| CloudWatch | < free tier (7-day retention) | \$0–3.00 |
| SNS | < free tier | \$0 |
| VPC Endpoints (6 endpoints) | 6 × $0.01 × 730 hrs | \$43.80 |
| Route 53 | 1 hosted zone | \$0.50 |
| Secrets Manager | 1 secret | \$0.40 |
| **Total** | | **~\$189/month** |

> [!WARNING]
> The largest cost items are NAT Gateway (\$65) and VPC Endpoints (\$44). 
> For a short demo/graduation project, deploy Profile B for 2-3 days maximum, then destroy.
> 2-3 day cost: approximately \$12-18.

---

## Cost-Saving Options

| Option | Saving |
|--------|--------|
| Use `nat_gateway_enabled = false` + VPC endpoints | -\$65/month |
| Use single NAT GW (`single_nat_gateway = true`) | -\$33/month vs HA |
| Use `db_multi_az = false` | -\$14/month |
| Use t3.micro within Free Tier (first 12 months) | -\$16/month |
| Reduce VPC endpoints to SSM-only (3 endpoints) | -\$22/month |

**Minimum viable deployment (1 AZ, single NAT, single-AZ RDS):**
~\$70/month

---

## Cleanup Reminder

Always destroy infrastructure after the demo:

```powershell
cd terraform
terraform destroy -var-file="terraform.tfvars"
```

Verify in the AWS Billing console that no resources remain.
