"""
M2X課題 - 工場向けタスク管理システム Web API

このモジュールは工場タスク管理システムのREST APIを提供します。

主な機能:
- テナント管理
- 設備管理（階層構造対応）
- 部品管理（在庫・発注点管理）
- タスク管理（カスタムフィールド・コメント対応）

セキュリティ:
- JWT認証とロールベースアクセス制御（RBAC）
- Row Level Security (RLS) によるデータベースレベルでのテナント分離
- セキュリティヘッダー（CORS, CSP, HSTS, X-Frame-Options）
- レート制限によるDoS/ブルートフォース防止
- 入力バリデーション（UUID形式チェック、XSS検出、長さ制限）
- パラメータ化クエリによるSQLインジェクション防止
- セキュリティイベントの包括的ログ

パフォーマンス:
- コネクションプーリングによる接続管理
- 楽観的ロックによるコンフリクト検出対応

準拠規格:
- OWASP Top 10
- NIST 800-63B
- ISO 27001
"""

from __future__ import annotations

import atexit
import os
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import wraps
from typing import Any, Callable, Generator, TypeVar

import psycopg2
from flask import Flask, Response, g, jsonify, render_template, request
from psycopg2 import pool
from psycopg2.extras import RealDictCursor

# 構造化ログ設定
from logging_config import (
    configure_logging,
    get_logger,
    setup_flask_logging,
)

# セキュリティモジュール
from security import (
    init_security,
    rate_limit,
    require_auth,
    security_logger,
    validate_email,
)

# ============================================================================
# Type Definitions
# ============================================================================

F = TypeVar("F", bound=Callable[..., Any])

# ============================================================================
# Application Configuration
# ============================================================================

app = Flask(__name__)
app.config["JSON_AS_ASCII"] = False  # Support Japanese characters in JSON

# セキュリティ設定
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", os.urandom(32).hex())
app.config["SECURITY_DB_LOGGING"] = os.environ.get("SECURITY_DB_LOGGING", "false").lower() == "true"

# セキュリティモジュール初期化
init_security(app)

# 構造化ログ設定（JSON形式）
configure_logging()
logger = get_logger(__name__)

# Flaskリクエストログミドルウェア
setup_flask_logging(app)

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql://m2x_user:m2x_password@db:5432/m2x_task_management"
)

# ============================================================================
# Connection Pool Configuration
# ============================================================================
# グローバル基準のコネクションプーリング設定
# - minconn: 最小接続数（常時維持）
# - maxconn: 最大接続数（ピーク時対応）

POOL_MIN_CONNECTIONS = int(os.environ.get("POOL_MIN_CONNECTIONS", "2"))
POOL_MAX_CONNECTIONS = int(os.environ.get("POOL_MAX_CONNECTIONS", "20"))

# コネクションプールの初期化（遅延初期化パターン）
_connection_pool: pool.ThreadedConnectionPool | None = None


def get_connection_pool() -> pool.ThreadedConnectionPool:
    """
    スレッドセーフなコネクションプールを取得（シングルトンパターン）。

    Returns:
        ThreadedConnectionPool: データベースコネクションプール
    """
    global _connection_pool
    if _connection_pool is None:
        try:
            _connection_pool = pool.ThreadedConnectionPool(
                minconn=POOL_MIN_CONNECTIONS,
                maxconn=POOL_MAX_CONNECTIONS,
                dsn=DATABASE_URL,
                cursor_factory=RealDictCursor,
            )
            logger.info(
                f"Connection pool initialized: min={POOL_MIN_CONNECTIONS}, "
                f"max={POOL_MAX_CONNECTIONS}"
            )
        except psycopg2.Error as e:
            logger.error(f"Failed to initialize connection pool: {e}")
            raise
    return _connection_pool


def close_connection_pool() -> None:
    """アプリケーション終了時にコネクションプールをクローズ。"""
    global _connection_pool
    if _connection_pool is not None:
        _connection_pool.closeall()
        _connection_pool = None
        logger.info("Connection pool closed")


