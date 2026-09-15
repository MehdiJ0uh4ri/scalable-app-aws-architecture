"""
application/app/utils/metadata.py
EC2 Instance Metadata Service v2 (IMDSv2) helper.

IMDSv2 is used instead of IMDSv1 because it requires a session token and is
therefore resistant to SSRF attacks — an important security improvement
mandated by AWS best practices.

On non-EC2 environments (local development, CI), all calls return safe fallback
values so the application starts normally without an IMDS endpoint.
"""

import logging
import os

import requests

logger = logging.getLogger(__name__)

# IMDSv2 endpoint (only reachable from inside an EC2 instance)
_IMDS_BASE = "http://169.254.169.254/latest"
_IMDS_TOKEN_TTL = 21600  # 6 hours in seconds
_IMDS_TIMEOUT = 1  # Short timeout — fail fast on non-EC2 hosts


def _get_imds_token() -> str | None:
    """Acquire an IMDSv2 session token."""
    try:
        response = requests.put(
            f"{_IMDS_BASE}/api/token",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": str(_IMDS_TOKEN_TTL)},
            timeout=_IMDS_TIMEOUT,
        )
        response.raise_for_status()
        return response.text
    except Exception as exc:
        logger.debug("IMDS token request failed (expected outside EC2): %s", exc)
        return None


def _get_imds_value(path: str, token: str) -> str | None:
    """Retrieve a single metadata value using an existing IMDSv2 token."""
    try:
        response = requests.get(
            f"{_IMDS_BASE}/meta-data/{path}",
            headers={"X-aws-ec2-metadata-token": token},
            timeout=_IMDS_TIMEOUT,
        )
        response.raise_for_status()
        return response.text
    except Exception as exc:
        logger.debug("IMDS value request failed for %s: %s", path, exc)
        return None


def get_instance_metadata() -> dict:
    """
    Return EC2 instance metadata.

    Falls back to environment variables (injected by launch template user-data
    or SSM parameter store), then to 'unknown' — so local development works
    without any AWS connectivity.
    """
    # Try environment variables first (set by user-data script on EC2)
    instance_id = os.getenv("INSTANCE_ID")
    availability_zone = os.getenv("AVAILABILITY_ZONE")
    region = os.getenv("AWS_REGION", "eu-west-3")

    if not instance_id:
        # Attempt live IMDSv2 query
        token = _get_imds_token()
        if token:
            instance_id = _get_imds_value("instance-id", token)
            availability_zone = _get_imds_value("placement/availability-zone", token)
            if availability_zone and not region:
                # AZ is like "eu-west-3a"; strip the trailing letter for the region
                region = availability_zone[:-1]

    return {
        "instance_id": instance_id or "local-dev",
        "availability_zone": availability_zone or "local",
        "region": region,
    }
