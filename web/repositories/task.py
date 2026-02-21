"""Task repository for M2X Task Management System."""

from __future__ import annotations

from typing import Any

from repositories.base import BaseRepository


class TaskRepository(BaseRepository):
    """Repository for task operations."""

    @property
    def table_name(self) -> str:
        return "tasks"

    def find_by_id(self, task_id: str, tenant_id: str | None = None) -> dict[str, Any] | None:
        """Find a task by ID."""
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
        """Find all tasks for a tenant with optional filters."""
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
        """Count tasks for a tenant with optional filters."""
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
        """Create a new task."""
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
        """Update a task with optimistic locking."""
        set_parts = []
        params: list[Any] = []

        for field in [
            "title",
            "description",
            "status",
            "priority",
            "category",
            "assigned_to",
            "due_date",
        ]:
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
        """Soft delete a task."""
        query = "UPDATE tasks SET deleted_at = NOW() WHERE id = %s AND deleted_at IS NULL"
        rows = self._execute_write(query, (task_id,))
        return rows > 0


task_repository = TaskRepository()
