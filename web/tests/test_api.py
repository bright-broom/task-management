"""
API endpoint tests for M2X Task Management System.

These tests verify:
- All API endpoints return correct responses
- Response structure matches expected format
- Error handling for invalid inputs
- Multi-tenant data filtering
- CRUD operations (Create, Read, Update, Delete)
- Pagination and filtering
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

    def test_get_equipments_returns_paginated_list(self, client):
        """Verify GET equipments returns a paginated list."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/equipments")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert "items" in data
        assert "pagination" in data
        assert isinstance(data["items"], list)

    def test_get_equipments_pagination_metadata(self, client):
        """Verify pagination metadata is correct."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/equipments?page=1&per_page=5")
        data = json.loads(response.data)

        pagination = data["pagination"]
        assert pagination["page"] == 1
        assert pagination["per_page"] == 5
        assert "total" in pagination
        assert "total_pages" in pagination

    def test_get_equipments_includes_hierarchy_depth(self, client):
        """Verify equipments include depth for hierarchy display."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/equipments")
        data = json.loads(response.data)

        if len(data["items"]) > 0:
            assert "depth" in data["items"][0], "Equipment should include depth field"

    def test_get_equipments_tenant_isolation(self, client):
        """Verify equipments are filtered by tenant."""
        response1 = client.get(f"/api/tenants/{TEST_TENANT_ID}/equipments")
        response2 = client.get(f"/api/tenants/{TEST_TENANT_ID_2}/equipments")

        data1 = json.loads(response1.data)
        data2 = json.loads(response2.data)

        # Equipment IDs should be different between tenants
        ids1 = {e["id"] for e in data1["items"]}
        ids2 = {e["id"] for e in data2["items"]}

        assert ids1.isdisjoint(ids2), "Tenants should have separate equipment"

    def test_get_equipments_invalid_tenant(self, client):
        """Verify invalid tenant ID returns empty list."""
        response = client.get("/api/tenants/00000000-0000-0000-0000-000000000000/equipments")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["items"] == []


class TestPartsAPI:
    """Test /api/tenants/<tenant_id>/parts endpoint."""

    def test_get_parts_returns_paginated_list(self, client):
        """Verify GET parts returns a paginated list."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/parts")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert "items" in data
        assert "pagination" in data
        assert isinstance(data["items"], list)

    def test_get_parts_has_required_fields(self, client):
        """Verify parts have all required fields from spec."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/parts")
        data = json.loads(response.data)

        if len(data["items"]) > 0:
            part = data["items"][0]
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
        parts_with_equipment = [p for p in data["items"] if p.get("related_equipments")]
        assert len(parts_with_equipment) > 0, "Some parts should have related equipment"

    def test_get_parts_low_stock_filter(self, client):
        """Verify low_stock filter returns only low stock parts."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/parts?low_stock=true")
        data = json.loads(response.data)

        for part in data["items"]:
            assert part["stock_quantity"] <= part["reorder_point"]


class TestTasksAPI:
    """Test /api/tenants/<tenant_id>/tasks endpoint."""

    def test_get_tasks_returns_paginated_list(self, client):
        """Verify GET tasks returns a paginated list."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert "items" in data
        assert "pagination" in data
        assert isinstance(data["items"], list)

    def test_get_tasks_has_required_fields(self, client):
        """Verify tasks have all required fields."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")
        data = json.loads(response.data)

        if len(data["items"]) > 0:
            task = data["items"][0]
            assert "id" in task
            assert "title" in task
            assert "status" in task
            assert "equipment_name" in task

    def test_get_tasks_ordered_by_created_at(self, client):
        """Verify tasks are ordered by created_at descending."""
        from email.utils import parsedate_to_datetime

        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")
        data = json.loads(response.data)

        items = data["items"]
        if len(items) > 1:
            for i in range(1, len(items)):
                # Parse HTTP date format to datetime for proper comparison
                prev_date = parsedate_to_datetime(items[i - 1]["created_at"])
                curr_date = parsedate_to_datetime(items[i]["created_at"])
                assert prev_date >= curr_date

    def test_get_tasks_status_filter(self, client):
        """Verify status filter works correctly."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?status=todo")
        data = json.loads(response.data)

        for task in data["items"]:
            assert task["status"] == "todo"


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