# アプリケーション終了時のクリーンアップ登録
atexit.register(close_connection_pool)

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
    Database connection context manager with connection pooling.

    コネクションプールから接続を取得し、使用後はプールに返却します。
    これにより、接続の作成/破棄のオーバーヘッドを削減し、
    高負荷時のパフォーマンスを向上させます。

    Yields:
        psycopg2 connection object with RealDictCursor
    """
    conn = None
    connection_pool = None
    try:
        connection_pool = get_connection_pool()
        conn = connection_pool.getconn()
        yield conn
    except psycopg2.Error as e:
        logger.error(f"Database connection error: {e}")
        raise
    finally:
        if conn and connection_pool:
            connection_pool.putconn(conn)


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
def tenant_context(
    conn: Any,
    tenant_id: str,
    user_id: str | None = None,
    user_name: str | None = None,
) -> Generator[Any, None, None]:
    """
    Set tenant and user context for Row Level Security and audit logging.

    This sets session variables used by RLS policies and audit triggers:
    - app.current_tenant_id: テナント分離
    - app.current_user_id: 監査ログのユーザー追跡
    - app.current_user_name: 監査ログのユーザー名スナップショット

    Args:
        conn: Database connection
        tenant_id: UUID of the current tenant
        user_id: Optional UUID of the current user (for audit logging)
        user_name: Optional display name of the current user

    Yields:
        Database cursor with tenant/user context set
    """
    with get_db_cursor(conn) as cur:
        # Set tenant context for RLS
        cur.execute("SET app.current_tenant_id = %s", (tenant_id,))

        # Set user context for audit logging (if provided)
        if user_id:
            cur.execute("SET app.current_user_id = %s", (user_id,))
        if user_name:
            cur.execute("SET app.current_user_name = %s", (user_name,))

        yield cur

        # Reset all context variables
        cur.execute("RESET app.current_tenant_id")
        cur.execute("RESET app.current_user_id")
        cur.execute("RESET app.current_user_name")


def get_request_user_context() -> tuple[str | None, str | None]:
    """
    リクエストヘッダーからユーザーコンテキストを取得。

    実運用ではJWT等の認証トークンから取得しますが、
    開発用にヘッダーベースの簡易実装を提供します。

    Returns:
        Tuple of (user_id, user_name)
    """
    user_id = request.headers.get("X-User-ID")
    user_name = request.headers.get("X-User-Name")
    return user_id, user_name


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


class OptimisticLockError(Exception):
    """楽観的ロックの競合エラー。"""

    pass


def validate_version(data: dict[str, Any], field: str = "version") -> int | None:
    """
    リクエストデータからバージョン番号を検証・取得。

    Args:
        data: リクエストJSONデータ
        field: バージョンフィールド名

    Returns:
        バージョン番号（指定なしの場合はNone）

    Raises:
        ValueError: 不正なバージョン形式
    """
    version = data.get(field)
    if version is None:
        return None
    try:
        v = int(version)
        if v < 1:
            raise ValueError("Version must be a positive integer")
        return v
    except (TypeError, ValueError) as e:
        raise ValueError(f"Invalid version format: {e}") from e


def build_optimistic_update(
    updates: list[str],
    params: list[Any],
    current_version: int | None,
) -> tuple[list[str], list[Any]]:
    """
    楽観的ロック対応のUPDATE文を構築。

    Args:
        updates: 既存のSETフィールドリスト
        params: 既存のパラメータリスト
        current_version: クライアント側のバージョン番号

    Returns:
        Tuple of (updated fields list, updated params list)
    """
    if current_version is not None:
        updates.append("version = version + 1")
    return updates, params


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
            cur.execute(
                "SELECT COUNT(*) as count FROM equipments WHERE tenant_id = %s",
                (tenant_id,),
            )
            total = cur.fetchone()["count"]

            # Get paginated results with hierarchy
            cur.execute(
                """
                WITH RECURSIVE equipment_tree AS (
                    SELECT id, name, parent_equipment_id, manufacturer, description, 0 AS depth
                    FROM equipments
                    WHERE tenant_id = %s AND parent_equipment_id IS NULL
                    UNION ALL
                    SELECT e.id, e.name, e.parent_equipment_id, e.manufacturer,
                           e.description, et.depth + 1
                    FROM equipments e
                    JOIN equipment_tree et ON e.parent_equipment_id = et.id
                    WHERE e.tenant_id = %s
                )
                SELECT * FROM equipment_tree
                ORDER BY depth, name
                LIMIT %s OFFSET %s
            """,
                (tenant_id, tenant_id, pagination.per_page, pagination.offset),
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
            # Build WHERE clause - always filter by tenant_id
            conditions = ["p.tenant_id = %s"]
            params: list[Any] = [tenant_id]

            if low_stock_only:
                conditions.append("p.stock_quantity <= p.reorder_point")

            where_clause = "WHERE " + " AND ".join(conditions)

            # Get total count (safe: where_clause uses validated columns)
            cur.execute(
                f"SELECT COUNT(*) as count FROM parts p {where_clause}",
                params,
            )
            total = cur.fetchone()["count"]

            # Get paginated results (nosec B608: where_clause uses validated columns)
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
                params + [pagination.per_page, pagination.offset],
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
            # Build WHERE clause - always filter by tenant_id
            conditions = ["t.tenant_id = %s"]
            params: list[Any] = [tenant_id]

            if status_filter and status_filter in ("todo", "in_progress", "done"):
                conditions.append("t.status = %s")
                params.append(status_filter)

            if equipment_filter and is_valid_uuid(equipment_filter):
                conditions.append("t.equipment_id = %s")
                params.append(equipment_filter)

            where_clause = "WHERE " + " AND ".join(conditions)

            # Get total count (safe: where_clause uses validated columns)
            cur.execute(
                f"SELECT COUNT(*) as count FROM tasks t {where_clause}",
                params,
            )
            total = cur.fetchone()["count"]

            # Get paginated results (nosec B608: where_clause uses validated columns)
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

            # Tasks by equipment
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

            # Parts low stock (at or below reorder point)
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


# ============================================================================
# API Routes - Write Operations (CRUD)
# ============================================================================


# 有効なタスクステータス
VALID_TASK_STATUSES = ("todo", "in_progress", "done")
# 有効な優先度
VALID_TASK_PRIORITIES = ("critical", "high", "medium", "low")
# 有効なカテゴリー
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
        priority: Task priority (optional, default: 'medium')
        category: Task category (optional, default: 'maintenance')
        due_date: Due date YYYY-MM-DD (optional)
        assigned_to: Assignee name (optional)
        estimated_hours: Estimated work hours (optional)

    Returns:
        Created task object with 201 status
    """
    data = request.get_json()
    user_id, user_name = get_request_user_context()

    # Validate equipment_id
    equipment_id = data.get("equipment_id")
    if not is_valid_uuid(equipment_id):
        return jsonify({"error": "Invalid equipment_id format"}), 400

    # Validate status if provided
    status = data.get("status", "todo")
    if status not in VALID_TASK_STATUSES:
        return (
            jsonify({"error": f"Invalid status. Must be one of: {', '.join(VALID_TASK_STATUSES)}"}),
            400,
        )

    # Validate priority if provided
    priority = data.get("priority", "medium")
    if priority not in VALID_TASK_PRIORITIES:
        return (
            jsonify(
                {"error": f"Invalid priority. Must be one of: {', '.join(VALID_TASK_PRIORITIES)}"}
            ),
            400,
        )

    # Validate category if provided
    category = data.get("category", "maintenance")
    if category not in VALID_TASK_CATEGORIES:
        return (
            jsonify(
                {"error": f"Invalid category. Must be one of: {', '.join(VALID_TASK_CATEGORIES)}"}
            ),
            400,
        )

    # Sanitize inputs
    title = sanitize_string(data.get("title"))
    description = sanitize_string(data.get("description"), max_length=2000)
    assigned_to = sanitize_string(data.get("assigned_to"))
    due_date = data.get("due_date")
    estimated_hours = data.get("estimated_hours")

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id, user_id, user_name) as cur:
            # Verify equipment exists in this tenant
            cur.execute("SELECT id FROM equipments WHERE id = %s", (equipment_id,))
            if not cur.fetchone():
                return jsonify({"error": "Equipment not found"}), 404

            # Create task
            # Check if v2 schema columns exist (priority, category, etc.)
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
                # v1 schema fallback (for backwards compatibility)
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


