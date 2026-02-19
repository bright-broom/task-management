"""
M2X課題 - 工場向けタスク管理システム Web API

このモジュールは工場タスク管理システムのREST APIを提供します。

主な機能:
- テナント管理
- 設備管理（階層構造対応）
- 部品管理（在庫・発注点管理）
- タスク管理（カスタムフィールド・コメント対応）

セキュリティ:
- Row Level Security (RLS) によるデータベースレベルでのテナント分離
- 入力バリデーション（UUID形式チェック、長さ制限）
- パラメータ化クエリによるSQLインジェクション防止
"""

from __future__ import annotations

import logging
import os
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from functools import wraps
from typing import Any, Callable, Generator, TypeVar

import psycopg2
from flask import Flask, Response, jsonify, render_template, request
from psycopg2.extras import RealDictCursor

# ============================================================================
# Type Definitions
# ============================================================================

F = TypeVar("F", bound=Callable[..., Any])

# ============================================================================
# Application Configuration
# ============================================================================

app = Flask(__name__)
app.config["JSON_AS_ASCII"] = False  # Support Japanese characters in JSON

# Logging configuration
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql://m2x_user:m2x_password@db:5432/m2x_task_management"
)

# ============================================================================
# Pagination Configuration
# ============================================================================

DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100


@dataclass
class PaginationParams:
    """Pagination parameters extracted from request."""

    page: int = 1
    per_page: int = DEFAULT_PAGE_SIZE
    sort_by: str | None = None
    sort_order: str = "asc"

    @classmethod
    def from_request(
        cls,
        default_sort: str | None = None,
        default_order: str = "desc",
    ) -> PaginationParams:
        """Extract pagination parameters from request args."""
        try:
            page = max(1, int(request.args.get("page", 1)))
        except (ValueError, TypeError):
            page = 1

        try:
            per_page = min(
                MAX_PAGE_SIZE, max(1, int(request.args.get("per_page", DEFAULT_PAGE_SIZE)))
            )
        except (ValueError, TypeError):
            per_page = DEFAULT_PAGE_SIZE

        sort_by = request.args.get("sort_by", default_sort)
        sort_order = request.args.get("sort_order", default_order)
        if sort_order not in ("asc", "desc"):
            sort_order = default_order

        return cls(page=page, per_page=per_page, sort_by=sort_by, sort_order=sort_order)

    @property
    def offset(self) -> int:
        """Calculate SQL offset."""
        return (self.page - 1) * self.per_page


# ============================================================================
# Database Utilities
# ============================================================================


@contextmanager
def get_db_connection() -> Generator[Any, None, None]:
    """
    Database connection context manager.

    Ensures connections are properly closed after use,
    preventing connection leaks.

    Yields:
        psycopg2 connection object with RealDictCursor
    """
    conn = None
    try:
        conn = psycopg2.connect(DATABASE_URL, cursor_factory=RealDictCursor)
        yield conn
    except psycopg2.Error as e:
        logger.error(f"Database connection error: {e}")
        raise
    finally:
        if conn:
            conn.close()


@contextmanager
def get_db_cursor(conn: Any) -> Generator[Any, None, None]:
    """
    Database cursor context manager.

    Args:
        conn: Database connection

    Yields:
        Database cursor
    """
    cur = conn.cursor()
    try:
        yield cur
    finally:
        cur.close()


@contextmanager
def tenant_context(conn: Any, tenant_id: str) -> Generator[Any, None, None]:
    """
    Set tenant context for Row Level Security.

    This sets the app.current_tenant_id session variable which is used
    by RLS policies to filter data to the current tenant.

    Args:
        conn: Database connection
        tenant_id: UUID of the current tenant

    Yields:
        Database cursor with tenant context set
    """
    with get_db_cursor(conn) as cur:
        # Set tenant context for RLS
        cur.execute("SET app.current_tenant_id = %s", (tenant_id,))
        yield cur
        # Reset tenant context
        cur.execute("RESET app.current_tenant_id")


# ============================================================================
# Validation Utilities
# ============================================================================


def is_valid_uuid(value: str) -> bool:
    """
    Validate if a string is a valid UUID.

    Args:
        value: String to validate

    Returns:
        True if valid UUID, False otherwise
    """
    try:
        uuid.UUID(str(value))
        return True
    except (ValueError, AttributeError):
        return False