class TestTaskCRUD:
    """Test Task CRUD operations (Create, Update)."""

    def test_create_task_success(self, auth_client, sample_equipment_id):
        """Verify task creation with valid data."""
        if not sample_equipment_id:
            pytest.skip("No sample equipment available")

        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={
                "title": "Test Task",
                "equipment_id": sample_equipment_id,
                "description": "Test description",
                "status": "todo",
                "assigned_to": "Test User",
            },
            content_type="application/json",
        )

        assert response.status_code == 201
        data = json.loads(response.data)
        assert data["title"] == "Test Task"
        assert data["status"] == "todo"
        assert data["tenant_id"] == TEST_TENANT_ID

    def test_create_task_missing_required_fields(self, auth_client):
        """Verify error when required fields are missing."""
        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={"description": "Only description"},
            content_type="application/json",
        )

        assert response.status_code == 400
        data = json.loads(response.data)
        assert "error" in data
        assert "fields" in data

    def test_create_task_invalid_equipment_id(self, auth_client):
        """Verify error when equipment_id is invalid."""
        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={
                "title": "Test Task",
                "equipment_id": "not-a-uuid",
            },
            content_type="application/json",
        )

        assert response.status_code == 400

    def test_create_task_nonexistent_equipment(self, auth_client):
        """Verify error when equipment doesn't exist."""
        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={
                "title": "Test Task",
                "equipment_id": "00000000-0000-0000-0000-000000000000",
            },
            content_type="application/json",
        )

        assert response.status_code == 404

    def test_update_task_success(self, auth_client, sample_task_id):
        """Verify task update with valid data."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"status": "in_progress"},
            content_type="application/json",
        )

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["status"] == "in_progress"

    def test_update_task_invalid_status(self, auth_client, sample_task_id):
        """Verify error when status is invalid."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"status": "invalid_status"},
            content_type="application/json",
        )

        assert response.status_code == 400

    def test_update_task_not_found(self, auth_client):
        """Verify error when task doesn't exist."""
        response = auth_client.patch(
            "/api/tasks/00000000-0000-0000-0000-000000000000",
            json={"title": "Updated Title"},
            content_type="application/json",
        )

        assert response.status_code == 404

    def test_create_task_requires_auth(self, client):
        """Verify task creation requires authentication."""
        response = client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={"title": "Test Task"},
            content_type="application/json",
        )
        assert response.status_code == 401

    def test_update_task_requires_auth(self, client):
        """Verify task update requires authentication."""
        response = client.patch(
            "/api/tasks/00000000-0000-0000-0000-000000000000",
            json={"title": "Updated Title"},
            content_type="application/json",
        )
        assert response.status_code == 401


class TestCommentCRUD:
    """Test Comment CRUD operations (Create, Delete) - 課題2."""

    def test_create_comment_success(self, auth_client, sample_task_id):
        """Verify comment creation with valid data."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = auth_client.post(
            f"/api/tasks/{sample_task_id}/comments",
            json={
                "commented_by": "Test User",
                "comment": "This is a test comment",
            },
            content_type="application/json",
        )

        assert response.status_code == 201
        data = json.loads(response.data)
        assert data["commented_by"] == "Test User"
        assert data["comment"] == "This is a test comment"
        assert "created_at" in data

    def test_create_comment_missing_fields(self, auth_client, sample_task_id):
        """Verify error when required fields are missing."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = auth_client.post(
            f"/api/tasks/{sample_task_id}/comments",
            json={"comment": "Only comment, no author"},
            content_type="application/json",
        )

        assert response.status_code == 400

    def test_create_comment_task_not_found(self, auth_client):
        """Verify error when task doesn't exist."""
        response = auth_client.post(
            "/api/tasks/00000000-0000-0000-0000-000000000000/comments",
            json={
                "commented_by": "Test User",
                "comment": "Test comment",
            },
            content_type="application/json",
        )

        assert response.status_code == 404

    def test_delete_comment_not_found(self, auth_client):
        """Verify error when comment doesn't exist."""
        response = auth_client.delete("/api/comments/00000000-0000-0000-0000-000000000000")

        assert response.status_code == 404

    def test_create_comment_requires_auth(self, client, sample_task_id):
        """Verify comment creation requires authentication."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = client.post(
            f"/api/tasks/{sample_task_id}/comments",
            json={"commented_by": "User", "comment": "Test"},
            content_type="application/json",
        )
        assert response.status_code == 401

    def test_delete_comment_requires_auth(self, client):
        """Verify comment deletion requires authentication."""
        response = client.delete("/api/comments/00000000-0000-0000-0000-000000000000")
        assert response.status_code == 401


class TestInputValidation:
    """Test input validation and error handling."""

    def test_invalid_uuid_format(self, client):
        """Verify error for invalid UUID format."""
        response = client.get("/api/tenants/not-a-valid-uuid/equipments")

        assert response.status_code == 400
        data = json.loads(response.data)
        assert "error" in data
        assert data["error"] == "Invalid UUID format"

    def test_json_content_type_required(self, auth_client, sample_task_id):
        """Verify error when JSON content type is missing for POST."""
        if not sample_task_id:
            pytest.skip("No sample task available")

        response = auth_client.post(
            f"/api/tasks/{sample_task_id}/comments",
            data="not json",
        )

        assert response.status_code == 400


class TestPagination:
    """Test pagination functionality."""

    def test_pagination_defaults(self, client):
        """Verify default pagination values."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")
        data = json.loads(response.data)

        assert data["pagination"]["page"] == 1
        assert data["pagination"]["per_page"] == 20  # Default

    def test_pagination_custom_values(self, client):
        """Verify custom pagination values are respected."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?page=2&per_page=5")
        data = json.loads(response.data)

        assert data["pagination"]["page"] == 2
        assert data["pagination"]["per_page"] == 5

    def test_pagination_max_per_page(self, client):
        """Verify per_page is capped at maximum."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?per_page=1000")
        data = json.loads(response.data)

        assert data["pagination"]["per_page"] <= 100  # Max limit


class TestIndexPage:
    """Test index page rendering."""

    def test_index_returns_html(self, client):
        """Verify index page returns HTML."""
        response = client.get("/")

        assert response.status_code == 200
        assert b"<!DOCTYPE html>" in response.data
        assert b"M2X" in response.data


class TestHealthCheck:
    """Test health check endpoint."""

    def test_health_check_returns_healthy(self, client):
        """Verify health check returns healthy status."""
        response = client.get("/health")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["status"] == "healthy"
        assert data["database"] == "connected"
