"""
M2X課題 - 工場向けタスク管理システム Web UI

このモジュールは工場タスク管理システムのREST APIを提供します。

主な機能:
- テナント管理
- 設備管理（階層構造対応）
- 部品管理（在庫・発注点管理）
- タスク管理（カスタムフィールド・コメント対応）
"""
import os
import uuid
import logging
from functools import wraps
from contextlib import contextmanager

from flask import Flask, render_template, jsonify, request
import psycopg2
from psycopg2.extras import RealDictCursor

# ============================================================================
# Application Configuration
# ============================================================================

app = Flask(__name__)
app.config['JSON_AS_ASCII'] = False  # Support Japanese characters in JSON

# Logging configuration
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

DATABASE_URL = os.environ.get(
    'DATABASE_URL',
    'postgresql://m2x_user:m2x_password@db:5432/m2x_task_management'
)


# ============================================================================
# Database Utilities
# ============================================================================

@contextmanager
def get_db_connection():
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
def get_db_cursor(conn):
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


def validate_uuid(param_name: str):
    """
    Decorator to validate UUID parameters.

    Args:
        param_name: Name of the parameter to validate

    Returns:
        Decorated function
    """
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            param_value = kwargs.get(param_name)
            if param_value and not is_valid_uuid(param_value):
                return jsonify({
                    'error': 'Invalid UUID format',
                    'parameter': param_name,
                    'value': param_value
                }), 400
            return f(*args, **kwargs)
        return wrapper
    return decorator


# ============================================================================
# Error Handlers
# ============================================================================

@app.errorhandler(404)
def not_found(error):
    """Handle 404 errors."""
    return jsonify({'error': 'Resource not found'}), 404


@app.errorhandler(500)
def internal_error(error):
    """Handle 500 errors."""
    logger.error(f"Internal server error: {error}")
    return jsonify({'error': 'Internal server error'}), 500


@app.errorhandler(psycopg2.Error)
def database_error(error):
    """Handle database errors."""
    logger.error(f"Database error: {error}")
    return jsonify({'error': 'Database error occurred'}), 500


# ============================================================================
# API Routes
# ============================================================================

@app.route('/')
def index():
    """Render the main page."""
    return render_template('index.html')


@app.route('/api/tenants')
def get_tenants():
    """
    Get all tenants.

    Returns:
        JSON array of tenant objects
    """
    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            cur.execute('SELECT * FROM tenants ORDER BY name')
            tenants = cur.fetchall()
    return jsonify(tenants)


@app.route('/api/tenants/<tenant_id>/equipments')
@validate_uuid('tenant_id')
def get_equipments(tenant_id):
    """
    Get equipments for a tenant with hierarchy information.

    Uses recursive CTE to build equipment tree with depth levels.

    Args:
        tenant_id: Tenant UUID

    Returns:
        JSON array of equipment objects with depth field
    """
    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            cur.execute('''
                WITH RECURSIVE equipment_tree AS (
                    SELECT id, name, parent_equipment_id, manufacturer, description, 0 AS depth
                    FROM equipments
                    WHERE tenant_id = %s AND parent_equipment_id IS NULL
                    UNION ALL
                    SELECT e.id, e.name, e.parent_equipment_id, e.manufacturer, e.description, et.depth + 1
                    FROM equipments e
                    JOIN equipment_tree et ON e.parent_equipment_id = et.id
                )
                SELECT * FROM equipment_tree ORDER BY depth, name
            ''', (tenant_id,))
            equipments = cur.fetchall()
    return jsonify(equipments)


@app.route('/api/tenants/<tenant_id>/parts')
@validate_uuid('tenant_id')
def get_parts(tenant_id):
    """
    Get parts for a tenant with related equipment information.

    Args:
        tenant_id: Tenant UUID

    Returns:
        JSON array of part objects with related_equipments field
    """
    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            cur.execute('''
                SELECT p.*,
                       COALESCE(
                           (SELECT STRING_AGG(e.name, ', ')
                            FROM equipment_parts ep
                            JOIN equipments e ON ep.equipment_id = e.id
                            WHERE ep.part_id = p.id), ''
                       ) AS related_equipments
                FROM parts p
                WHERE p.tenant_id = %s
                ORDER BY p.name
            ''', (tenant_id,))
            parts = cur.fetchall()
    return jsonify(parts)