def validate_uuid(param_name: str) -> Callable[[F], F]:
    """
    Decorator to validate UUID parameters.

    Args:
        param_name: Name of the parameter to validate

    Returns:
        Decorated function
    """

    def decorator(f: F) -> F:
        @wraps(f)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            param_value = kwargs.get(param_name)
            if param_value and not is_valid_uuid(param_value):
                return (
                    jsonify(
                        {
                            "error": "Invalid UUID format",
                            "parameter": param_name,
                            "value": param_value,
                        }
                    ),
                    400,
                )
            return f(*args, **kwargs)

        return wrapper  # type: ignore

    return decorator


def validate_required_fields(required: list[str]) -> Callable[[F], F]:
    """
    Decorator to validate required JSON fields in request body.

    Args:
        required: List of required field names

    Returns:
        Decorated function
    """

    def decorator(f: F) -> F:
        @wraps(f)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            if not request.is_json:
                return jsonify({"error": "Content-Type must be application/json"}), 400

            data = request.get_json()
            if not data:
                return jsonify({"error": "Request body is required"}), 400

            missing = [field for field in required if field not in data or data[field] is None]
            if missing:
                return (
                    jsonify(
                        {
                            "error": "Missing required fields",
                            "fields": missing,
                        }
                    ),
                    400,
                )
            return f(*args, **kwargs)

        return wrapper  # type: ignore

    return decorator


def sanitize_string(value: str | None, max_length: int = 255) -> str | None:
    """
    Sanitize string input.

    Args:
        value: Input string
        max_length: Maximum allowed length

    Returns:
        Sanitized string or None
    """
    if value is None:
        return None
    return str(value).strip()[:max_length]


# ============================================================================
# Error Handlers
# ============================================================================


@app.errorhandler(404)
def not_found(error: Exception) -> tuple[Response, int]:
    """Handle 404 errors."""
    return jsonify({"error": "Resource not found"}), 404


@app.errorhandler(500)
def internal_error(error: Exception) -> tuple[Response, int]:
    """Handle 500 errors."""
    logger.error(f"Internal server error: {error}")
    return jsonify({"error": "Internal server error"}), 500


@app.errorhandler(psycopg2.Error)
def database_error(error: psycopg2.Error) -> tuple[Response, int]:
    """Handle database errors."""
    logger.error(f"Database error: {error}")
    return jsonify({"error": "Database error occurred"}), 500


# ============================================================================
# API Routes - Read Operations
# ============================================================================


@app.route("/")
def index() -> str:
    """Render the main page."""
    return render_template("index.html")


@app.route("/api/tenants")
def get_tenants() -> Response:
    """
    Get all tenants.

    Returns:
        JSON array of tenant objects
    """
    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            cur.execute("SELECT * FROM tenants ORDER BY name")
            tenants = cur.fetchall()
    return jsonify(tenants)


@app.route("/api/tenants/<tenant_id>/equipments")
@validate_uuid("tenant_id")
def get_equipments(tenant_id: str) -> Response:
    """
    Get equipments for a tenant with hierarchy information.

    Uses recursive CTE to build equipment tree with depth levels.

    Args:
        tenant_id: Tenant UUID

    Query Parameters:
        page: Page number (default: 1)
        per_page: Items per page (default: 20, max: 100)

    Returns:
        JSON object with items array and pagination metadata
    """
    pagination = PaginationParams.from_request(default_sort="name")

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            # Get total count
            cur.execute("SELECT COUNT(*) as count FROM equipments")
            total = cur.fetchone()["count"]

            # Get paginated results with hierarchy
            cur.execute(
                """
                WITH RECURSIVE equipment_tree AS (
                    SELECT id, name, parent_equipment_id, manufacturer, description, 0 AS depth
                    FROM equipments
                    WHERE parent_equipment_id IS NULL
                    UNION ALL
                    SELECT e.id, e.name, e.parent_equipment_id, e.manufacturer, e.description, et.depth + 1
                    FROM equipments e
                    JOIN equipment_tree et ON e.parent_equipment_id = et.id
                )
                SELECT * FROM equipment_tree
                ORDER BY depth, name
                LIMIT %s OFFSET %s
            """,
                (pagination.per_page, pagination.offset),
            )
            equipments = cur.fetchall()

    return jsonify(
        {
            "items": equipments,
            "pagination": {
                "page": pagination.page,
                "per_page": pagination.per_page,
                "total": total,
                "total_pages": (total + pagination.per_page - 1) // pagination.per_page,
            },
        }
    )


