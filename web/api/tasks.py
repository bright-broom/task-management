"""
Task management API endpoints.

This module provides REST API endpoints for:
- Task CRUD operations
- Task comments
- Task statistics
"""

from __future__ import annotations

from typing import Any

from api import tasks_bp
from database import get_db_connection, get_db_cursor, tenant_context
from flask import Response, jsonify, request
from security import require_auth
from validators import (
    PaginationParams,
    build_pagination_response,
    get_request_user_context,
    is_valid_uuid,
    sanitize_string,
    validate_required_fields,
    validate_uuid,
    validate_version,
)

VALID_TASK_STATUSES = ("todo", "in_progress", "done")
VALID_TASK_PRIORITIES = ("critical", "high", "medium", "low")
VALID_TASK_CATEGORIES = (
    "maintenance",
    "repair",
    "inspection",
    "replacement",
    "calibration",
    "cleaning",
    "improvement",
    "emergency",
    "other",
)


@tasks_bp.route("/api/tenants/<tenant_id>/tasks")
@validate_uuid("tenant_id")
def get_tasks(tenant_id: str) -> Response:
    """
    タスク一覧取得
    ---
    tags:
      - Tasks
    parameters:
      - name: tenant_id
        in: path
        required: true
        schema:
          type: string
          format: uuid
        description: テナントID
      - name: page
        in: query
        schema:
          type: integer
          default: 1
        description: ページ番号
      - name: per_page
        in: query
        schema:
          type: integer
          default: 20
          maximum: 100
        description: 1ページあたりの件数
      - name: status
        in: query
        schema:
          type: string
          enum: [todo, in_progress, done]
        description: ステータスでフィルタ
      - name: equipment_id
        in: query
        schema:
          type: string
          format: uuid
        description: 設備IDでフィルタ
    responses:
      200:
        description: タスク一覧（ページネーション付き）
    """
    pagination = PaginationParams.from_request(default_sort="created_at", default_order="desc")
    status_filter = request.args.get("status")
    equipment_filter = request.args.get("equipment_id")

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            # Always filter out soft-deleted tasks
            conditions = ["t.tenant_id = %s", "t.deleted_at IS NULL"]
            params: list[Any] = [tenant_id]

            if status_filter and status_filter in VALID_TASK_STATUSES:
                conditions.append("t.status = %s")
                params.append(status_filter)

            if equipment_filter and is_valid_uuid(equipment_filter):
                conditions.append("t.equipment_id = %s")
                params.append(equipment_filter)

            where_clause = "WHERE " + " AND ".join(conditions)

            cur.execute(
                f"SELECT COUNT(*) as count FROM tasks t {where_clause}",
                params,
            )
            total = cur.fetchone()["count"]

            cur.execute(
                f"""
                SELECT t.*, e.name AS equipment_name
                FROM tasks t
                LEFT JOIN equipments e ON t.equipment_id = e.id
                {where_clause}
                ORDER BY t.created_at DESC
                LIMIT %s OFFSET %s
            """,
                params + [pagination.per_page, pagination.offset],
            )
            tasks = cur.fetchall()

    return jsonify(build_pagination_response(tasks, pagination, total))


@tasks_bp.route("/api/tenants/<tenant_id>/tasks/<task_id>")
@validate_uuid("tenant_id")
@validate_uuid("task_id")
def get_task(tenant_id: str, task_id: str) -> tuple[Response, int]:
    """Get a single task by ID."""
    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            cur.execute(
                """
                SELECT t.*, e.name AS equipment_name
                FROM tasks t
                LEFT JOIN equipments e ON t.equipment_id = e.id
                WHERE t.id = %s AND t.tenant_id = %s AND t.deleted_at IS NULL
            """,
                (task_id, tenant_id),
            )
            task = cur.fetchone()

            if not task:
                return jsonify({"error": "Task not found"}), 404

    return jsonify(task), 200