@app.route('/api/tenants/<tenant_id>/tasks')
@validate_uuid('tenant_id')
def get_tasks(tenant_id):
    """
    Get tasks for a tenant.

    Args:
        tenant_id: Tenant UUID

    Returns:
        JSON array of task objects ordered by created_at DESC
    """
    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            cur.execute('''
                SELECT t.*, e.name AS equipment_name
                FROM tasks t
                JOIN equipments e ON t.equipment_id = e.id
                WHERE t.tenant_id = %s
                ORDER BY t.created_at DESC
            ''', (tenant_id,))
            tasks = cur.fetchall()
    return jsonify(tasks)


@app.route('/api/tasks/<task_id>/details')
@validate_uuid('task_id')
def get_task_details(task_id):
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
            cur.execute('''
                SELECT t.*, e.name AS equipment_name
                FROM tasks t
                JOIN equipments e ON t.equipment_id = e.id
                WHERE t.id = %s
            ''', (task_id,))
            task = cur.fetchone()

            if not task:
                return jsonify({
                    'task': None,
                    'custom_fields': [],
                    'parts': [],
                    'comments': []
                })

            # Custom fields (EAV pattern - Value retrieval)
            cur.execute('''
                SELECT cfd.field_name, cfd.field_type, cfv.value
                FROM custom_field_values cfv
                JOIN custom_field_definitions cfd ON cfv.field_definition_id = cfd.id
                WHERE cfv.task_id = %s
                ORDER BY cfd.display_order
            ''', (task_id,))
            custom_fields = cur.fetchall()

            # Parts used
            cur.execute('''
                SELECT p.name, p.part_number, tp.quantity
                FROM task_parts tp
                JOIN parts p ON tp.part_id = p.id
                WHERE tp.task_id = %s
            ''', (task_id,))
            parts = cur.fetchall()

            # Comments (課題2: タスクコメント機能)
            cur.execute('''
                SELECT commented_by, comment, created_at
                FROM task_comments
                WHERE task_id = %s AND deleted_at IS NULL
                ORDER BY created_at
            ''', (task_id,))
            comments = cur.fetchall()

    return jsonify({
        'task': task,
        'custom_fields': custom_fields,
        'parts': parts,
        'comments': comments
    })


@app.route('/api/tenants/<tenant_id>/custom_fields')
@validate_uuid('tenant_id')
def get_custom_field_definitions(tenant_id):
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
        with get_db_cursor(conn) as cur:
            cur.execute('''
                SELECT * FROM custom_field_definitions
                WHERE tenant_id = %s
                ORDER BY display_order
            ''', (tenant_id,))
            fields = cur.fetchall()
    return jsonify(fields)


@app.route('/api/tenants/<tenant_id>/stats')
@validate_uuid('tenant_id')
def get_stats(tenant_id):
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
        with get_db_cursor(conn) as cur:
            # Tasks by status
            cur.execute('''
                SELECT status, COUNT(*) as count
                FROM tasks
                WHERE tenant_id = %s
                GROUP BY status
            ''', (tenant_id,))
            tasks_by_status = cur.fetchall()

            # Tasks by equipment
            cur.execute('''
                SELECT e.name, COUNT(t.id) as count
                FROM equipments e
                LEFT JOIN tasks t ON e.id = t.equipment_id
                WHERE e.tenant_id = %s
                GROUP BY e.id, e.name
                ORDER BY count DESC
            ''', (tenant_id,))
            tasks_by_equipment = cur.fetchall()

            # Parts low stock (at or below reorder point)
            cur.execute('''
                SELECT name, part_number, stock_quantity, reorder_point
                FROM parts
                WHERE tenant_id = %s AND stock_quantity <= reorder_point
                ORDER BY stock_quantity
            ''', (tenant_id,))
            low_stock_parts = cur.fetchall()

    return jsonify({
        'tasks_by_status': tasks_by_status,
        'tasks_by_equipment': tasks_by_equipment,
        'low_stock_parts': low_stock_parts
    })


# ============================================================================
# Health Check Endpoint
# ============================================================================

@app.route('/health')
def health_check():
    """
    Health check endpoint for container orchestration.

    Returns:
        JSON object with health status
    """
    try:
        with get_db_connection() as conn:
            with get_db_cursor(conn) as cur:
                cur.execute('SELECT 1')
        return jsonify({'status': 'healthy', 'database': 'connected'})
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({'status': 'unhealthy', 'database': 'disconnected'}), 503


# ============================================================================
# Main Entry Point
# ============================================================================

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
