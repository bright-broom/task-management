"""
M2X Task Management System - Web API

A multi-tenant task management system for factory operations.

Features:
- Multi-tenant architecture with Row Level Security
- JWT authentication with role-based access control
- Equipment hierarchy management
- Parts inventory management
- Task management with custom fields and comments

Security:
- CORS, CSP, HSTS headers
- Rate limiting
- Input validation
- Parameterized queries
"""

from __future__ import annotations

from typing import Any

import psycopg2
from core import get_config
from database import get_db_connection, get_db_cursor, tenant_context
from flask import Flask, Response, jsonify, render_template
from logging_config import configure_logging, get_logger, setup_flask_logging
from metrics import init_metrics, metrics_endpoint
from security import init_security, rate_limit
from validators import PaginationParams, build_pagination_response, validate_uuid

config = get_config()

app = Flask(__name__)
app.config["JSON_AS_ASCII"] = config.json_as_ascii
app.config["SECRET_KEY"] = config.security.secret_key
app.config["SECURITY_DB_LOGGING"] = config.logging.db_logging

init_security(app)
init_metrics(app)
configure_logging()
logger = get_logger(__name__)
setup_flask_logging(app)

from swagger_config import init_swagger  # noqa: E402

init_swagger(app)

from api import register_blueprints  # noqa: E402

register_blueprints(app)


@app.errorhandler(404)
def not_found(error: Exception) -> tuple[Response, int]:
    return jsonify({"error": "Resource not found"}), 404


@app.errorhandler(500)
def internal_error(error: Exception) -> tuple[Response, int]:
    logger.error(f"Internal server error: {error}")
    return jsonify({"error": "Internal server error"}), 500


@app.errorhandler(psycopg2.Error)
def database_error(error: psycopg2.Error) -> tuple[Response, int]:
    logger.error(f"Database error: {error}")
    return jsonify({"error": "Database error occurred"}), 500


@app.route("/")
def index() -> str:
    return render_template("index.html")


@app.route("/metrics")
def metrics() -> tuple[Response, int]:
    """
    Prometheusメトリクスエンドポイント
    ---
    tags:
      - Monitoring
    responses:
      200:
        description: Prometheus形式のメトリクス
        content:
          text/plain:
            schema:
              type: string
    """
    return metrics_endpoint()


@app.route("/health")
@rate_limit(limit=120, window_seconds=60)
def health_check() -> tuple[Response, int]:
    """
    ヘルスチェックエンドポイント
    ---
    tags:
      - Health
    responses:
      200:
        description: サービス正常
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/HealthCheck'
      503:
        description: サービス異常
    """
    try:
        with get_db_connection() as conn:
            with get_db_cursor(conn) as cur:
                cur.execute("SELECT 1")
        return jsonify({"status": "healthy", "database": "connected"}), 200
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({"status": "unhealthy", "database": "disconnected"}), 503


@app.route("/api/tenants")
def get_tenants() -> Response:
    """
    テナント一覧取得
    ---
    tags:
      - Tenants
    responses:
      200:
        description: テナント一覧
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
    設備一覧取得（階層構造対応）
    ---
    tags:
      - Equipments
    """
    pagination = PaginationParams.from_request(default_sort="name")

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            cur.execute(
                "SELECT COUNT(*) as count FROM equipments WHERE tenant_id = %s",
                (tenant_id,),
            )
            total = cur.fetchone()["count"]

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

    return jsonify(build_pagination_response(equipments, pagination, total))


@app.route("/api/tenants/<tenant_id>/parts")
@validate_uuid("tenant_id")
def get_parts(tenant_id: str) -> Response:
    """
    部品一覧取得
    ---
    tags:
      - Parts
    """
    from flask import request

    pagination = PaginationParams.from_request(default_sort="name")
    low_stock_only = request.args.get("low_stock", "").lower() == "true"

    with get_db_connection() as conn:
        with tenant_context(conn, tenant_id) as cur:
            conditions = ["p.tenant_id = %s"]
            params: list[Any] = [tenant_id]

            if low_stock_only:
                conditions.append("p.stock_quantity <= p.reorder_point")

            where_clause = "WHERE " + " AND ".join(conditions)

            cur.execute(
                f"SELECT COUNT(*) as count FROM parts p {where_clause}",
                params,
            )
            total = cur.fetchone()["count"]

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

    return jsonify(build_pagination_response(parts, pagination, total))


if config.debug:
    logger.warning("DEBUG MODE IS ENABLED - DO NOT USE IN PRODUCTION")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=config.debug)  # nosec B104
