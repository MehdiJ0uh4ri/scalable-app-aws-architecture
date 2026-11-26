# Project Overview — Scalable Web Application with ALB and Auto Scaling

## Executive Summary

The **Scalable Web Application with ALB and Auto Scaling** project is an enterprise-grade, cloud-native reference architecture designed for the AWS Solutions Architect Associate graduation milestone.

It demonstrates end-to-end implementation of an EC2-based web tier that is resilient, highly available, secure, and dynamically scalable in response to real-world traffic fluctuations.

---

## Technical Identity & Specifications

| Dimension | Specification |
| :--- | :--- |
| **Project Title** | Scalable Web Application with ALB and Auto Scaling |
| **Target AWS Region** | `eu-west-3` (Paris) |
| **Availability Zones** | `eu-west-3a`, `eu-west-3b` |
| **Application Layer** | Python 3.12, Flask 3.1, Gunicorn 23.0 WSGI |
| **Data Persistence** | Amazon RDS PostgreSQL 16 (Multi-AZ Deployment) |
| **ORM / Data Access** | SQLAlchemy 2.0 / Flask-SQLAlchemy |
| **Infrastructure as Code** | Terraform (HashiCorp AWS Provider ~> 5.80) |
| **Security & Edge** | AWS WAFv2 (Global & Regional), Amazon CloudFront, AWS Secrets Manager |
| **Management & Shell** | AWS Systems Manager (SSM) Session Manager (Zero Bastion / Zero SSH Key) |
| **Operating System** | Target Host: Amazon Linux 2023; Development: Windows 11 |
| **Architecture Diagrams** | Draw.io SVG ([`architecture.svg`](../architecture/architecture.svg)) & Draw.io Model ([`architecture.drawio`](../architecture/architecture.drawio)) |

---

## Business Problem & Motivations

Modern web systems must handle unpredictable usage patterns while maintaining strict SLAs for uptime, data integrity, and low response latency. Common architectural pitfalls include:

1. **Monolithic Single-Point-of-Failure (SPOF):** Running an application and database on a single virtual machine leaves systems vulnerable to underlying hardware outages and datacenter incidents.
2. **Static Resource Allocation:** Fixed compute capacity either results in dropped requests during traffic spikes or wasted budget during idle hours.
3. **Insecure Exposure:** Exposing application compute or databases directly to public subnets with open SSH ports creates a wide attack surface susceptible to credential bruteforcing and zero-day vulnerabilities.
4. **Stateful Compute Traps:** Storing user state or persistent files on local instance storage breaks load balancing and prevents elastic scale-in/scale-out.

---

## Architectural Objectives

This architecture addresses these challenges by implementing:

- **Stateless Application Compute:** All business logic runs in stateless Python Flask processes across multiple EC2 instances. Any instance can process any request.
- **Dynamic Horizontal Elasticity:** AWS Auto Scaling Groups (ASG) monitor CPU utilization and ALB target request rates, scaling compute capacity automatically between 2 and 6 instances.
- **Multi-AZ Fault Tolerance:** Every critical tier (ALB, Compute, RDS Database) spans two independent Availability Zones in `eu-west-3`.
- **Zero-Trust Network Partitioning:** Strict multi-tier subnet boundaries (Public, Private Application, Private Database) isolated by stateless Network ACLs and stateful Security Groups.
- **Bastionless Operations:** Remote administration takes place exclusively via AWS Systems Manager Session Manager, removing public SSH ports (22) and SSH key management overhead.
- **Automated Secrets Lifecycle:** Database credentials are generated, stored, and retrieved via AWS Secrets Manager with IAM authorization, avoiding plaintext credentials in source control or startup scripts.
