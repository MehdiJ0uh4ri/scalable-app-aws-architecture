#!/bin/bash
# =============================================================================
# scripts/user_data.sh
# EC2 instance initialisation script (runs as root on first boot).
#
# This script is rendered by Terraform templatefile().
# Bash variables use double-dollar to escape Terraform interpolation.
# Terraform-injected values use single-dollar syntax in the template.
# =============================================================================

set -euo pipefail

LOG_FILE="/var/log/user_data.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Task Manager EC2 Initialisation ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# IMDSv2 token
IMDS_TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" \
    http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" \
    http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || echo "unknown")

echo "Instance ID: $${INSTANCE_ID}"
echo "AZ: $${AZ}"

# ---------------------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------------------
echo "--- Updating system packages ---"
dnf update -y --quiet

# ---------------------------------------------------------------------------
# 2. Install runtime dependencies
# ---------------------------------------------------------------------------
echo "--- Installing Python, pip, git ---"
dnf install -y python3.12 python3.12-pip git --quiet

# ---------------------------------------------------------------------------
# 3. Create application user and directory
# ---------------------------------------------------------------------------
echo "--- Creating app user ---"
useradd -r -s /sbin/nologin appuser || true
mkdir -p /opt/taskmanager
chown appuser:appuser /opt/taskmanager

# ---------------------------------------------------------------------------
# 4. Install Python packages
# ---------------------------------------------------------------------------
echo "--- Installing Python packages ---"
python3.12 -m pip install --upgrade pip --quiet
python3.12 -m pip install \
    flask gunicorn sqlalchemy flask-sqlalchemy psycopg2-binary \
    python-dotenv requests flask-migrate \
    --quiet

# ---------------------------------------------------------------------------
# 5. Retrieve database credentials from Secrets Manager
# ---------------------------------------------------------------------------
echo "--- Retrieving DB credentials from Secrets Manager ---"

SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "${db_secret_name}" \
    --region "${aws_region}" \
    --query SecretString \
    --output text 2>/dev/null || echo '{}')

DB_HOST=$(echo "$${SECRET_JSON}" | python3.12 -c "import sys,json; d=json.load(sys.stdin); print(d.get('host','localhost'))")
DB_PORT=$(echo "$${SECRET_JSON}" | python3.12 -c "import sys,json; d=json.load(sys.stdin); print(d.get('port',5432))")
DB_NAME=$(echo "$${SECRET_JSON}" | python3.12 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dbname','taskdb'))")
DB_USER=$(echo "$${SECRET_JSON}" | python3.12 -c "import sys,json; d=json.load(sys.stdin); print(d.get('username','taskadmin'))")
DB_PASS=$(echo "$${SECRET_JSON}" | python3.12 -c "import sys,json; d=json.load(sys.stdin); print(d.get('password',''))")

# ---------------------------------------------------------------------------
# 6. Write environment file
# ---------------------------------------------------------------------------
echo "--- Writing environment configuration ---"
SECRET_KEY=$(openssl rand -hex 32)

cat > /opt/taskmanager/.env << ENVEOF
FLASK_ENV=production
DATABASE_URL=postgresql://$${DB_USER}:$${DB_PASS}@$${DB_HOST}:$${DB_PORT}/$${DB_NAME}
SECRET_KEY=$${SECRET_KEY}
INSTANCE_ID=$${INSTANCE_ID}
AVAILABILITY_ZONE=$${AZ}
AWS_REGION=${aws_region}
APP_VERSION=${app_version}
APP_NAME=task-manager
LOG_LEVEL=INFO
GUNICORN_WORKERS=4
ENVEOF

chmod 600 /opt/taskmanager/.env
chown appuser:appuser /opt/taskmanager/.env

# ---------------------------------------------------------------------------
# 7. Create systemd service
# ---------------------------------------------------------------------------
echo "--- Creating systemd service ---"
mkdir -p /var/log/taskmanager
chown appuser:appuser /var/log/taskmanager

cat > /etc/systemd/system/taskmanager.service << 'SYSTEMD_EOF'
[Unit]
Description=Task Manager Gunicorn Application
After=network.target

[Service]
Type=exec
User=appuser
Group=appuser
WorkingDirectory=/opt/taskmanager
EnvironmentFile=/opt/taskmanager/.env
ExecStart=/usr/local/bin/gunicorn \
    --workers 4 \
    --bind 0.0.0.0:APP_PORT_PLACEHOLDER \
    --timeout 120 \
    --access-logfile /var/log/taskmanager/access.log \
    --error-logfile /var/log/taskmanager/error.log \
    wsgi:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

# Replace the placeholder with the actual port (Terraform-substituted)
sed -i "s/APP_PORT_PLACEHOLDER/${app_port}/g" /etc/systemd/system/taskmanager.service

systemctl daemon-reload
systemctl enable taskmanager
systemctl start taskmanager || echo "Service start deferred (app code not yet deployed)"

# ---------------------------------------------------------------------------
# 8. Install CloudWatch Agent
# ---------------------------------------------------------------------------
echo "--- Installing CloudWatch Agent ---"
dnf install -y amazon-cloudwatch-agent --quiet || true

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWEOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/taskmanager/app.log",
            "log_group_name": "/aws/ec2/${name_prefix}/application",
            "log_stream_name": "{instance_id}",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          },
          {
            "file_path": "/var/log/taskmanager/access.log",
            "log_group_name": "/aws/ec2/${name_prefix}/access",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/user_data.log",
            "log_group_name": "/aws/ec2/${name_prefix}/user-data",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "${name_prefix}",
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["disk_used_percent"], "resources": ["/"] }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
    -s || true

echo "=== Initialisation complete ==="