@tasks_bp.route("/api/tenants/<tenant_id>/tasks/<task_id>/details")
@tasks_bp.route("/api/tasks/<task_id>/details")  # Legacy route (deprecated)
@validate_uuid("task_id")
def get_task_details(
    task_id: str, tenant_id: str | None = None
) -> Response | tuple[Response, int]:
    """Get task with custom fields, parts, and comments.

    Security Note: The legacy route /api/tasks/<task_id>/details is deprecated.
    Use /api/tenants/<tenant_id>/tasks/<task_id>/details for proper tenant isolation.
    """
    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            # Build query with optional tenant filter
            query = """
                SELECT t.*, e.name AS equipment_name
                FROM tasks t
                LEFT JOIN equipments e ON t.equipment_id = e.id
                WHERE t.id = %s AND t.deleted_at IS NULL
            """
            params: tuple[str, ...] = (task_id,)

            # If tenant_id provided, enforce tenant isolation
            if tenant_id:
                if not is_valid_uuid(tenant_id):
                    return jsonify({"error": "Invalid tenant_id format"}), 400
                query = """
                    SELECT t.*, e.name AS equipment_name
                    FROM tasks t
                    LEFT JOIN equipments e ON t.equipment_id = e.id
                    WHERE t.id = %s AND t.tenant_id = %s AND t.deleted_at IS NULL
                """
                params = (task_id, tenant_id)

            cur.execute(query, params)
            task = cur.fetchone()

            if not task:
                return jsonify({"error": "Task not found"}), 404

            cur.execute("SET app.current_tenant_id = %s", (str(task["tenant_id"]),))

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


@tasks_bp.route("/api/tenants/<tenant_id>/tasks", methods=["POST"])
@require_auth
@validate_uuid("tenant_id")
@validate_required_fields(["title"])
def create_task(tenant_id: str) -> tuple[Response, int]:
    """
    タスク作成
    ---
    tags:
      - Tasks
    """
    data = request.get_json()
    user_id, user_name = get_request_user_context()

    equipment_id = data.get("equipment_id")
    # equipment_id is optional, but if provided must be valid UUID
    if equipment_id is not None and not is_valid_uuid(equipment_id):
        return jsonify({"error": "Invalid equipment_id format"}), 400

    # status: explicit null is a precondition violation, missing key gets default
    if "status" in data and data["status"] is None:
        return jsonify({"error": "status cannot be null"}), 400
    status = data.get("status", "todo")
    if status not in VALID_TASK_STATUSES:
        return (
            jsonify({"error": f"Invalid status. Must be one of: {', '.join(VALID_TASK_STATUSES)}"}),
            400,
        )

    # priority: explicit null is a precondition violation, missing key gets default
    if "priority" in data and data["priority"] is None:
        return jsonify({"error": "priority cannot be null"}), 400
    priority = data.get("priority", "medium")
    if priority not in VALID_TASK_PRIORITIES:
        return (
            jsonify(
                {"error": f"Invalid priority. Must be one of: {', '.join(VALID_TASK_PRIORITIES)}"}
            ),
            400,
        )

    # category: explicit null is a precondition violation, missing key gets default
    if "category" in data and data["category"] is None:
        return jsonify({"error": "category cannot be null"}), 400
    category = data.get("category", "maintenance")
    if category not in VALID_TASK_CATEGORIES:
        return (
            jsonify(
                {"error": f"Invalid category. Must be one of: {', '.join(VALID_TASK_CATEGORIES)}"}
            ),
            400,
        )

    title = sanitize_string(data.get("title"))
    description = sanitize_string(data.get("description"), max_length=2000)
    assigned_to = sanitize_string(data.get("assigned_to"))
    due_date = data.get("due_date")
    estimated_hours = data.get("estimated_hours")

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id, user_id, user_name) as cur:
            # Verify equipment exists if provided
            if equipment_id:
                cur.execute(
                    """SELECT id FROM equipments
                       WHERE id = %s AND tenant_id = %s AND deleted_at IS NULL""",
                    (equipment_id, tenant_id),
                )
                if not cur.fetchone():
                    return jsonify({"error": "Equipment not found"}), 404

            cur.execute("""SELECT column_name FROM information_schema.columns
                   WHERE table_name = 'tasks' AND column_name = 'priority'""")
            has_v2_schema = cur.fetchone() is not None

            if has_v2_schema:
                cur.execute(
                    """
                    INSERT INTO tasks
                        (tenant_id, equipment_id, title, description, status,
                         priority, category, due_date, assigned_to, estimated_hours, created_by)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    RETURNING *
                """,
                    (
                        tenant_id,
                        equipment_id,
                        title,
                        description,
                        status,
                        priority,
                        category,
                        due_date,
                        assigned_to,
                        estimated_hours,
                        user_id,
                    ),
                )
            else:
                cur.execute(
                    """
                    INSERT INTO tasks
                        (tenant_id, equipment_id, title, description, status, due_date, assigned_to)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    RETURNING *
                """,
                    (tenant_id, equipment_id, title, description, status, due_date, assigned_to),
                )
            task = cur.fetchone()
            conn.commit()

    return jsonify(task), 201


