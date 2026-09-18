"""
application/tests/conftest.py
Pytest configuration and shared fixtures.

The testing configuration uses an in-memory SQLite database so tests:
  - Run fast (no network I/O)
  - Are isolated (each session gets a fresh schema)
  - Require no running PostgreSQL instance
"""

import pytest

from app import create_app, db as _db


@pytest.fixture(scope="session")
def app():
    """Create a Flask application configured for testing (session-scoped)."""
    _app = create_app("testing")
    return _app


@pytest.fixture(scope="session")
def db(app):
    """Create all tables once per test session, drop them on teardown."""
    with app.app_context():
        _db.create_all()
        yield _db
        _db.drop_all()


@pytest.fixture(scope="function")
def db_session(db, app):
    """
    Provide a clean database session for each test function.

    Uses a nested transaction (SAVEPOINT) so each test can rollback any
    changes without truncating tables.
    """
    with app.app_context():
        connection = db.engine.connect()
        transaction = connection.begin()
        # Bind the session to this connection
        db.session.bind = connection  # type: ignore[attr-defined]
        yield db.session
        db.session.remove()
        transaction.rollback()
        connection.close()


@pytest.fixture(scope="function")
def client(app):
    """Return a Flask test client for HTTP-level testing."""
    with app.test_client() as c:
        with app.app_context():
            yield c


@pytest.fixture
def sample_task_data():
    """Return valid task payload."""
    return {
        "title": "Test Task",
        "description": "A task created in a test",
        "status": "pending",
        "priority": "medium",
    }


@pytest.fixture
def created_task(client, sample_task_data):
    """Create a task via the API and return the response JSON."""
    response = client.post(
        "/api/tasks",
        json=sample_task_data,
        content_type="application/json",
    )
    assert response.status_code == 201
    return response.get_json()
