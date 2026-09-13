"""
application/app/__init__.py
Application factory for the Task Manager Flask application.

Using the application factory pattern allows the app to be created with
different configurations (development, testing, production) without global state.
"""

import logging
import os
from logging.handlers import RotatingFileHandler

from flask import Flask
from flask_migrate import Migrate
from flask_sqlalchemy import SQLAlchemy

# ---------------------------------------------------------------------------
# Extension instances (created here, bound to app in create_app())
# ---------------------------------------------------------------------------
db = SQLAlchemy()
migrate = Migrate()


def create_app(config_name: str | None = None) -> Flask:
    """
    Application factory.

    Args:
        config_name: One of 'development', 'testing', 'production'.
                     Falls back to FLASK_ENV environment variable, then 'development'.

    Returns:
        Configured Flask application instance.
    """
    app = Flask(__name__)

    # ------------------------------------------------------------------
    # Load configuration
    # ------------------------------------------------------------------
    from app.config import config_map

    if config_name is None:
        config_name = os.getenv("FLASK_ENV", "development")

    app.config.from_object(config_map[config_name])

    # ------------------------------------------------------------------
    # Initialise extensions
    # ------------------------------------------------------------------
    db.init_app(app)
    migrate.init_app(app, db)

    # ------------------------------------------------------------------
    # Register blueprints
    # ------------------------------------------------------------------
    from app.routes.tasks import tasks_bp
    from app.routes.health import health_bp

    app.register_blueprint(tasks_bp, url_prefix="/api/tasks")
    app.register_blueprint(health_bp)

    # ------------------------------------------------------------------
    # Configure logging
    # ------------------------------------------------------------------
    _configure_logging(app)

    # ------------------------------------------------------------------
    # Create database tables (development / testing convenience)
    # ------------------------------------------------------------------
    with app.app_context():
        db.create_all()

    app.logger.info(
        "Task Manager application started [env=%s]", config_name
    )
    return app


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _configure_logging(app: Flask) -> None:
    """Configure application-level logging."""
    log_level = getattr(logging, app.config.get("LOG_LEVEL", "INFO"), logging.INFO)

    formatter = logging.Formatter(
        "[%(asctime)s] %(levelname)s in %(module)s: %(message)s"
    )

    # Stream handler (stdout → CloudWatch Logs via the agent)
    stream_handler = logging.StreamHandler()
    stream_handler.setLevel(log_level)
    stream_handler.setFormatter(formatter)

    # Rotating file handler for local development
    if app.config.get("LOG_TO_FILE"):
        os.makedirs("logs", exist_ok=True)
        file_handler = RotatingFileHandler(
            "logs/app.log", maxBytes=10_485_760, backupCount=5
        )
        file_handler.setLevel(log_level)
        file_handler.setFormatter(formatter)
        app.logger.addHandler(file_handler)

    app.logger.addHandler(stream_handler)
    app.logger.setLevel(log_level)
    app.logger.propagate = False
