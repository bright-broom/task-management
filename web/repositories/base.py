"""Base repository for M2X Task Management System."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Generic, Literal, TypeVar, overload

from infrastructure.database import get_db_connection, get_db_cursor, tenant_context

T = TypeVar("T")


class BaseRepository(ABC, Generic[T]):
    """Abstract base repository providing common database operations."""

    @property
    @abstractmethod
    def table_name(self) -> str:
        """Return the table name for this repository."""
        ...

    def _execute_query(
        self,
        query: str,
        params: tuple[Any, ...] | None = None,
        tenant_id: str | None = None,
    ) -> list[dict[str, Any]]:
        """Execute a SELECT query and return all results."""
        with get_db_connection() as conn:
            if tenant_id:
                with tenant_context(conn, tenant_id) as cur:
                    cur.execute(query, params)
                    return cur.fetchall()
            else:
                with get_db_cursor(conn) as cur:
                    cur.execute(query, params)
                    return cur.fetchall()

    def _execute_one(
        self,
        query: str,
        params: tuple[Any, ...] | None = None,
        tenant_id: str | None = None,
    ) -> dict[str, Any] | None:
        """Execute a SELECT query and return the first result."""
        results = self._execute_query(query, params, tenant_id)
        return results[0] if results else None

    @overload
    def _execute_write(
        self,
        query: str,
        params: tuple[Any, ...] | None = None,
        tenant_id: str | None = None,
        *,
        return_result: Literal[True],
    ) -> dict[str, Any]: ...

    @overload
    def _execute_write(
        self,
        query: str,
        params: tuple[Any, ...] | None = None,
        tenant_id: str | None = None,
        *,
        return_result: Literal[False] = ...,
    ) -> int: ...

    def _execute_write(
        self,
        query: str,
        params: tuple[Any, ...] | None = None,
        tenant_id: str | None = None,
        return_result: bool = False,
    ) -> dict[str, Any] | int:
        """Execute an INSERT/UPDATE/DELETE query."""
        with get_db_connection() as conn:
            if tenant_id:
                with tenant_context(conn, tenant_id) as cur:
                    cur.execute(query, params)
                    conn.commit()
                    if return_result:
                        return cur.fetchone()
                    return cur.rowcount
            else:
                with get_db_cursor(conn) as cur:
                    cur.execute(query, params)
                    conn.commit()
                    if return_result:
                        return cur.fetchone()
                    return cur.rowcount
