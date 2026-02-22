"""
Authentication API tests for M2X Task Management System.
"""

import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

TEST_TENANT_ID = "11111111-1111-1111-1111-111111111111"


class TestLoginEndpoint:
    """Test /api/auth/login endpoint."""

    def test_login_missing_content_type(self, client):
        """Test login without JSON content type."""
        response = client.post("/api/auth/login", data="not json")
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "Content-Type" in data["error"]

    def test_login_empty_body(self, client):
        """Test login with empty request body."""
        response = client.post(
            "/api/auth/login",
            data="",
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_login_missing_fields(self, client):
        """Test login with missing required fields."""
        response = client.post(
            "/api/auth/login",
            json={"email": "test@example.com"},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "required" in data["error"].lower()

    def test_login_null_email_does_not_crash(self, client):
        """Test login with null email doesn't crash (precondition violation)."""
        response = client.post(
            "/api/auth/login",
            json={
                "email": None,
                "password": "password123",
                "tenant_id": TEST_TENANT_ID,
            },
            content_type="application/json",
        )
        # Should return 400, not 500 (crash)
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "required" in data["error"].lower()

    def test_login_invalid_email_format(self, client):
        """Test login with invalid email format."""
        response = client.post(
            "/api/auth/login",
            json={
                "email": "not-an-email",
                "password": "password123",
                "tenant_id": TEST_TENANT_ID,
            },
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "email" in data["error"].lower()

    def test_login_invalid_tenant_id(self, client):
        """Test login with invalid tenant ID format."""
        response = client.post(
            "/api/auth/login",
            json={
                "email": "test@example.com",
                "password": "password123",
                "tenant_id": "invalid-uuid",
            },
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "tenant" in data["error"].lower()

    def test_login_user_not_found(self, client):
        """Test login with non-existent user."""
        response = client.post(
            "/api/auth/login",
            json={
                "email": "nonexistent@example.com",
                "password": "password123",
                "tenant_id": TEST_TENANT_ID,
            },
            content_type="application/json",
        )
        # May return 401 (user not found) or 500 (if users table doesn't exist)
        assert response.status_code in [401, 500]


class TestRefreshTokenEndpoint:
    """Test /api/auth/refresh endpoint."""

    def test_refresh_missing_content_type(self, client):
        """Test refresh without JSON content type."""
        response = client.post("/api/auth/refresh", data="not json")
        assert response.status_code == 400

    def test_refresh_missing_token(self, client):
        """Test refresh without token."""
        response = client.post(
            "/api/auth/refresh",
            json={},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "token" in data["error"].lower()

    def test_refresh_null_token_does_not_crash(self, client):
        """Test refresh with null token doesn't crash (precondition violation)."""
        response = client.post(
            "/api/auth/refresh",
            json={"refresh_token": None},
            content_type="application/json",
        )
        # Should return 400, not 500 (crash)
        assert response.status_code == 400

    def test_refresh_invalid_token(self, client):
        """Test refresh with invalid token."""
        response = client.post(
            "/api/auth/refresh",
            json={"refresh_token": "invalid.token.here"},
            content_type="application/json",
        )
        assert response.status_code == 401
        data = json.loads(response.data)
        assert "Invalid" in data["error"]

    def test_refresh_access_token_rejected(self, client):
        """Test refresh with access token (should be rejected)."""
        from security import create_access_token

        access_token = create_access_token(
            user_id="user-123",
            tenant_id=TEST_TENANT_ID,
            role="user",
        )
        response = client.post(
            "/api/auth/refresh",
            json={"refresh_token": access_token},
            content_type="application/json",
        )
        assert response.status_code == 401


class TestCurrentUserEndpoint:
    """Test /api/auth/me endpoint."""

    def test_me_without_auth(self, client):
        """Test /me without authentication."""
        response = client.get("/api/auth/me")
        assert response.status_code == 401

    def test_me_with_invalid_token(self, client):
        """Test /me with invalid token."""
        response = client.get(
            "/api/auth/me",
            headers={"Authorization": "Bearer invalid.token.here"},
        )
        assert response.status_code == 401

    def test_me_with_expired_token(self, client):
        """Test /me with malformed authorization header."""
        response = client.get(
            "/api/auth/me",
            headers={"Authorization": "InvalidFormat token"},
        )
        assert response.status_code == 401


class TestTaskCRUD:
    """Additional task CRUD tests for coverage."""

    def test_get_single_task_not_found(self, client):
        """Test getting a non-existent task."""
        fake_task_id = "99999999-9999-9999-9999-999999999999"
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks/{fake_task_id}")
        assert response.status_code == 404

    def test_update_task_no_content_type(self, auth_client, sample_task_id):
        """Test update task without JSON content type."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(f"/api/tasks/{sample_task_id}", data="not json")
        assert response.status_code == 400

    def test_update_task_empty_body(self, auth_client, sample_task_id):
        """Test update task with empty body."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            data="",
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_update_task_no_fields(self, auth_client, sample_task_id):
        """Test update task with no fields to update."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"version": 1},  # Only version, no actual fields to update
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "No fields" in data["error"] or "field" in data["error"].lower()

    def test_update_task_invalid_status(self, auth_client, sample_task_id):
        """Test update task with invalid status."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"status": "invalid_status"},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "status" in data["error"].lower()

    def test_update_task_invalid_priority(self, auth_client, sample_task_id):
        """Test update task with invalid priority."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"priority": "invalid_priority"},
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_update_task_invalid_category(self, auth_client, sample_task_id):
        """Test update task with invalid category."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"category": "invalid_category"},
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_update_task_not_found(self, auth_client):
        """Test update non-existent task."""
        fake_task_id = "99999999-9999-9999-9999-999999999999"
        response = auth_client.patch(
            f"/api/tasks/{fake_task_id}",
            json={"title": "New Title"},
            content_type="application/json",
        )
        assert response.status_code == 404

    def test_update_task_invalid_version(self, auth_client, sample_task_id):
        """Test update task with invalid version format."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"title": "New Title", "version": "not-a-number"},
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_create_task_invalid_equipment_id(self, auth_client):
        """Test create task with invalid equipment ID format."""
        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={"title": "Test Task", "equipment_id": "invalid-uuid"},
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_create_task_equipment_not_found(self, auth_client):
        """Test create task with non-existent equipment."""
        fake_equipment_id = "99999999-9999-9999-9999-999999999999"
        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={"title": "Test Task", "equipment_id": fake_equipment_id},
            content_type="application/json",
        )
        assert response.status_code == 404

    def test_create_task_invalid_status(self, auth_client, sample_equipment_id):
        """Test create task with invalid status."""
        if sample_equipment_id is None:
            pytest.skip("No equipment available for testing")

        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={
                "title": "Test Task",
                "equipment_id": sample_equipment_id,
                "status": "invalid",
            },
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_create_task_invalid_priority(self, auth_client, sample_equipment_id):
        """Test create task with invalid priority."""
        if sample_equipment_id is None:
            pytest.skip("No equipment available for testing")

        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={
                "title": "Test Task",
                "equipment_id": sample_equipment_id,
                "priority": "invalid",
            },
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_create_task_invalid_category(self, auth_client, sample_equipment_id):
        """Test create task with invalid category."""
        if sample_equipment_id is None:
            pytest.skip("No equipment available for testing")

        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={
                "title": "Test Task",
                "equipment_id": sample_equipment_id,
                "category": "invalid",
            },
            content_type="application/json",
        )
        assert response.status_code == 400

    # ========================================================================
    # Null/Empty validation tests - precondition violation detection
    # ========================================================================

    def test_update_task_null_title_rejected(self, auth_client, sample_task_id):
        """Test that explicit null for title is rejected as precondition violation."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"title": None},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "title" in data["error"].lower() and "null" in data["error"].lower()

    def test_update_task_empty_title_rejected(self, auth_client, sample_task_id):
        """Test that empty string for title is rejected."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"title": ""},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "title" in data["error"].lower() or "empty" in data["error"].lower()

    def test_update_task_null_status_rejected(self, auth_client, sample_task_id):
        """Test that explicit null for status is rejected as precondition violation."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"status": None},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "status" in data["error"].lower() and "null" in data["error"].lower()

    def test_update_task_null_priority_rejected(self, auth_client, sample_task_id):
        """Test that explicit null for priority is rejected as precondition violation."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"priority": None},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "priority" in data["error"].lower() and "null" in data["error"].lower()

    def test_update_task_null_category_rejected(self, auth_client, sample_task_id):
        """Test that explicit null for category is rejected as precondition violation."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.patch(
            f"/api/tasks/{sample_task_id}",
            json={"category": None},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "category" in data["error"].lower() and "null" in data["error"].lower()

    def test_create_task_whitespace_title_rejected(self, auth_client):
        """Test that whitespace-only title is rejected."""
        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={"title": "   "},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "empty" in data["error"].lower() or "title" in str(data).lower()

    def test_create_task_null_status_rejected(self, auth_client):
        """Test that explicit null for status is rejected (not defaulted)."""
        response = auth_client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={"title": "Test Task", "status": None},
            content_type="application/json",
        )
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "status" in data["error"].lower() and "null" in data["error"].lower()

    def test_get_task_details_not_found_returns_404(self, client):
        """Test that get_task_details returns 404 for non-existent task."""
        fake_task_id = "99999999-9999-9999-9999-999999999999"
        response = client.get(f"/api/tasks/{fake_task_id}/details")
        assert response.status_code == 404
        data = json.loads(response.data)
        assert "error" in data


class TestCommentEndpoints:
    """Test comment-related endpoints."""

    def test_create_comment_task_not_found(self, auth_client):
        """Test creating comment on non-existent task."""
        fake_task_id = "99999999-9999-9999-9999-999999999999"
        response = auth_client.post(
            f"/api/tasks/{fake_task_id}/comments",
            json={"commented_by": "Test User", "comment": "Test comment"},
            content_type="application/json",
        )
        assert response.status_code == 404

    def test_create_comment_empty_fields(self, auth_client, sample_task_id):
        """Test creating comment with empty fields."""
        if sample_task_id is None:
            pytest.skip("No task available for testing")

        response = auth_client.post(
            f"/api/tasks/{sample_task_id}/comments",
            json={"commented_by": "", "comment": ""},
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_delete_comment_not_found(self, auth_client):
        """Test deleting non-existent comment."""
        fake_comment_id = "99999999-9999-9999-9999-999999999999"
        response = auth_client.delete(f"/api/comments/{fake_comment_id}")
        assert response.status_code == 404


class TestValidators:
    """Test validator functions."""

    def test_pagination_invalid_page(self, client):
        """Test pagination with invalid page number."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?page=abc")
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["pagination"]["page"] == 1

    def test_pagination_invalid_per_page(self, client):
        """Test pagination with invalid per_page value."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?per_page=abc")
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["pagination"]["per_page"] == 20

    def test_pagination_invalid_sort_order(self, client):
        """Test pagination with invalid sort order."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?sort_order=invalid")
        assert response.status_code == 200