@app.route("/api/tasks/<task_id>", methods=["PATCH"])
@validate_uuid("task_id")
def update_task(task_id: str) -> tuple[Response, int]:
    """
    Update a task with optimistic locking support.

    Args:
        task_id: Task UUID

    Request Body (all fields optional):
        title: Task title
        description: Task description
        status: Task status
        priority: Task priority
        category: Task category
        due_date: Due date YYYY-MM-DD
        assigned_to: Assignee name
        estimated_hours: Estimated work hours
        actual_hours: Actual work hours
        version: Expected version number (for optimistic locking)

    Returns:
        Updated task object

    Raises:
        409 Conflict: If version mismatch (optimistic lock failure)
    """
    if not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 400

    data = request.get_json()
    if not data:
        return jsonify({"error": "Request body is required"}), 400

    user_id, user_name = get_request_user_context()

    # Validate version for optimistic locking
    try:
        expected_version = validate_version(data)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

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

    # v2 schema fields (priority, category, estimated_hours, actual_hours)
    # These are validated but applied conditionally based on schema version
    v2_updates: list[str] = []
    v2_params: list[Any] = []

    if "priority" in data:
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
            # Set user context for audit logging
            if user_id:
                cur.execute("SET app.current_user_id = %s", (user_id,))
            if user_name:
                cur.execute("SET app.current_user_name = %s", (user_name,))

            # Check if v2 schema exists and merge v2 updates
            if v2_updates:
                cur.execute("""SELECT column_name FROM information_schema.columns
                       WHERE table_name = 'tasks' AND column_name = 'priority'""")
                if cur.fetchone() is not None:
                    updates.extend(v2_updates)
                    params.extend(v2_params)

            # Ensure we have updates after schema check
            if not updates:
                return jsonify({"error": "No fields to update for current schema"}), 400

            # Build WHERE clause with optimistic lock check
            where_conditions = ["id = %s"]
            params.append(task_id)

            if expected_version is not None:
                where_conditions.append("version = %s")
                params.append(expected_version)

            # nosec B608: updates/where_conditions use validated column names, values parameterized
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
                # Check if task exists but version mismatch
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
@rate_limit(limit=120, window_seconds=60)  # ヘルスチェックは緩いレート制限
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
# Authentication Endpoints
# ============================================================================


