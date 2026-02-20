"""
Repository layer for M2X Task Management System.

This module provides data access abstraction using the Repository pattern.
Each repository encapsulates database operations for a specific entity.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Generic, TypeVar

from database import get_db_connection, get_db_cursor, tenant_context

T = TypeVar("T")


class BaseRepository(ABC, Generic[T]):
    """Abstract base repository."""

    @property
    @abstractmethod
    def table_name(self) -> str:
        ...

    def _execute_query(
        self,
        query: str,
        params: tuple[Any, ...] | None = None,
        tenant_id: str | None = None,
    ) -> list[dict[str, Any]]:
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
        results = self._execute_query(query, params, tenant_id)
        return results[0] if results else None

    def _execute_write(
        self,
        query: str,
        params: tuple[Any, ...] | None = None,
        tenant_id: str | None = None,
        return_result: bool = False,
    ) -> dict[str, Any] | int:
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


class TaskRepository(BaseRepository):
    @property
    def table_name(self) -> str:
        return "tasks"

    def find_by_id(self, task_id: str, tenant_id: str | None = None) -> dict[str, Any] | None:
        query = """
            SELECT t.*, e.name as equipment_name
            FROM tasks t
            LEFT JOIN equipments e ON t.equipment_id = e.id
            WHERE t.id = %s
        """
        if tenant_id:
            query += " AND t.tenant_id = %s"
            return self._execute_one(query, (task_id, tenant_id), tenant_id)
        return self._execute_one(query, (task_id,))

    def find_all_by_tenant(
        self,
        tenant_id: str,
        limit: int = 20,
        offset: int = 0,
        status: str | None = None,
        priority: str | None = None,
        category: str | None = None,
    ) -> list[dict[str, Any]]:
        conditions = ["t.tenant_id = %s"]
        params: list[Any] = [tenant_id]

        if status:
            conditions.append("t.status = %s")
            params.append(status)
        if priority:
            conditions.append("t.priority = %s")
            params.append(priority)
        if category:
            conditions.append("t.category = %s")
            params.append(category)

        where_clause = " AND ".join(conditions)
        query = f"""
            SELECT t.*, e.name as equipment_name
            FROM tasks t
            LEFT JOIN equipments e ON t.equipment_id = e.id
            WHERE {where_clause}
            ORDER BY t.created_at DESC
            LIMIT %s OFFSET %s
        """
        params.extend([limit, offset])
        return self._execute_query(query, tuple(params), tenant_id)

    def count_by_tenant(
        self,
        tenant_id: str,
        status: str | None = None,
        priority: str | None = None,
        category: str | None = None,
    ) -> int:
        conditions = ["tenant_id = %s"]
        params: list[Any] = [tenant_id]

        if status:
            conditions.append("status = %s")
            params.append(status)
        if priority:
            conditions.append("priority = %s")
            params.append(priority)
        if category:
            conditions.append("category = %s")
            params.append(category)

        where_clause = " AND ".join(conditions)
        query = f"SELECT COUNT(*) as count FROM tasks WHERE {where_clause}"
        result = self._execute_one(query, tuple(params), tenant_id)
        return result["count"] if result else 0

    def create(self, tenant_id: str, data: dict[str, Any]) -> dict[str, Any]:
        query = """
            INSERT INTO tasks (tenant_id, equipment_id, title, description,
                             status, priority, category, assigned_to, due_date)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING *
        """
        params = (
            tenant_id,
            data.get("equipment_id"),
            data.get("title"),
            data.get("description"),
            data.get("status", "open"),
            data.get("priority", "medium"),
            data.get("category", "maintenance"),
            data.get("assigned_to"),
            data.get("due_date"),
        )
        return self._execute_write(query, params, tenant_id, return_result=True)

    def update(
        self,
        task_id: str,
        data: dict[str, Any],
        version: int,
    ) -> dict[str, Any] | None:
        set_parts = []
        params: list[Any] = []

        for field in ["title", "description", "status", "priority", "category", "assigned_to", "due_date"]:
            if field in data and data[field] is not None:
                set_parts.append(f"{field} = %s")
                params.append(data[field])

        if not set_parts:
            return None

        set_parts.append("version = version + 1")
        set_parts.append("updated_at = NOW()")
        set_clause = ", ".join(set_parts)

        params.extend([task_id, version])

        query = f"""
            UPDATE tasks
            SET {set_clause}
            WHERE id = %s AND version = %s
            RETURNING *
        """
        return self._execute_write(query, tuple(params), return_result=True)

    def delete(self, task_id: str) -> bool:
        query = "UPDATE tasks SET deleted_at = NOW() WHERE id = %s AND deleted_at IS NULL"
        rows = self._execute_write(query, (task_id,))
        return rows > 0


class CommentRepository(BaseRepository):
    @property
    def table_name(self) -> str:
        return "task_comments"

    def find_by_task_id(self, task_id: str, tenant_id: str) -> list[dict[str, Any]]:
        query = """
            SELECT * FROM task_comments
            WHERE task_id = %s AND tenant_id = %s AND deleted_at IS NULL
            ORDER BY created_at ASC
        """
        return self._execute_query(query, (task_id, tenant_id), tenant_id)

    def create(self, tenant_id: str, task_id: str, data: dict[str, Any]) -> dict[str, Any]:
        query = """
            INSERT INTO task_comments (tenant_id, task_id, commented_by, comment)
            VALUES (%s, %s, %s, %s)
            RETURNING *
        """
        params = (tenant_id, task_id, data.get("commented_by"), data.get("comment"))
        return self._execute_write(query, params, tenant_id, return_result=True)

    def delete(self, comment_id: str) -> bool:
        query = "UPDATE task_comments SET deleted_at = NOW() WHERE id = %s AND deleted_at IS NULL"
        rows = self._execute_write(query, (comment_id,))
        return rows > 0

    def find_by_id(self, comment_id: str) -> dict[str, Any] | None:
        query = "SELECT * FROM task_comments WHERE id = %s AND deleted_at IS NULL"
        return self._execute_one(query, (comment_id,))


class EquipmentRepository(BaseRepository):
    @property
    def table_name(self) -> str:
        return "equipments"

    def find_by_id(self, equipment_id: str, tenant_id: str) -> dict[str, Any] | None:
        query = "SELECT * FROM equipments WHERE id = %s AND tenant_id = %s"
        return self._execute_one(query, (equipment_id, tenant_id), tenant_id)

    def exists(self, equipment_id: str, tenant_id: str) -> bool:
        result = self.find_by_id(equipment_id, tenant_id)
        return result is not None

    def find_all_by_tenant(
        self,
        tenant_id: str,
        limit: int = 20,
        offset: int = 0,
    ) -> list[dict[str, Any]]:
        query = """
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
        """
        return self._execute_query(query, (tenant_id, tenant_id, limit, offset), tenant_id)


class PartRepository(BaseRepository):
    @property
    def table_name(self) -> str:
        return "parts"

    def find_all_by_tenant(
        self,
        tenant_id: str,
        limit: int = 20,
        offset: int = 0,
        low_stock_only: bool = False,
    ) -> list[dict[str, Any]]:
        conditions = ["p.tenant_id = %s"]
        params: list[Any] = [tenant_id]

        if low_stock_only:
            conditions.append("p.stock_quantity <= p.reorder_point")

        where_clause = " AND ".join(conditions)
        query = f"""
            SELECT p.*,
                   COALESCE(
                       (SELECT STRING_AGG(e.name, ', ')
                        FROM equipment_parts ep
                        JOIN equipments e ON ep.equipment_id = e.id
                        WHERE ep.part_id = p.id), ''
                   ) AS related_equipments
            FROM parts p
            WHERE {where_clause}
            ORDER BY p.name
            LIMIT %s OFFSET %s
        """
        params.extend([limit, offset])
        return self._execute_query(query, tuple(params), tenant_id)

    def count_by_tenant(self, tenant_id: str, low_stock_only: bool = False) -> int:
        conditions = ["tenant_id = %s"]
        params: list[Any] = [tenant_id]

        if low_stock_only:
            conditions.append("stock_quantity <= reorder_point")

        where_clause = " AND ".join(conditions)
        query = f"SELECT COUNT(*) as count FROM parts WHERE {where_clause}"
        result = self._execute_one(query, tuple(params), tenant_id)
        return result["count"] if result else 0


class TenantRepository(BaseRepository):
    @property
    def table_name(self) -> str:
        return "tenants"

    def find_all(self) -> list[dict[str, Any]]:
        query = "SELECT * FROM tenants ORDER BY name"
        return self._execute_query(query)

    def find_by_id(self, tenant_id: str) -> dict[str, Any] | None:
        query = "SELECT * FROM tenants WHERE id = %s"
        return self._execute_one(query, (tenant_id,))


task_repository = TaskRepository()
comment_repository = CommentRepository()
equipment_repository = EquipmentRepository()
part_repository = PartRepository()
tenant_repository = TenantRepository()
