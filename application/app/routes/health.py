"""
application/app/routes/health.py
Health-check and instance-info endpoints.

The /health endpoint is polled by the ALB target group health check every
30 seconds. It must return HTTP 200 quickly; any non-200 response causes the
ALB to mark the instance as unhealthy and stop sending traffic to it.

The /info endpoint exposes which EC2 instance and AZ served the request —
useful for demonstrating that the ALB distributes load across multiple
instances in different AZs.
"""

import logging
import os

from flask import Blueprint, current_app, jsonify

from app import db
from app.utils.metadata import get_instance_metadata

logger = logging.getLogger(__name__)

health_bp = Blueprint("health", __name__)


@health_bp.route("/health", methods=["GET"])
def health():
    """
    ALB health-check endpoint.

    Checks:
      1. The Flask application is responding.
      2. The database can be reached (a simple scalar query).

    Returns HTTP 200 when healthy, HTTP 503 when any check fails.
    The ALB routes traffic only to healthy instances.
    """
    checks = {
        "app": "healthy",
        "database": "unknown",
    }
    overall_status = "healthy"
    http_status = 200

    # --- Database connectivity check ---
    try:
        db.session.execute(db.text("SELECT 1"))
        checks["database"] = "healthy"
    except Exception as exc:
        logger.error("Health check — database unreachable: %s", exc)
        checks["database"] = "unhealthy"
        overall_status = "unhealthy"
        http_status = 503

    metadata = get_instance_metadata()

    return (
        jsonify(
            {
                "status": overall_status,
                "checks": checks,
                "version": current_app.config.get("APP_VERSION", "1.0.0"),
                "instance_id": metadata["instance_id"],
                "availability_zone": metadata["availability_zone"],
                "region": metadata["region"],
            }
        ),
        http_status,
    )


@health_bp.route("/info", methods=["GET"])
@health_bp.route("/version", methods=["GET"])
def info():
    """
    Instance and application information endpoint.

    Returns metadata about the serving EC2 instance so you can observe
    traffic being distributed across instances in different AZs.
    """
    metadata = get_instance_metadata()
    return jsonify(
        {
            "app_name": current_app.config.get("APP_NAME", "task-manager"),
            "version": current_app.config.get("APP_VERSION", "1.0.0"),
            "environment": os.getenv("FLASK_ENV", "development"),
            "instance_id": metadata["instance_id"],
            "availability_zone": metadata["availability_zone"],
            "region": metadata["region"],
        }
    )


@health_bp.route("/", methods=["GET"])
def index():
    """Root endpoint — returns a friendly welcome message."""
    return jsonify(
        {
            "message": "Task Manager API is running.",
            "docs": "/api/tasks",
            "health": "/health",
            "info": "/info",
        }
    )
