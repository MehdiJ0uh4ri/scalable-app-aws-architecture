"""
application/tests/test_config.py
Configuration validation tests.
"""

import pytest
from app.config import config_map, DevelopmentConfig, TestingConfig, ProductionConfig


class TestConfigMapping:
    def test_all_keys_present(self):
        for key in ("development", "testing", "production", "dev", "test", "prod"):
            assert key in config_map

    def test_testing_uses_in_memory_db(self):
        assert ":memory:" in TestingConfig.SQLALCHEMY_DATABASE_URI

    def test_testing_has_no_debug_false(self):
        # Testing config should have DEBUG=True for detailed errors
        assert TestingConfig.DEBUG is True

    def test_development_debug_enabled(self):
        assert DevelopmentConfig.DEBUG is True

    def test_production_debug_disabled(self):
        assert ProductionConfig.DEBUG is False


class TestProductionValidation:
    def test_validate_raises_when_missing_vars(self, monkeypatch):
        monkeypatch.delenv("SECRET_KEY", raising=False)
        monkeypatch.delenv("DATABASE_URL", raising=False)
        with pytest.raises(EnvironmentError):
            ProductionConfig.validate()

    def test_validate_passes_when_vars_present(self, monkeypatch):
        monkeypatch.setenv("SECRET_KEY", "supersecret")
        monkeypatch.setenv("DATABASE_URL", "postgresql://user:pass@host/db")
        # Should not raise
        ProductionConfig.validate()