@app.route("/api/tenants/<tenant_id>/parts")
@validate_uuid("tenant_id")
def get_parts(tenant_id: str) -> Response:
    """
    Get parts for a tenant with related equipment information.

    Args:
        tenant_id: Tenant UUID

    Query Parameters:
        page: Page number (default: 1)
        per_page: Items per page (default: 20, max: 100)
        low_stock: If 'true', only return parts at or below reorder point

    Returns:
        JSON object with items array and pagination metadata
    """
    pagination = PaginationParams.from_request(default_sort="name")
    low_stock_only = request.args.get("low_stock", "").lower() == "true"

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            # Build WHERE clause
            where_clause = ""
            if low_stock_only:
                where_clause = "WHERE p.stock_quantity <= p.reorder_point"

            # Get total count
            cur.execute(f"SELECT COUNT(*) as count FROM parts p {where_clause}")
            total = cur.fetchone()["count"]

            # Get paginated results
            cur.execute(
                f"""
                SELECT p.*,
                       COALESCE(
                           (SELECT STRING_AGG(e.name, ', ')
                            FROM equipment_parts ep
                            JOIN equipments e ON ep.equipment_id = e.id
                            WHERE ep.part_id = p.id), ''
                       ) AS related_equipments
                FROM parts p
                {where_clause}
                ORDER BY p.name
                LIMIT %s OFFSET %s
            """,
                (pagination.per_page, pagination.offset),
            )
            parts = cur.fetchall()

    return jsonify(
        {
            "items": parts,
            "pagination": {
                "page": pagination.page,
                "per_page": pagination.per_page,
                "total": total,
                "total_pages": (total + pagination.per_page - 1) // pagination.per_page,
            },
        }
    )


@app.route("/api/tenants/<tenant_id>/tasks")
@validate_uuid("tenant_id")
def get_tasks(tenant_id: str) -> Response:
    """
    Get tasks for a tenant.

    Args:
        tenant_id: Tenant UUID

    Query Parameters:
        page: Page number (default: 1)
        per_page: Items per page (default: 20, max: 100)
        status: Filter by status (todo, in_progress, done)
        equipment_id: Filter by equipment UUID

    Returns:
        JSON object with items array and pagination metadata
    """
    pagination = PaginationParams.from_request(default_sort="created_at", default_order="desc")
    status_filter = request.args.get("status")
    equipment_filter = request.args.get("equipment_id")

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            # Build WHERE clause
            conditions = []
            params: list[Any] = []

            if status_filter and status_filter in ("todo", "in_progress", "done"):
                conditions.append("t.status = %s")
                params.append(status_filter)

            if equipment_filter and is_valid_uuid(equipment_filter):
                conditions.append("t.equipment_id = %s")
                params.append(equipment_filter)

            where_clause = ""
            if conditions:
                where_clause = "WHERE " + " AND ".join(conditions)

            # Get total count
            cur.execute(
                f"SELECT COUNT(*) as count FROM tasks t {where_clause}",
                params,
            )
            total = cur.fetchone()["count"]

            # Get paginated results
            cur.execute(
                f"""
                SELECT t.*, e.name AS equipment_name
                FROM tasks t
                JOIN equipments e ON t.equipment_id = e.id
                {where_clause}
                ORDER BY t.created_at DESC
                LIMIT %s OFFSET %s
            """,
                params + [pagination.per_page, pagination.offset],
            )
            tasks = cur.fetchall()

    return jsonify(
        {
            "items": tasks,
            "pagination": {
                "page": pagination.page,
                "per_page": pagination.per_page,
                "total": total,
                "total_pages": (total + pagination.per_page - 1) // pagination.per_page,
            },
        }
    )


@app.route("/api/tasks/<task_id>/details")
@validate_uuid("task_id")
def get_task_details(task_id: str) -> Response:
    """
    Get detailed task information including custom fields, parts, and comments.

    This endpoint demonstrates the EAV pattern for custom fields
    and the task comments feature (課題2).

    Args:
        task_id: Task UUID

    Returns:
        JSON object with task, custom_fields, parts, and comments
    """
    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            # Task basic info
            cur.execute(
                """
                SELECT t.*, e.name AS equipment_name
                FROM tasks t
                JOIN equipments e ON t.equipment_id = e.id
                WHERE t.id = %s
            """,
                (task_id,),
            )
            task = cur.fetchone()

            if not task:
                return jsonify({"task": None, "custom_fields": [], "parts": [], "comments": []})

            # Set tenant context for RLS
            cur.execute("SET app.current_tenant_id = %s", (str(task["tenant_id"]),))

            # Custom fields (EAV pattern - Value retrieval)
            cur.execute(
                """
                SELECT cfd.field_name, cfd.field_type, cfv.value
                FROM custom_field_values cfv
                JOIN custom_field_definitions cfd ON cfv.field_definition_id = cfd.id
                WHERE cfv.task_id = %s
                ORDER BY cfd.display_order
            """,
                (task_id,),
            )
            custom_fields = cur.fetchall()

            # Parts used
            cur.execute(
                """
                SELECT p.name, p.part_number, tp.quantity
                FROM task_parts tp
                JOIN parts p ON tp.part_id = p.id
                WHERE tp.task_id = %s
            """,
                (task_id,),
            )
            parts = cur.fetchall()

            # Comments (課題2: タスクコメント機能)
            cur.execute(
                """
                SELECT id, commented_by, comment, created_at
                FROM task_comments
                WHERE task_id = %s AND deleted_at IS NULL
                ORDER BY created_at
            """,
                (task_id,),
            )
            comments = cur.fetchall()

            cur.execute("RESET app.current_tenant_id")

    return jsonify(
        {
            "task": task,
            "custom_fields": custom_fields,
            "parts": parts,
            "comments": comments,
        }
    )