@tasks_bp.route("/api/tasks/<task_id>", methods=["PATCH"])
@require_auth
@validate_uuid("task_id")
def update_task(task_id: str) -> tuple[Response, int]:
    """
    Update a task with optimistic locking support.
    """
    if not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 400

    data = request.get_json()
    if not data:
        return jsonify({"error": "Request body is required"}), 400

    user_id, user_name = get_request_user_context()

    try:
        expected_version = validate_version(data)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    updates = []
    params: list[Any] = []

    if "title" in data:
        # title is required - null is a precondition violation
        if data["title"] is None:
            return jsonify({"error": "title cannot be null"}), 400
        sanitized_title = sanitize_string(data["title"])
        if not sanitized_title:
            return jsonify({"error": "title cannot be empty"}), 400
        updates.append("title = %s")
        params.append(sanitized_title)

    if "description" in data:
        updates.append("description = %s")
        params.append(sanitize_string(data["description"], max_length=2000))

    if "status" in data:
        # status is an enum - null is a precondition violation
        if data["status"] is None:
            return jsonify({"error": "status cannot be null"}), 400
        if data["status"] not in VALID_TASK_STATUSES:
            return (
                jsonify(
                    {"error": f"Invalid status. Must be one of: {', '.join(VALID_TASK_STATUSES)}"}
                ),
                400,
            )
        updates.append("status = %s")
        params.append(data["status"])

    if "due_date" in data:
        updates.append("due_date = %s")
        params.append(data["due_date"])

    if "assigned_to" in data:
        updates.append("assigned_to = %s")
        params.append(sanitize_string(data["assigned_to"]))

    v2_updates: list[str] = []
    v2_params: list[Any] = []

    if "priority" in data:
        # priority is an enum - null is a precondition violation
        if data["priority"] is None:
            return jsonify({"error": "priority cannot be null"}), 400
        if data["priority"] not in VALID_TASK_PRIORITIES:
            return (
                jsonify(
                    {
                        "error": "Invalid priority. Must be one of: "
                        f"{', '.join(VALID_TASK_PRIORITIES)}"
                    }
                ),
                400,
            )
        v2_updates.append("priority = %s")
        v2_params.append(data["priority"])

    if "category" in data:
        # category is an enum - null is a precondition violation
        if data["category"] is None:
            return jsonify({"error": "category cannot be null"}), 400
        if data["category"] not in VALID_TASK_CATEGORIES:
            return (
                jsonify(
                    {
                        "error": "Invalid category. Must be one of: "
                        f"{', '.join(VALID_TASK_CATEGORIES)}"
                    }
                ),
                400,
            )
        v2_updates.append("category = %s")
        v2_params.append(data["category"])

    if "estimated_hours" in data:
        v2_updates.append("estimated_hours = %s")
        v2_params.append(data["estimated_hours"])

    if "actual_hours" in data:
        v2_updates.append("actual_hours = %s")
        v2_params.append(data["actual_hours"])

    if not updates and not v2_updates:
        return jsonify({"error": "No fields to update"}), 400

    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            if user_id:
                cur.execute("SET app.current_user_id = %s", (user_id,))
            if user_name:
                cur.execute("SET app.current_user_name = %s", (user_name,))

            if v2_updates:
                cur.execute("""SELECT column_name FROM information_schema.columns
                       WHERE table_name = 'tasks' AND column_name = 'priority'""")
                if cur.fetchone() is not None:
                    updates.extend(v2_updates)
                    params.extend(v2_params)

            if not updates:
                return jsonify({"error": "No fields to update for current schema"}), 400

            where_conditions = ["id = %s"]
            params.append(task_id)

            if expected_version is not None:
                where_conditions.append("version = %s")
                params.append(expected_version)

            cur.execute(
                f"""
                UPDATE tasks SET {', '.join(updates)}
                WHERE {' AND '.join(where_conditions)}
                RETURNING *
            """,
                params,
            )
            task = cur.fetchone()

            if not task:
                if expected_version is not None:
                    cur.execute(
                        "SELECT id, version FROM tasks WHERE id = %s",
                        (task_id,),
                    )
                    existing = cur.fetchone()
                    if existing:
                        return (
                            jsonify(
                                {
                                    "error": "Optimistic lock conflict",
                                    "message": "Record was modified by another transaction",
                                    "current_version": existing["version"],
                                    "expected_version": expected_version,
                                }
                            ),
                            409,
                        )
                return jsonify({"error": "Task not found"}), 404

            conn.commit()

    return jsonify(task), 200