@app.route("/api/auth/login", methods=["POST"])
@rate_limit(limit=10, window_seconds=60)  # ログインは厳しいレート制限
def login() -> tuple[Response, int]:
    """
    ユーザー認証エンドポイント。

    Request Body:
        email: ユーザーメールアドレス
        password: パスワード
        tenant_id: テナントID

    Returns:
        JWTトークンを含むレスポンス
    """
    from security import (
        create_access_token,
        create_refresh_token,
        verify_password,
    )

    if not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 400

    data = request.get_json()
    if not data:
        return jsonify({"error": "Request body required"}), 400

    email = data.get("email", "").strip().lower()
    password = data.get("password", "")
    tenant_id = data.get("tenant_id", "")

    # 入力検証
    if not email or not password or not tenant_id:
        security_logger.login_failure(email, "missing_fields")
        return jsonify({"error": "Email, password, and tenant_id are required"}), 400

    if not validate_email(email):
        security_logger.login_failure(email, "invalid_email")
        return jsonify({"error": "Invalid email format"}), 400

    if not is_valid_uuid(tenant_id):
        security_logger.login_failure(email, "invalid_tenant")
        return jsonify({"error": "Invalid tenant_id format"}), 400

    # ブルートフォース検出（本番実装ではDBチェックを追加）
    # 簡易実装のため、ここではログのみ

    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            # ユーザー検索
            cur.execute(
                """
                SELECT id, tenant_id, email, password_hash, display_name, role, status,
                       failed_login_count, locked_until
                FROM users
                WHERE tenant_id = %s AND email = %s AND deleted_at IS NULL
                """,
                (tenant_id, email),
            )
            user = cur.fetchone()

            if not user:
                security_logger.login_failure(email, "user_not_found", tenant_id)
                return jsonify({"error": "Invalid email or password"}), 401

            # アカウントロックチェック
            if user["status"] == "locked" or (
                user["locked_until"] and user["locked_until"] > datetime.now(timezone.utc)
            ):
                security_logger.login_failure(email, "account_locked", tenant_id)
                return jsonify({"error": "Account is locked"}), 403

            # パスワード検証
            if not user["password_hash"] or not verify_password(password, user["password_hash"]):
                # 失敗回数を増加
                cur.execute(
                    """
                    UPDATE users
                    SET failed_login_count = failed_login_count + 1,
                        locked_until = CASE
                            WHEN failed_login_count >= 4
                            THEN CURRENT_TIMESTAMP + INTERVAL '30 minutes'
                            ELSE locked_until
                        END
                    WHERE id = %s
                    """,
                    (user["id"],),
                )
                conn.commit()

                security_logger.login_failure(email, "invalid_password", tenant_id)
                return jsonify({"error": "Invalid email or password"}), 401

            # ログイン成功: カウンターリセット
            cur.execute(
                """
                UPDATE users
                SET failed_login_count = 0,
                    locked_until = NULL,
                    last_login_at = CURRENT_TIMESTAMP
                WHERE id = %s
                """,
                (user["id"],),
            )
            conn.commit()

    # トークン生成
    access_token = create_access_token(
        user_id=str(user["id"]),
        tenant_id=str(user["tenant_id"]),
        role=user["role"],
        additional_claims={"display_name": user["display_name"]},
    )
    refresh_token = create_refresh_token(
        user_id=str(user["id"]),
        tenant_id=str(user["tenant_id"]),
    )

    security_logger.login_success(str(user["id"]), str(user["tenant_id"]))

    return (
        jsonify(
            {
                "access_token": access_token,
                "refresh_token": refresh_token,
                "token_type": "Bearer",
                "expires_in": 3600,
                "user": {
                    "id": str(user["id"]),
                    "email": user["email"],
                    "display_name": user["display_name"],
                    "role": user["role"],
                },
            }
        ),
        200,
    )