@app.route("/api/tenants/<tenant_id>/custom_fields")
@validate_uuid("tenant_id")
def get_custom_field_definitions(tenant_id: str) -> Response:
    """
    Get custom field definitions for a tenant.

    This endpoint returns the EAV pattern's Attribute definitions,
    which specify what custom fields are available for this tenant.

    Args:
        tenant_id: Tenant UUID

    Returns:
        JSON array of custom field definition objects
    """
    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            cur.execute("""
                SELECT * FROM custom_field_definitions
                ORDER BY display_order
            """)
            fields = cur.fetchall()
    return jsonify(fields)


@app.route("/api/tenants/<tenant_id>/stats")
@validate_uuid("tenant_id")
def get_stats(tenant_id: str) -> Response:
    """
    Get statistics for a tenant's dashboard.

    Returns:
        - tasks_by_status: Count of tasks grouped by status
        - tasks_by_equipment: Count of tasks grouped by equipment
        - low_stock_parts: Parts with stock at or below reorder point

    Args:
        tenant_id: Tenant UUID

    Returns:
        JSON object with statistical data
    """
    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            # Tasks by status
            cur.execute("""
                SELECT status, COUNT(*) as count
                FROM tasks
                GROUP BY status
            """)
            tasks_by_status = cur.fetchall()

            # Tasks by equipment
            cur.execute("""
                SELECT e.name, COUNT(t.id) as count
                FROM equipments e
                LEFT JOIN tasks t ON e.id = t.equipment_id
                GROUP BY e.id, e.name
                ORDER BY count DESC
            """)
            tasks_by_equipment = cur.fetchall()

            # Parts low stock (at or below reorder point)
            cur.execute("""
                SELECT name, part_number, stock_quantity, reorder_point
                FROM parts
                WHERE stock_quantity <= reorder_point
                ORDER BY stock_quantity
            """)
            low_stock_parts = cur.fetchall()

    return jsonify(
        {
            "tasks_by_status": tasks_by_status,
            "tasks_by_equipment": tasks_by_equipment,
            "low_stock_parts": low_stock_parts,
        }
    )


# ============================================================================
# API Routes - Write Operations (CRUD)
# ============================================================================


@app.route("/api/tenants/<tenant_id>/tasks", methods=["POST"])
@validate_uuid("tenant_id")
@validate_required_fields(["title", "equipment_id"])
def create_task(tenant_id: str) -> tuple[Response, int]:
    """
    Create a new task.

    Args:
        tenant_id: Tenant UUID

    Request Body:
        title: Task title (required)
        equipment_id: Equipment UUID (required)
        description: Task description (optional)
        status: Task status (optional, default: 'todo')
        due_date: Due date YYYY-MM-DD (optional)
        assigned_to: Assignee name (optional)

    Returns:
        Created task object with 201 status
    """
    data = request.get_json()

    # Validate equipment_id
    equipment_id = data.get("equipment_id")
    if not is_valid_uuid(equipment_id):
        return jsonify({"error": "Invalid equipment_id format"}), 400

    # Validate status if provided
    status = data.get("status", "todo")
    if status not in ("todo", "in_progress", "done"):
        return jsonify({"error": "Invalid status. Must be: todo, in_progress, done"}), 400

    # Sanitize inputs
    title = sanitize_string(data.get("title"))
    description = sanitize_string(data.get("description"), max_length=2000)
    assigned_to = sanitize_string(data.get("assigned_to"))
    due_date = data.get("due_date")

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            # Verify equipment exists in this tenant
            cur.execute("SELECT id FROM equipments WHERE id = %s", (equipment_id,))
            if not cur.fetchone():
                return jsonify({"error": "Equipment not found"}), 404

            # Create task
            cur.execute(
                """
                INSERT INTO tasks (tenant_id, equipment_id, title, description, status, due_date, assigned_to)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                RETURNING *
            """,
                (tenant_id, equipment_id, title, description, status, due_date, assigned_to),
            )
            task = cur.fetchone()
            conn.commit()

    return jsonify(task), 201


