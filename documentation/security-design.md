# Security Design

## Security Architecture Overview

This document describes the security controls applied at each layer of the architecture.

---

## Defence in Depth

Security controls are applied at multiple independent layers:

```
Internet
  → CloudFront (TLS termination, WAF edge protection)
  → ALB (WAF regional, HTTP→HTTPS redirect)
  → Security Groups (stateful, least-privilege)
  → Network ACLs (stateless, subnet-level)
  → EC2 (no public IP, no SSH, IMDSv2 enforced)
  → Application (input validation, parameterised queries)
  → RDS (private subnet, encrypted, SG-restricted)
```

---

## Identity & Access Management

### EC2 Instance Role (Least Privilege)
The IAM role attached to EC2 instances grants **only** what the application needs:

| Permission | Service | Why |
|-----------|---------|-----|
| `ssm:*` (managed) | Systems Manager | Session Manager shell access |
| `cloudwatch:*` (managed) | CloudWatch Agent | Publish metrics and logs |
| `secretsmanager:GetSecretValue` | Secrets Manager | Read DB password at boot |
| `ssm:GetParameter*` | Parameter Store | Read app configuration |

**What is NOT granted:**
- `ec2:*` — instances cannot create or modify EC2 resources
- `s3:*` — no S3 access unless specifically added
- `iam:*` — no IAM modification
- `AdministratorAccess` — never assigned to application roles

### No Hardcoded Credentials
- EC2 instances use **IAM instance profiles** — no access key/secret in code.
- Database password is stored in **Secrets Manager** and retrieved at runtime.
- No `.env` files with secrets are committed to Git.

---

## Network Security

### Security Groups (Stateful)

| Security Group | Inbound | From |
|---------------|---------|------|
| ALB SG | TCP 80, 443 | `0.0.0.0/0` (internet) |
| App SG | TCP 5000 | ALB SG only |
| DB SG | TCP 5432 | App SG only |
| VPC Endpoint SG | TCP 443 | App SG only |

**Key principle:** No resource accepts traffic from the internet except the ALB.

### Network ACLs (Stateless — additional layer)
- Public subnets: HTTP/HTTPS + ephemeral ports
- Private app subnets: app port from VPC + ephemeral return traffic
- Private DB subnets: PostgreSQL from VPC only

### No Public IPs on EC2
`map_public_ip_on_launch = false` on all private subnets.
EC2 instances are **unreachable from the internet** even if the security group were misconfigured.

---

## EC2 Instance Security

| Control | Implementation |
|---------|---------------|
| No SSH | No key pair on Launch Template |
| Shell access | SSM Session Manager (IAM-authenticated, fully audited) |
| IMDSv2 enforced | `http_tokens = "required"` — prevents SSRF metadata theft |
| IMDS hop limit | `http_put_response_hop_limit = 1` — prevents container escape |
| EBS encrypted | `encrypted = true` on all volumes |
| Instance metadata tags | Enabled — useful for tagging-based IAM conditions |

---

## Database Security

| Control | Implementation |
|---------|---------------|
| Private subnet | No internet route to DB subnets |
| No public access | `publicly_accessible = false` |
| SG restriction | Only App SG can connect on port 5432 |
| Encryption at rest | `storage_encrypted = true` |
| Credential rotation | Secrets Manager stores password (manual rotation ready) |
| Automated backups | 7-day retention, encrypted |

---

## Application Layer Security

| Control | Implementation |
|---------|---------------|
| Input validation | All API inputs validated before DB query |
| ORM (SQLAlchemy) | Parameterised queries prevent SQL injection |
| Error handling | Generic error messages — no stack traces to client |
| Stateless design | No session state on EC2 — any instance can serve any request |
| `SECRET_KEY` | Long random key set via environment variable |
| No debug mode | `DEBUG = False` in production config |

---

## WAF Protection

Two WAF web ACLs protect the application:

**CloudFront WAF (global, us-east-1):**
- Rate limiting: 2,000 requests per 5 minutes per IP
- AWS Managed Rules: Common Rule Set (OWASP Top 10)
- AWS Managed Rules: Known Bad Inputs
- AWS Managed Rules: SQL Injection

**Regional WAF (eu-west-3, attached to ALB):**
- Rate limiting: 2,000 requests per 5 minutes per IP
- AWS Managed Rules: Common Rule Set

---

## Secrets Management

| Secret | Storage | Access |
|--------|---------|--------|
| DB master password | Secrets Manager | EC2 IAM role (scoped by prefix) |
| Flask SECRET_KEY | Generated at boot (openssl rand) | Written to `/opt/taskmanager/.env` (mode 600) |
| AWS credentials | IAM instance profile | Never stored on disk |

---

## Git Security

`.gitignore` excludes:
- `*.tfvars` (Terraform variable files with real values)
- `.env` (application secrets)
- `*.pem`, `*.key`, `*.crt` (certificates and keys)
- `*.tfstate` (Terraform state — may contain resource ARNs and secrets)
- `credentials` (AWS credential files)

---

## Compliance Notes

| Requirement | Status |
|-------------|--------|
| Encryption in transit | ✅ HTTPS at CloudFront + ALB (TLS 1.2+) |
| Encryption at rest | ✅ EBS + RDS + SNS + Secrets Manager |
| No hardcoded credentials | ✅ All secrets via env vars or Secrets Manager |
| Least privilege IAM | ✅ Scoped custom policies |
| No public DB | ✅ Private subnet, no public IP |
| Audit trail | ✅ SSM Session Manager logs all commands |
| WAF | ✅ OWASP rules at CloudFront and ALB |
