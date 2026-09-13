"""
application/app/config.py
Configuration classes for different environments.

Design decision: class-based configuration keeps related settings together and
makes it easy to override a single value for a specific environment without
duplicating everything.
"""

import os


class BaseConfig:
    """Shared settings inherited by all environments."""

    # Flask core
    SECRET_KEY: str = os.getenv("SECRET_KEY", "dev-only-insecure-key-change-me")
    JSON_SORT_KEYS: bool = False

    # Database
    SQLALCHEMY_TRACK_MODIFICATIONS: bool = False
    SQLALCHEMY_DATABASE_URI: str = os.getenv(
        "DATABASE_URL", "sqlite:///tasks.db"
    )

    # Application metadata
    APP_VERSION: str = os.getenv("APP_VERSION", "1.0.0")
    APP_NAME: str = os.getenv("APP_NAME", "task-manager")

    # Logging
    LOG_LEVEL: str = os.getenv("LOG_LEVEL", "INFO")
    LOG_TO_FILE: bool = False


class DevelopmentConfig(BaseConfig):
    """Local development configuration."""

    DEBUG: bool = True
    LOG_LEVEL: str = "DEBUG"
    LOG_TO_FILE: bool = True


class TestingConfig(BaseConfig):
    """Test-runner configuration.

    Uses an in-memory SQLite database so tests are fast and isolated.
    """

    TESTING: bool = True
    DEBUG: bool = True
    # In-memory SQLite — no file left on disk after the test session
    SQLALCHEMY_DATABASE_URI: str = "sqlite:///:memory:"
    # Disable CSRF protection in tests
    WTF_CSRF_ENABLED: bool = False


class ProductionConfig(BaseConfig):
    """Production (EC2 / AWS) configuration.

    DATABASE_URL must be injected via an environment variable (e.g. from
    AWS Secrets Manager via the Systems Manager parameter store or a startup
    script). The application will refuse to start if it is missing.
    """

    DEBUG: bool = False

    @classmethod
    def validate(cls) -> None:
        """Raise if required production settings are absent."""
        required = ["SECRET_KEY", "DATABASE_URL"]
        missing = [k for k in required if not os.getenv(k)]
        if missing:
            raise EnvironmentError(
                f"Missing required environment variables for production: {missing}"
            )


# Registry used by the application factory
config_map = {
    "development": DevelopmentConfig,
    "testing": TestingConfig,
    "production": ProductionConfig,
    # Alias so FLASK_ENV=dev also works
    "dev": DevelopmentConfig,
    "test": TestingConfig,
    "prod": ProductionConfig,
}
