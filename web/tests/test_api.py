"""
API endpoint tests for M2X Task Management System.

These tests verify:
- All API endpoints return correct responses
- Response structure matches expected format
- Error handling for invalid inputs
- Multi-tenant data filtering
"""

import json

import pytest

# Test tenant IDs (from seed data)
TEST_TENANT_ID = "11111111-1111-1111-1111-111111111111"
TEST_TENANT_ID_2 = "22222222-2222-2222-2222-222222222222"


class TestTenantsAPI:
    """Test /api/tenants endpoint."""

    def test_get_tenants_returns_list(self, client):
        """Verify GET /api/tenants returns a list of tenants."""
        response = client.get("/api/tenants")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert isinstance(data, list)
        assert len(data) >= 2  # At least 2 tenants from seed data

    def test_get_tenants_has_required_fields(self, client):
        """Verify tenant objects have required fields."""
        response = client.get("/api/tenants")
        data = json.loads(response.data)

        for tenant in data:
            assert "id" in tenant
            assert "name" in tenant
            assert "created_at" in tenant


class TestEquipmentsAPI:
    """Test /api/tenants/<tenant_id>/equipments endpoint."""

    def test_get_equipments_returns_list(self, client):
        """Verify GET equipments returns a list."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/equipments")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert isinstance(data, list)

    def test_get_equipments_includes_hierarchy_depth(self, client):
        """Verify equipments include depth for hierarchy display."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/equipments")
        data = json.loads(response.data)

        if len(data) > 0:
            assert "depth" in data[0], "Equipment should include depth field"

    def test_get_equipments_tenant_isolation(self, client):
        """Verify equipments are filtered by tenant."""
        response1 = client.get(f"/api/tenants/{TEST_TENANT_ID}/equipments")
        response2 = client.get(f"/api/tenants/{TEST_TENANT_ID_2}/equipments")

        data1 = json.loads(response1.data)
        data2 = json.loads(response2.data)

        # Equipment IDs should be different between tenants
        ids1 = {e["id"] for e in data1}
        ids2 = {e["id"] for e in data2}

        assert ids1.isdisjoint(ids2), "Tenants should have separate equipment"

    def test_get_equipments_invalid_tenant(self, client):
        """Verify invalid tenant ID returns empty list."""
        response = client.get(
            "/api/tenants/00000000-0000-0000-0000-000000000000/equipments"
        )

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data == []


class TestPartsAPI:
    """Test /api/tenants/<tenant_id>/parts endpoint."""

    def test_get_parts_returns_list(self, client):
        """Verify GET parts returns a list."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/parts")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert isinstance(data, list)

    def test_get_parts_has_required_fields(self, client):
        """Verify parts have all required fields from spec."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/parts")
        data = json.loads(response.data)

        if len(data) > 0:
            part = data[0]
            assert "id" in part
            assert "name" in part
            assert "part_number" in part
            assert "location" in part
            assert "stock_quantity" in part
            assert "reorder_point" in part
            assert "related_equipments" in part

    def test_get_parts_includes_related_equipments(self, client):
        """Verify parts include related equipment information."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/parts")
        data = json.loads(response.data)

        # Find a part that has related equipment
        parts_with_equipment = [p for p in data if p.get("related_equipments")]
        assert len(parts_with_equipment) > 0, "Some parts should have related equipment"


class TestTasksAPI:
    """Test /api/tenants/<tenant_id>/tasks endpoint."""

    def test_get_tasks_returns_list(self, client):
        """Verify GET tasks returns a list."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert isinstance(data, list)

    def test_get_tasks_has_required_fields(self, client):
        """Verify tasks have all required fields."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")
        data = json.loads(response.data)

        if len(data) > 0:
            task = data[0]
            assert "id" in task
            assert "title" in task
            assert "status" in task
            assert "equipment_name" in task

    def test_get_tasks_ordered_by_created_at(self, client):
        """Verify tasks are ordered by created_at descending."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")
        data = json.loads(response.data)

        if len(data) > 1:
            for i in range(1, len(data)):
                assert data[i - 1]["created_at"] >= data[i]["created_at"]


