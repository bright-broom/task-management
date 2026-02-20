"""
API Blueprint modules for M2X Task Management System.

This package contains Flask blueprints for different API domains:
- tasks: Task management endpoints
- auth: Authentication endpoints
"""

from flask import Blueprint

# Create blueprints
tasks_bp = Blueprint("tasks", __name__)
auth_bp = Blueprint("auth", __name__)


def register_blueprints(app: object) -> None:
    """
    Register all API blueprints with the Flask application.

    Args:
        app: Flask application instance
    """
    # Import routes here to avoid circular imports
    # Register with appropriate prefixes
    from flask import Flask

    from . import auth, tasks  # noqa: F401

    if isinstance(app, Flask):
        app.register_blueprint(tasks_bp)
        app.register_blueprint(auth_bp)
