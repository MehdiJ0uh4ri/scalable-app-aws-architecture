"""
application/tests/test_tasks.py
API endpoint tests for the /api/tasks resource.
"""

import pytest


class TestListTasks:
    """GET /api/tasks"""

    def test_returns_200(self, client):
        assert client.get("/api/tasks").status_code == 200

    def test_returns_list_structure(self, client):
        data = client.get("/api/tasks").get_json()
        assert "tasks" in data
        assert "count" in data
        assert isinstance(data["tasks"], list)

    def test_filter_by_valid_status(self, client, created_task):
        resp = client.get("/api/tasks?status=pending")
        assert resp.status_code == 200

    def test_filter_by_invalid_status_returns_400(self, client):
        resp = client.get("/api/tasks?status=banana")
        assert resp.status_code == 400

    def test_filter_by_priority(self, client, created_task):
        resp = client.get("/api/tasks?priority=medium")
        assert resp.status_code == 200


class TestCreateTask:
    """POST /api/tasks"""

    def test_creates_task_with_minimal_payload(self, client):
        resp = client.post("/api/tasks", json={"title": "Minimal Task"})
        assert resp.status_code == 201
        data = resp.get_json()
        assert data["title"] == "Minimal Task"
        assert data["status"] == "pending"
        assert data["priority"] == "medium"

    def test_creates_task_with_full_payload(self, client, sample_task_data):
        resp = client.post("/api/tasks", json=sample_task_data)
        assert resp.status_code == 201
        data = resp.get_json()
        assert data["title"] == sample_task_data["title"]
        assert data["description"] == sample_task_data["description"]

    def test_missing_title_returns_400(self, client):
        resp = client.post("/api/tasks", json={"description": "No title"})
        assert resp.status_code == 400

    def test_empty_title_returns_400(self, client):
        resp = client.post("/api/tasks", json={"title": "   "})
        assert resp.status_code == 400

    def test_invalid_status_returns_400(self, client):
        resp = client.post("/api/tasks", json={"title": "T", "status": "invalid"})
        assert resp.status_code == 400

    def test_invalid_priority_returns_400(self, client):
        resp = client.post("/api/tasks", json={"title": "T", "priority": "ultra"})
        assert resp.status_code == 400

    def test_no_body_returns_400(self, client):
        resp = client.post("/api/tasks", data="not json", content_type="text/plain")
        assert resp.status_code == 400

    def test_response_includes_id(self, client):
        resp = client.post("/api/tasks", json={"title": "ID Test"})
        assert "id" in resp.get_json()

    def test_response_includes_timestamps(self, client):
        data = client.post("/api/tasks", json={"title": "TS Test"}).get_json()
        assert "created_at" in data
        assert "updated_at" in data


class TestGetTask:
    """GET /api/tasks/<id>"""

    def test_returns_existing_task(self, client, created_task):
        task_id = created_task["id"]
        resp = client.get(f"/api/tasks/{task_id}")
        assert resp.status_code == 200
        assert resp.get_json()["id"] == task_id

    def test_nonexistent_task_returns_404(self, client):
        assert client.get("/api/tasks/999999").status_code == 404


class TestUpdateTask:
    """PUT /api/tasks/<id>"""

    def test_full_update(self, client, created_task):
        task_id = created_task["id"]
        payload = {
            "title": "Updated Title",
            "description": "Updated description",
            "status": "in_progress",
            "priority": "high",
        }
        resp = client.put(f"/api/tasks/{task_id}", json=payload)
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["title"] == "Updated Title"
        assert data["status"] == "in_progress"
        assert data["priority"] == "high"

    def test_nonexistent_task_returns_404(self, client):
        resp = client.put(
            "/api/tasks/999999",
            json={"title": "X", "status": "pending", "priority": "low"},
        )
        assert resp.status_code == 404


class TestPartialUpdateTask:
    """PATCH /api/tasks/<id>"""

    def test_partial_status_update(self, client, created_task):
        task_id = created_task["id"]
        resp = client.patch(f"/api/tasks/{task_id}", json={"status": "completed"})
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "completed"

    def test_partial_title_update(self, client, created_task):
        task_id = created_task["id"]
        resp = client.patch(f"/api/tasks/{task_id}", json={"title": "Patched"})
        assert resp.status_code == 200
        assert resp.get_json()["title"] == "Patched"

    def test_nonexistent_task_returns_404(self, client):
        resp = client.patch("/api/tasks/999999", json={"status": "completed"})
        assert resp.status_code == 404


class TestDeleteTask:
    """DELETE /api/tasks/<id>"""

    def test_deletes_task(self, client):
        # Create a fresh task to delete
        task = client.post("/api/tasks", json={"title": "To Delete"}).get_json()
        task_id = task["id"]

        resp = client.delete(f"/api/tasks/{task_id}")
        assert resp.status_code == 200

        # Verify it no longer exists
        assert client.get(f"/api/tasks/{task_id}").status_code == 404

    def test_nonexistent_task_returns_404(self, client):
        assert client.delete("/api/tasks/999999").status_code == 404