@app.route("/api/tasks/<task_id>", methods=["PATCH"])
@validate_uuid("task_id")
def update_task(task_id: str) -> tuple[Response, int]:
    """
    Update a task.

    Args:
        task_id: Task UUID

    Request Body (all fields optional):
        title: Task title
        description: Task description
        status: Task status
        due_date: Due date YYYY-MM-DD
        assigned_to: Assignee name

    Returns:
        Updated task object
    """
    if not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 400

    data = request.get_json()
    if not data:
        return jsonify({"error": "Request body is required"}), 400

    # Build update fields
    updates = []
    params: list[Any] = []

    if "title" in data:
        updates.append("title = %s")
        params.append(sanitize_string(data["title"]))

    if "description" in data:
        updates.append("description = %s")
        params.append(sanitize_string(data["description"], max_length=2000))

    if "status" in data:
        if data["status"] not in ("todo", "in_progress", "done"):
            return jsonify({"error": "Invalid status. Must be: todo, in_progress, done"}), 400
        updates.append("status = %s")
        params.append(data["status"])

    if "due_date" in data:
        updates.append("due_date = %s")
        params.append(data["due_date"])

    if "assigned_to" in data:
        updates.append("assigned_to = %s")
        params.append(sanitize_string(data["assigned_to"]))

    if not updates:
        return jsonify({"error": "No fields to update"}), 400

    params.append(task_id)

    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            cur.execute(
                f"""
                UPDATE tasks SET {', '.join(updates)}
                WHERE id = %s
                RETURNING *
            """,
                params,
            )
            task = cur.fetchone()

            if not task:
                return jsonify({"error": "Task not found"}), 404

            conn.commit()

    return jsonify(task), 200


@app.route("/api/tasks/<task_id>/comments", methods=["POST"])
@validate_uuid("task_id")
@validate_required_fields(["commented_by", "comment"])
def create_comment(task_id: str) -> tuple[Response, int]:
    """
    Add a comment to a task (課題2).

    Args:
        task_id: Task UUID

    Request Body:
        commented_by: Commenter name (required)
        comment: Comment text (required)

    Returns:
        Created comment object with 201 status
    """
    data = request.get_json()

    commented_by = sanitize_string(data.get("commented_by"))
    comment_text = sanitize_string(data.get("comment"), max_length=2000)

    if not commented_by or not comment_text:
        return jsonify({"error": "commented_by and comment are required"}), 400

    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            # Get task to verify it exists and get tenant_id
            cur.execute("SELECT tenant_id FROM tasks WHERE id = %s", (task_id,))
            task = cur.fetchone()

            if not task:
                return jsonify({"error": "Task not found"}), 404

            # Create comment
            cur.execute(
                """
                INSERT INTO task_comments (tenant_id, task_id, commented_by, comment)
                VALUES (%s, %s, %s, %s)
                RETURNING id, commented_by, comment, created_at
            """,
                (task["tenant_id"], task_id, commented_by, comment_text),
            )
            comment = cur.fetchone()
            conn.commit()

    return jsonify(comment), 201


@app.route("/api/comments/<comment_id>", methods=["DELETE"])
@validate_uuid("comment_id")
def delete_comment(comment_id: str) -> tuple[Response, int]:
    """
    Soft delete a comment (課題2).

    Args:
        comment_id: Comment UUID

    Returns:
        Success message with 200 status
    """
    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            cur.execute(
                """
                UPDATE task_comments
                SET deleted_at = CURRENT_TIMESTAMP
                WHERE id = %s AND deleted_at IS NULL
                RETURNING id
            """,
                (comment_id,),
            )
            result = cur.fetchone()

            if not result:
                return jsonify({"error": "Comment not found or already deleted"}), 404

            conn.commit()

    return jsonify({"message": "Comment deleted successfully"}), 200


# ============================================================================
# Health Check Endpoint
# ============================================================================


@app.route("/health")
def health_check() -> tuple[Response, int]:
    """
    Health check endpoint for container orchestration.

    Returns:
        JSON object with health status
    """
    try:
        with get_db_connection() as conn:
            with get_db_cursor(conn) as cur:
                cur.execute("SELECT 1")
        return jsonify({"status": "healthy", "database": "connected"}), 200
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({"status": "unhealthy", "database": "disconnected"}), 503


# ============================================================================
# Main Entry Point
# ============================================================================

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
