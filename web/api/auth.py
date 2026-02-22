"""
Authentication API endpoints.

This module provides REST API endpoints for:
- User login
- Token refresh
- Current user info
"""

from __future__ import annotations

from datetime import datetime, timezone

from api import auth_bp
from database import get_db_connection, get_db_cursor, tenant_context
from flask import Response, g, jsonify, request
from security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    rate_limit,
    require_auth,
    security_logger,
    validate_email,
    verify_password,
)
from validators import is_valid_uuid


@auth_bp.route("/api/auth/login", methods=["POST"])
@rate_limit(limit=10, window_seconds=60)  # Strict rate limit for login
def login() -> tuple[Response, int]:
    """
    User authentication endpoint.

    Request Body:
        email: User email address
        password: Password
        tenant_id: Tenant ID

    Returns:
        JWT tokens
    """
    if not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 400

    data = request.get_json()
    if not data:
        return jsonify({"error": "Request body required"}), 400

    # Handle explicit null as precondition violation (same as missing)
    email = (data.get("email") or "").strip().lower()
    password = data.get("password") or ""
    tenant_id = data.get("tenant_id") or ""

    # Input validation
    if not email or not password or not tenant_id:
        security_logger.login_failure(email, "missing_fields")
        return jsonify({"error": "Email, password, and tenant_id are required"}), 400

    if not validate_email(email):
        security_logger.login_failure(email, "invalid_email")
        return jsonify({"error": "Invalid email format"}), 400

    if not is_valid_uuid(tenant_id):
        security_logger.login_failure(email, "invalid_tenant")
        return jsonify({"error": "Invalid tenant_id format"}), 400

    with get_db_connection() as conn:
        with get_db_cursor(conn) as cur:
            # User lookup
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

            # Account lock check
            if user["status"] == "locked" or (
                user["locked_until"] and user["locked_until"] > datetime.now(timezone.utc)
            ):
                security_logger.login_failure(email, "account_locked", tenant_id)
                return jsonify({"error": "Account is locked"}), 403

            # Password verification
            if not user["password_hash"] or not verify_password(password, user["password_hash"]):
                # Increment failure count
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

            # Login success: reset counter
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

    # Generate tokens
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


@auth_bp.route("/api/auth/refresh", methods=["POST"])
@rate_limit(limit=30, window_seconds=60)
def refresh_token() -> tuple[Response, int]:
    """
    Refresh access token using refresh token.

    Request Body:
        refresh_token: Refresh token

    Returns:
        New access token
    """
    if not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 400

    data = request.get_json()
    # Handle explicit null as precondition violation
    refresh_token_str = data.get("refresh_token") or ""

    if not refresh_token_str:
        return jsonify({"error": "Refresh token required"}), 400

    # Token verification
    payload = decode_token(refresh_token_str)
    if not payload or payload.get("type") != "refresh":
        return jsonify({"error": "Invalid refresh token"}), 401

    user_id = payload.get("sub")
    tenant_id = payload.get("tenant_id")

    if not isinstance(tenant_id, str):
        return jsonify({"error": "Invalid token payload"}), 401

    # Get fresh user info
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

    # Generate new access token
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


@auth_bp.route("/api/auth/me", methods=["GET"])
@require_auth
def get_current_user() -> tuple[Response, int]:
    """
    Get current authenticated user info.

    Returns:
        User info
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
