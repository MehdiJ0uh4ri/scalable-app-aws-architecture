"""
application/tests/test_health.py
Tests for the /health and /info endpoints.
"""

import pytest


class TestHealthEndpoint:
    """Tests for GET /health"""

    def test_health_returns_200(self, client):
        response = client.get("/health")
        assert response.status_code == 200

    def test_health_response_structure(self, client):
        data = client.get("/health").get_json()
        assert "status" in data
        assert "checks" in data
        assert "version" in data
        assert "instance_id" in data
        assert "availability_zone" in data

    def test_health_status_is_healthy(self, client):
        data = client.get("/health").get_json()
        assert data["status"] == "healthy"

    def test_health_database_check_passes(self, client):
        data = client.get("/health").get_json()
        assert data["checks"]["database"] == "healthy"

    def test_health_app_check_passes(self, client):
        data = client.get("/health").get_json()
        assert data["checks"]["app"] == "healthy"


class TestInfoEndpoint:
    """Tests for GET /info and GET /version"""

    def test_info_returns_200(self, client):
        assert client.get("/info").status_code == 200

    def test_version_alias_returns_200(self, client):
        assert client.get("/version").status_code == 200

    def test_info_structure(self, client):
        data = client.get("/info").get_json()
        assert "app_name" in data
        assert "version" in data
        assert "instance_id" in data
        assert "availability_zone" in data
        assert "region" in data

    def test_info_app_name(self, client):
        data = client.get("/info").get_json()
        assert data["app_name"] == "task-manager"


class TestRootEndpoint:
    """Tests for GET /"""

    def test_root_returns_200(self, client):
        assert client.get("/").status_code == 200

    def test_root_contains_links(self, client):
        data = client.get("/").get_json()
        assert "health" in data
        assert "docs" in data
