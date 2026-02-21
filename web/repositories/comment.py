"""Comment repository for M2X Task Management System."""

from __future__ import annotations

from typing import Any

from repositories.base import BaseRepository


class CommentRepository(BaseRepository):
    """Repository for comment operations."""

    @property
    def table_name(self) -> str:
        return "task_comments"

    def find_by_task_id(self, task_id: str, tenant_id: str) -> list[dict[str, Any]]:
        """Find all comments for a task."""
        query = """
            SELECT * FROM task_comments
            WHERE task_id = %s AND tenant_id = %s AND deleted_at IS NULL
            ORDER BY created_at ASC
        """
        return self._execute_query(query, (task_id, tenant_id), tenant_id)

    def find_by_id(self, comment_id: str) -> dict[str, Any] | None:
        """Find a comment by ID."""
        query = "SELECT * FROM task_comments WHERE id = %s AND deleted_at IS NULL"
        return self._execute_one(query, (comment_id,))

    def create(self, tenant_id: str, task_id: str, data: dict[str, Any]) -> dict[str, Any]:
        """Create a new comment."""
        query = """
            INSERT INTO task_comments (tenant_id, task_id, commented_by, comment)
            VALUES (%s, %s, %s, %s)
            RETURNING *
        """
        params = (tenant_id, task_id, data.get("commented_by"), data.get("comment"))
        return self._execute_write(query, params, tenant_id, return_result=True)

    def delete(self, comment_id: str) -> bool:
        """Soft delete a comment."""
        query = "UPDATE task_comments SET deleted_at = NOW() WHERE id = %s AND deleted_at IS NULL"
        rows = self._execute_write(query, (comment_id,))
        return rows > 0


comment_repository = CommentRepository()
