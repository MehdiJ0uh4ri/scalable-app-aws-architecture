# Secure CI/CD Pipeline & Shift-Left Security Guide

## 1. Pipeline Overview

This repository implements a **Shift-Left Security CI/CD Pipeline** using GitHub Actions to automate code validation, vulnerability scanning, static security analysis, infrastructure planning, and controlled deployments.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           GitHub Actions Workflow Suite                         │
└──────────────────────────────────────┬──────────────────────────────────────────┘
                                       │
            ┌──────────────────────────┴──────────────────────────┐
            ▼                                                     ▼
┌───────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│   ci.yml (Pull Requests & Pushes)     │   │   deploy.yml (Workflow Dispatch)         │
├───────────────────────────────────────┤   ├──────────────────────────────────────────┤
│ 1. Shift-Left Security Gate           │   │ 1. Pre-Deployment Quality Gate           │
│    ├── Gitleaks (Secret Scanning)     │   │    └── Pytest (Min 80% Coverage)         │
│    ├── Bandit (Python SAST)           │   │ 2. Production Approval Gate              │
│    ├── pip-audit (Dependency SCA)     │   │    └── GitHub Environment Sign-off       │
│    └── Trivy (IaC Misconfigurations)  │   │ 3. Terraform Execution Engine            │
│ 2. Python Quality & Unit Tests        │   │    ├── Profile Selection (A vs B)        │
│    ├── Flake8 Code Style              │   │    └── Actions: plan / apply / destroy   │
│    └── Pytest (Coverage Gate >= 80%)  │   │ 4. Post-Deploy Verification              │
│ 3. Terraform Lint & Speculative Plan  │   │    └── Automated ALB /health Probe       │
│    ├── terraform fmt -check           │   └──────────────────────────────────────────┘
│    ├── terraform validate             │
│    └── PR Plan Comment Bot            │
└───────────────────────────────────────┘
```

---

## 2. Shift-Left Security Controls

Shift-Left security moves security inspections from post-deployment auditing directly into the developer's pull request workflow.

| Security Gate | Tool | Shift-Left Purpose | Enforcement Level |
| :--- | :--- | :--- | :--- |
| **Secret Detection** | **Gitleaks** | Prevents AWS keys, database passwords, or private keys from entering Git history. | **Blocking:** Fails build on secret detection. Configured via `.gitleaks.toml`. |
| **Python SAST** | **Bandit** | Scans Python AST for common vulnerabilities (SSRF, hardcoded secrets, dangerous subprocess calls). | **Blocking:** Alerts on Medium and High severity findings (`-ll -ii`). |
| **Dependency SCA** | **pip-audit** | Checks `requirements.txt` against PyPI advisories and the National Vulnerability Database (NVD). | **Blocking:** Fails build if known CVEs exist in packages. |
| **IaC Security** | **Trivy** | Checks Terraform against CIS benchmarks, open security groups, and encryption rules. | **Warning / Non-blocking:** Surfaces high/critical alerts in GitHub security tab. |
| **Code Coverage** | **Pytest-Cov** | Enforces that tests cover at least 80% of application logic before merge. | **Blocking:** Fails build if coverage < 80%. |

---

## 3. GitHub Secrets Configuration

To enable the CI/CD pipeline, configure the following secrets in your GitHub repository:

**Path:** `Settings` → `Secrets and variables` → `Actions` → `New repository secret`

| Secret Name | Description | Example / Recommended Value |
| :--- | :--- | :--- |
| `AWS_ACCESS_KEY_ID` | IAM User Access Key ID with deployment permissions. | `AKIAIOSFODNN7EXAMPLE` |
| `AWS_SECRET_ACCESS_KEY` | IAM User Secret Access Key. | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` |
| `AWS_REGION` | Target AWS deployment region. | `eu-west-3` |
| `TF_VAR_DB_PASSWORD` | Strong master password for RDS PostgreSQL. | *Random 24-character alphanumeric string* |
| `TF_VAR_ALARM_EMAIL` | *(Optional)* Email address for CloudWatch alarm notifications. | `ops-alerts@yourdomain.com` |

---

## 4. Production Approval Gate (Environment Protection)

To prevent accidental deployments and avoid unwanted charges, the `deploy.yml` workflow is bound to the **`production`** GitHub Environment.

### How to Configure Environment Approvals:
1. Navigate to your GitHub repository: **Settings** → **Environments**.
2. Click **New environment** and enter name: `production`.
3. Check **Required reviewers**.
4. Select your GitHub username as the required reviewer.
5. Click **Save protection rules**.

When someone triggers a deployment to `apply`, GitHub will pause execution and notify you via email and GitHub web UI for explicit approval before running `terraform apply`.

---

## 5. How to Deploy via CI/CD

The deployment pipeline is triggered manually via **GitHub Actions Workflow Dispatch**:

1. In GitHub, navigate to the **Actions** tab.
2. Select **CD & Automated Deployment** in the left sidebar.
3. Click **Run workflow**:
   - **Terraform Action:**
     - `plan` — Generates and previews the Terraform plan without making changes.
     - `apply` — Deploys the infrastructure to AWS and runs health checks.
     - `destroy` — Tears down all resources for cleanup.
   - **Architecture Profile:**
     - `Profile A (Zero Budget — No NAT GW)` — Dev profile; avoids NAT Gateway charges.
     - `Profile B (Full Graduation Architecture — With NAT GW)` — Full multi-AZ graduation topology.
4. Click **Run workflow**.

---

## 6. Least-Privilege IAM Policy for CI/CD

If creating a dedicated IAM user for GitHub Actions, attach a customer-managed policy restricted to the required services:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VPCAndNetworkingAccess",
      "Effect": "Allow",
      "Action": [
        "ec2:*Vpc*",
        "ec2:*Subnet*",
        "ec2:*RouteTable*",
        "ec2:*InternetGateway*",
        "ec2:*NatGateway*",
        "ec2:*SecurityGroup*",
        "ec2:*NetworkAcl*",
        "ec2:*Address*",
        "ec2:Describe*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ComputeAndLoadBalancingAccess",
      "Effect": "Allow",
      "Action": [
        "ec2:*LaunchTemplate*",
        "ec2:*Instance*",
        "autoscaling:*",
        "elasticloadbalancing:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DatabaseAccess",
      "Effect": "Allow",
      "Action": [
        "rds:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecurityAndSecretsAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:*",
        "wafv2:*",
        "iam:*Role*",
        "iam:*Policy*",
        "iam:*InstanceProfile*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "MonitoringAndEdgeAccess",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:*",
        "logs:*",
        "sns:*",
        "cloudfront:*",
        "route53:*"
      ],
      "Resource": "*"
    }
  ]
}
```
