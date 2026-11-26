"""
application/tests/test_models.py
Unit tests for the Task model and its serialisation.
"""

from app.models.task import Task, TaskStatus


class TestTaskModel:
    """Tests for the Task SQLAlchemy model."""

    def test_task_creation(self, app):
        with app.app_context():
            task = Task(title="Test", status=TaskStatus.PENDING, priority="medium")
            assert task.title == "Test"
            assert task.status == TaskStatus.PENDING
            assert task.priority == "medium"

    def test_to_dict_structure(self, app):
        with app.app_context():
            task = Task(title="Dict Test", status=TaskStatus.IN_PROGRESS, priority="high")
            d = task.to_dict()
            expected_keys = {"id", "title", "description", "status", "priority", "created_at", "updated_at"}
            assert expected_keys == set(d.keys())

    def test_to_dict_status_is_string(self, app):
        with app.app_context():
            task = Task(title="Status Test", status=TaskStatus.COMPLETED, priority="low")
            assert task.to_dict()["status"] == "completed"

    def test_task_status_enum_values(self):
        assert TaskStatus.PENDING.value == "pending"
        assert TaskStatus.IN_PROGRESS.value == "in_progress"
        assert TaskStatus.COMPLETED.value == "completed"
        assert TaskStatus.CANCELLED.value == "cancelled"

    def test_task_repr(self, app):
        with app.app_context():
            task = Task(title="Repr Test", status=TaskStatus.PENDING, priority="low")
            assert "Repr Test" in repr(task)


class TestTaskPersistence:
    """Integration tests that write to the in-memory SQLite database."""

    def test_create_and_retrieve(self, db, app):
        with app.app_context():
            from app import db as _db
            task = Task(title="Persistent Task", status=TaskStatus.PENDING, priority="medium")
            _db.session.add(task)
            _db.session.commit()

            retrieved = _db.session.get(Task, task.id)
            assert retrieved is not None
            assert retrieved.title == "Persistent Task"

    def test_delete_task(self, db, app):
        with app.app_context():
            from app import db as _db
            task = Task(title="Delete Me", status=TaskStatus.PENDING, priority="low")
            _db.session.add(task)
            _db.session.commit()
            task_id = task.id

            _db.session.delete(task)
            _db.session.commit()

            assert _db.session.get(Task, task_id) is None
