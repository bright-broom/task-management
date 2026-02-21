"""Equipment repository for M2X Task Management System."""

from __future__ import annotations

from typing import Any

from repositories.base import BaseRepository


class EquipmentRepository(BaseRepository):
    """Repository for equipment operations."""

    @property
    def table_name(self) -> str:
        return "equipments"

    def find_by_id(self, equipment_id: str, tenant_id: str) -> dict[str, Any] | None:
        """Find equipment by ID."""
        query = "SELECT * FROM equipments WHERE id = %s AND tenant_id = %s"
        return self._execute_one(query, (equipment_id, tenant_id), tenant_id)

    def exists(self, equipment_id: str, tenant_id: str) -> bool:
        """Check if equipment exists."""
        result = self.find_by_id(equipment_id, tenant_id)
        return result is not None

    def find_all_by_tenant(
        self,
        tenant_id: str,
        limit: int = 20,
        offset: int = 0,
    ) -> list[dict[str, Any]]:
        """Find all equipment for a tenant with hierarchy."""
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


equipment_repository = EquipmentRepository()
