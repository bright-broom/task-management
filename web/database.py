"""Backward compatibility re-export for database module.

This module re-exports from infrastructure.database for backward compatibility.
New code should import from infrastructure.database directly.
"""

from infrastructure.database import (
    DATABASE_URL,
    POOL_MAX_CONNECTIONS,
    POOL_MIN_CONNECTIONS,
    close_connection_pool,
    get_connection_pool,
    get_db_connection,
    get_db_cursor,
    tenant_context,
)

__all__ = [
    "DATABASE_URL",
    "POOL_MIN_CONNECTIONS",
    "POOL_MAX_CONNECTIONS",
    "get_connection_pool",
    "close_connection_pool",
    "get_db_connection",
    "get_db_cursor",
    "tenant_context",
]