class TestTaskDetailsAPI:
    """Test /api/tasks/<task_id>/details endpoint."""

    def test_get_task_details_structure(self, client, sample_task_id):
        """Verify task details response structure."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = client.get(f"/api/tasks/{sample_task_id}/details")

        assert response.status_code == 200
        data = json.loads(response.data)

        assert "task" in data
        assert "custom_fields" in data
        assert "parts" in data
        assert "comments" in data

    def test_get_task_details_task_info(self, client, sample_task_id):
        """Verify task info in details response."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = client.get(f"/api/tasks/{sample_task_id}/details")
        data = json.loads(response.data)

        task = data["task"]
        assert "id" in task
        assert "title" in task
        assert "status" in task
        assert "equipment_name" in task

    def test_get_task_details_custom_fields(self, client, sample_task_id):
        """Verify custom fields in task details (EAV pattern)."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = client.get(f"/api/tasks/{sample_task_id}/details")
        data = json.loads(response.data)

        custom_fields = data["custom_fields"]
        assert isinstance(custom_fields, list)

        if len(custom_fields) > 0:
            field = custom_fields[0]
            assert "field_name" in field
            assert "field_type" in field
            assert "value" in field

    def test_get_task_details_comments(self, client, sample_task_id):
        """Verify comments in task details (課題2)."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = client.get(f"/api/tasks/{sample_task_id}/details")
        data = json.loads(response.data)

        comments = data["comments"]
        assert isinstance(comments, list)

        if len(comments) > 0:
            comment = comments[0]
            assert "commented_by" in comment
            assert "comment" in comment
            assert "created_at" in comment

    def test_get_task_details_invalid_id(self, client):
        """Verify invalid task ID handling."""
        response = client.get("/api/tasks/00000000-0000-0000-0000-000000000000/details")

        # Should return 200 with null task or 404
        # Current implementation returns 200 with null
        assert response.status_code in [200, 404]


class TestCustomFieldsAPI:
    """Test /api/tenants/<tenant_id>/custom_fields endpoint."""

    def test_get_custom_fields_returns_list(self, client):
        """Verify GET custom_fields returns a list."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/custom_fields")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert isinstance(data, list)

    def test_get_custom_fields_has_required_fields(self, client):
        """Verify custom field definitions have required fields."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/custom_fields")
        data = json.loads(response.data)

        if len(data) > 0:
            field = data[0]
            assert "id" in field
            assert "field_name" in field
            assert "field_type" in field
            assert "is_required" in field
            assert "display_order" in field

    def test_get_custom_fields_tenant_isolation(self, client):
        """Verify custom fields are tenant-specific."""
        response1 = client.get(f"/api/tenants/{TEST_TENANT_ID}/custom_fields")
        response2 = client.get(f"/api/tenants/{TEST_TENANT_ID_2}/custom_fields")

        data1 = json.loads(response1.data)
        data2 = json.loads(response2.data)

        # Field names should be different between tenants
        names1 = {f["field_name"] for f in data1}
        names2 = {f["field_name"] for f in data2}

        # At least some fields should be different
        assert names1 != names2 or (len(names1) == 0 and len(names2) == 0)


class TestStatsAPI:
    """Test /api/tenants/<tenant_id>/stats endpoint."""

    def test_get_stats_structure(self, client):
        """Verify stats response structure."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/stats")

        assert response.status_code == 200
        data = json.loads(response.data)

        assert "tasks_by_status" in data
        assert "tasks_by_equipment" in data
        assert "low_stock_parts" in data

    def test_get_stats_tasks_by_status(self, client):
        """Verify tasks_by_status in stats."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/stats")
        data = json.loads(response.data)

        tasks_by_status = data["tasks_by_status"]
        assert isinstance(tasks_by_status, list)

        for item in tasks_by_status:
            assert "status" in item
            assert "count" in item
            assert item["status"] in ["todo", "in_progress", "done"]

    def test_get_stats_low_stock_parts(self, client):
        """Verify low_stock_parts identifies parts below reorder point."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/stats")
        data = json.loads(response.data)

        low_stock = data["low_stock_parts"]
        assert isinstance(low_stock, list)

        for part in low_stock:
            assert "name" in part
            assert "stock_quantity" in part
            assert "reorder_point" in part
            # Stock should be at or below reorder point
            assert part["stock_quantity"] <= part["reorder_point"]


class TestIndexPage:
    """Test index page rendering."""

    def test_index_returns_html(self, client):
        """Verify index page returns HTML."""
        response = client.get("/")

        assert response.status_code == 200
        assert b"<!DOCTYPE html>" in response.data
        assert b"M2X" in response.data