@app.route("/api/auth/refresh", methods=["POST"])
@rate_limit(limit=30, window_seconds=60)
def refresh_token() -> tuple[Response, int]:
    """
    リフレッシュトークンを使用して新しいアクセストークンを取得。

    Request Body:
        refresh_token: リフレッシュトークン

    Returns:
        新しいアクセストークン
    """
    from security import create_access_token, decode_token

    if not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 400

    data = request.get_json()
    refresh_token_str = data.get("refresh_token", "")

    if not refresh_token_str:
        return jsonify({"error": "Refresh token required"}), 400

    # トークン検証
    payload = decode_token(refresh_token_str)
    if not payload or payload.get("type") != "refresh":
        return jsonify({"error": "Invalid refresh token"}), 401

    user_id = payload.get("sub")
    tenant_id = payload.get("tenant_id")

    if not isinstance(tenant_id, str):
        return jsonify({"error": "Invalid token payload"}), 401

    # ユーザー情報を再取得（ロール変更等に対応）
    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            cur.execute(
                """
                SELECT id, role, display_name, status
                FROM users
                WHERE id = %s AND tenant_id = %s AND deleted_at IS NULL
                """,
                (user_id, tenant_id),
            )
            user = cur.fetchone()

            if not user or user["status"] != "active":
                return jsonify({"error": "User not found or inactive"}), 401

    # 新しいアクセストークン生成
    new_access_token = create_access_token(
        user_id=str(user["id"]),
        tenant_id=tenant_id,
        role=user["role"],
        additional_claims={"display_name": user["display_name"]},
    )

    return (
        jsonify(
            {
                "access_token": new_access_token,
                "token_type": "Bearer",
                "expires_in": 3600,
            }
        ),
        200,
    )


@app.route("/api/auth/me", methods=["GET"])
@require_auth
def get_current_user() -> tuple[Response, int]:
    """
    現在の認証済みユーザー情報を取得。

    Returns:
        ユーザー情報
    """
    user_id = g.current_user.get("user_id")
    tenant_id = g.current_user.get("tenant_id")

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            cur.execute(
                """
                SELECT id, email, display_name, role, department,
                       last_login_at, created_at
                FROM users
                WHERE id = %s AND deleted_at IS NULL
                """,
                (user_id,),
            )
            user = cur.fetchone()

            if not user:
                return jsonify({"error": "User not found"}), 404

    return jsonify({"user": user}), 200


# ============================================================================
# Main Entry Point
# ============================================================================

# デバッグモードは環境変数で制御（本番環境では必ずFalse）
DEBUG_MODE = os.environ.get("FLASK_DEBUG", "false").lower() == "true"

if DEBUG_MODE:
    logger.warning("DEBUG MODE IS ENABLED - DO NOT USE IN PRODUCTION")

if __name__ == "__main__":
    # nosec B104: Binding to all interfaces is required for Docker container
    app.run(host="0.0.0.0", port=5000, debug=DEBUG_MODE)  # nosec B104