@tasks_bp.route("/api/tasks/<task_id>/comments", methods=["POST"])
@require_auth
@validate_uuid("task_id")
@validate_required_fields(["commented_by", "comment"])
def create_comment(task_id: str) -> tuple[Response, int]:
    """Add a comment to a task."""
    data = request.get_json()

    commented_by = sanitize_string(data.get("commented_by"))
    comment_text = sanitize_string(data.get("comment"), max_length=2000)

    if not commented_by or not comment_text:
        return jsonify({"error": "commented_by and comment are required"}), 400

    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            # Don't allow comments on deleted tasks
            cur.execute(
                "SELECT tenant_id FROM tasks WHERE id = %s AND deleted_at IS NULL",
                (task_id,),
            )
            task = cur.fetchone()

            if not task:
                return jsonify({"error": "Task not found"}), 404

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


@tasks_bp.route("/api/comments/<comment_id>", methods=["DELETE"])
@require_auth
@validate_uuid("comment_id")
def delete_comment(comment_id: str) -> tuple[Response, int]:
    """Soft delete a comment."""
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


@tasks_bp.route("/api/tenants/<tenant_id>/stats")
@validate_uuid("tenant_id")
def get_stats(tenant_id: str) -> Response:
    """Get dashboard statistics for a tenant."""
    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            cur.execute(
                """
                SELECT status, COUNT(*) as count
                FROM tasks
                WHERE tenant_id = %s
                GROUP BY status
            """,
                (tenant_id,),
            )
            tasks_by_status = cur.fetchall()

            cur.execute(
                """
                SELECT e.name, COUNT(t.id) as count
                FROM equipments e
                LEFT JOIN tasks t ON e.id = t.equipment_id
                WHERE e.tenant_id = %s
                GROUP BY e.id, e.name
                ORDER BY count DESC
            """,
                (tenant_id,),
            )
            tasks_by_equipment = cur.fetchall()

            cur.execute(
                """
                SELECT name, part_number, stock_quantity, reorder_point
                FROM parts
                WHERE tenant_id = %s AND stock_quantity <= reorder_point
                ORDER BY stock_quantity
            """,
                (tenant_id,),
            )
            low_stock_parts = cur.fetchall()

    return jsonify(
        {
            "tasks_by_status": tasks_by_status,
            "tasks_by_equipment": tasks_by_equipment,
            "low_stock_parts": low_stock_parts,
        }
    )


@tasks_bp.route("/api/tenants/<tenant_id>/custom_fields")
@validate_uuid("tenant_id")
def get_custom_field_definitions(tenant_id: str) -> Response:
    """Get custom field definitions for a tenant."""
    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            cur.execute(
                """
                SELECT * FROM custom_field_definitions
                WHERE tenant_id = %s
                ORDER BY display_order
            """,
                (tenant_id,),
            )
            fields = cur.fetchall()
    return jsonify(fields)
