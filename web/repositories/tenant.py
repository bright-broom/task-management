"""Tenant repository for M2X Task Management System."""

from __future__ import annotations

from typing import Any

from repositories.base import BaseRepository


class TenantRepository(BaseRepository):
    """Repository for tenant operations."""

    @property
    def table_name(self) -> str:
        return "tenants"

    def find_all(self) -> list[dict[str, Any]]:
        """Find all tenants."""
        query = "SELECT * FROM tenants ORDER BY name"
        return self._execute_query(query)

    def find_by_id(self, tenant_id: str) -> dict[str, Any] | None:
        """Find a tenant by ID."""
        query = "SELECT * FROM tenants WHERE id = %s"
        return self._execute_one(query, (tenant_id,))


tenant_repository = TenantRepository()
