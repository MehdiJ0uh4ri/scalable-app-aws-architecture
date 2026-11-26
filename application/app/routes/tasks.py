"""
application/app/routes/tasks.py
CRUD endpoints for the Task resource.

REST design:
  GET    /api/tasks          → list all tasks (with optional filters)
  POST   /api/tasks          → create a task
  GET    /api/tasks/<id>     → get a single task
  PUT    /api/tasks/<id>     → replace a task (full update)
  PATCH  /api/tasks/<id>     → partial update
  DELETE /api/tasks/<id>     → delete a task

All handlers are stateless — they read/write only the shared RDS database.
Any healthy EC2 instance behind the ALB can process any request.
"""

import logging

from flask import Blueprint, jsonify, request
from sqlalchemy.exc import SQLAlchemyError

from app import db
from app.models.task import Task, TaskStatus

logger = logging.getLogger(__name__)

tasks_bp = Blueprint("tasks", __name__)

# ---------------------------------------------------------------------------
# Allowed values for validation
# ---------------------------------------------------------------------------
VALID_STATUSES = {s.value for s in TaskStatus}
VALID_PRIORITIES = {"low", "medium", "high"}


# ---------------------------------------------------------------------------
# Helper: standardised error response
# ---------------------------------------------------------------------------

def _error(message: str, status: int = 400) -> tuple:
    return jsonify({"error": message}), status


def _not_found(task_id: int) -> tuple:
    return _error(f"Task with id={task_id} not found.", 404)


# ---------------------------------------------------------------------------
# GET /api/tasks
# ---------------------------------------------------------------------------

@tasks_bp.route("", methods=["GET"])
def list_tasks():
    """
    Return all tasks.

    Optional query parameters:
      ?status=pending|in_progress|completed|cancelled
      ?priority=low|medium|high
    """
    query = db.select(Task)

    status_filter = request.args.get("status")
    if status_filter:
        if status_filter not in VALID_STATUSES:
            return _error(f"Invalid status '{status_filter}'. Valid: {VALID_STATUSES}")
        query = query.where(Task.status == status_filter)

    priority_filter = request.args.get("priority")
    if priority_filter:
        if priority_filter not in VALID_PRIORITIES:
            return _error(f"Invalid priority '{priority_filter}'. Valid: {VALID_PRIORITIES}")
        query = query.where(Task.priority == priority_filter)

    tasks = db.session.execute(query.order_by(Task.created_at.desc())).scalars().all()
    return jsonify({"tasks": [t.to_dict() for t in tasks], "count": len(tasks)})


# ---------------------------------------------------------------------------
# POST /api/tasks
# ---------------------------------------------------------------------------

@tasks_bp.route("", methods=["POST"])
def create_task():
    """Create a new task."""
    data = request.get_json(silent=True)
    if not data:
        return _error("Request body must be valid JSON.")

    title = data.get("title", "").strip()
    if not title:
        return _error("'title' is required and must not be empty.")

    status = data.get("status", TaskStatus.PENDING.value)
    if status not in VALID_STATUSES:
        return _error(f"Invalid status '{status}'. Valid: {VALID_STATUSES}")

    priority = data.get("priority", "medium")
    if priority not in VALID_PRIORITIES:
        return _error(f"Invalid priority '{priority}'. Valid: {VALID_PRIORITIES}")

    task = Task(
        title=title,
        description=data.get("description"),
        status=TaskStatus(status),
        priority=priority,
    )

    try:
        db.session.add(task)
        db.session.commit()
        logger.info("Task created: id=%s title=%r", task.id, task.title)
        return jsonify(task.to_dict()), 201
    except SQLAlchemyError as exc:
        db.session.rollback()
        logger.error("Failed to create task: %s", exc)
        return _error("Database error while creating task.", 500)


# ---------------------------------------------------------------------------
# GET /api/tasks/<id>
# ---------------------------------------------------------------------------

@tasks_bp.route("/<int:task_id>", methods=["GET"])
def get_task(task_id: int):
    """Return a single task by ID."""
    task = db.session.get(Task, task_id)
    if task is None:
        return _not_found(task_id)
    return jsonify(task.to_dict())


# ---------------------------------------------------------------------------
# PUT /api/tasks/<id>
# ---------------------------------------------------------------------------

@tasks_bp.route("/<int:task_id>", methods=["PUT"])
def update_task(task_id: int):
    """Full replacement of a task (all fields required)."""
    task = db.session.get(Task, task_id)
    if task is None:
        return _not_found(task_id)

    data = request.get_json(silent=True)
    if not data:
        return _error("Request body must be valid JSON.")

    title = data.get("title", "").strip()
    if not title:
        return _error("'title' is required.")

    status = data.get("status", TaskStatus.PENDING.value)
    if status not in VALID_STATUSES:
        return _error(f"Invalid status '{status}'.")

    priority = data.get("priority", "medium")
    if priority not in VALID_PRIORITIES:
        return _error(f"Invalid priority '{priority}'.")

    task.title = title
    task.description = data.get("description")
    task.status = TaskStatus(status)
    task.priority = priority

    try:
        db.session.commit()
        logger.info("Task updated (PUT): id=%s", task_id)
        return jsonify(task.to_dict())
    except SQLAlchemyError as exc:
        db.session.rollback()
        logger.error("Failed to update task %s: %s", task_id, exc)
        return _error("Database error while updating task.", 500)


# ---------------------------------------------------------------------------
# PATCH /api/tasks/<id>
# ---------------------------------------------------------------------------

@tasks_bp.route("/<int:task_id>", methods=["PATCH"])
def partial_update_task(task_id: int):
    """Partial update — only provided fields are changed."""
    task = db.session.get(Task, task_id)
    if task is None:
        return _not_found(task_id)

    data = request.get_json(silent=True)
    if not data:
        return _error("Request body must be valid JSON.")

    if "title" in data:
        title = data["title"].strip()
        if not title:
            return _error("'title' must not be empty.")
        task.title = title

    if "description" in data:
        task.description = data["description"]

    if "status" in data:
        status = data["status"]
        if status not in VALID_STATUSES:
            return _error(f"Invalid status '{status}'.")
        task.status = TaskStatus(status)

    if "priority" in data:
        priority = data["priority"]
        if priority not in VALID_PRIORITIES:
            return _error(f"Invalid priority '{priority}'.")
        task.priority = priority

    try:
        db.session.commit()
        logger.info("Task updated (PATCH): id=%s", task_id)
        return jsonify(task.to_dict())
    except SQLAlchemyError as exc:
        db.session.rollback()
        logger.error("Failed to patch task %s: %s", task_id, exc)
        return _error("Database error while updating task.", 500)


# ---------------------------------------------------------------------------
# DELETE /api/tasks/<id>
# ---------------------------------------------------------------------------

@tasks_bp.route("/<int:task_id>", methods=["DELETE"])
def delete_task(task_id: int):
    """Delete a task permanently."""
    task = db.session.get(Task, task_id)
    if task is None:
        return _not_found(task_id)

    try:
        db.session.delete(task)
        db.session.commit()
        logger.info("Task deleted: id=%s", task_id)
        return jsonify({"message": f"Task {task_id} deleted successfully."}), 200
    except SQLAlchemyError as exc:
        db.session.rollback()
        logger.error("Failed to delete task %s: %s", task_id, exc)
        return _error("Database error while deleting task.", 500)
