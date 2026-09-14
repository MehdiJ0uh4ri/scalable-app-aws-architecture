"""
application/app/models/__init__.py
Package marker — imports all models so SQLAlchemy finds them during db.create_all().
"""

from app.models.task import Task  # noqa: F401
