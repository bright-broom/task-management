"""Part repository for M2X Task Management System."""

from __future__ import annotations

from typing import Any

from repositories.base import BaseRepository


class PartRepository(BaseRepository):
    """Repository for part operations."""

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
        """Find all parts for a tenant with optional low stock filter."""
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
        """Count parts for a tenant with optional low stock filter."""
        conditions = ["tenant_id = %s"]
        params: list[Any] = [tenant_id]

        if low_stock_only:
            conditions.append("stock_quantity <= reorder_point")

        where_clause = " AND ".join(conditions)
        query = f"SELECT COUNT(*) as count FROM parts WHERE {where_clause}"
        result = self._execute_one(query, tuple(params), tenant_id)
        return result["count"] if result else 0


part_repository = PartRepository()
