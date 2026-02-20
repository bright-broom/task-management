"""
Database connection management for M2X Task Management System.

This module provides:
- Connection pool management (ThreadedConnectionPool)
- Database context managers
- Row Level Security (RLS) tenant context
"""

from __future__ import annotations

import atexit
import os
from contextlib import contextmanager
from typing import Any, Generator

import psycopg2
from logging_config import get_logger
from psycopg2 import pool
from psycopg2.extras import RealDictCursor

logger = get_logger(__name__)

# Database URL from environment
DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql://m2x_user:m2x_password@db:5432/m2x_task_management"
)

# Connection pool configuration
POOL_MIN_CONNECTIONS = int(os.environ.get("POOL_MIN_CONNECTIONS", "2"))
POOL_MAX_CONNECTIONS = int(os.environ.get("POOL_MAX_CONNECTIONS", "20"))

# Global connection pool (lazy initialization)
_connection_pool: pool.ThreadedConnectionPool | None = None


def get_connection_pool() -> pool.ThreadedConnectionPool:
    """
    Get thread-safe connection pool (singleton pattern).

    Returns:
        ThreadedConnectionPool: Database connection pool
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
    """Close connection pool on application shutdown."""
    global _connection_pool
    if _connection_pool is not None:
        _connection_pool.closeall()
        _connection_pool = None
        logger.info("Connection pool closed")


# Register cleanup on application exit
atexit.register(close_connection_pool)


@contextmanager
def get_db_connection() -> Generator[Any, None, None]:
    """
    Database connection context manager with connection pooling.

    Gets a connection from the pool and returns it after use.
    This reduces connection creation overhead and improves performance.

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
    - app.current_tenant_id: Tenant isolation
    - app.current_user_id: User tracking for audit logs
    - app.current_user_name: User name snapshot for audit logs

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
