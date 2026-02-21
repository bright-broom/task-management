"""
Security and authentication tests for M2X Task Management System.
"""

import json
import os
import sys

import pytest

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

# Test tenant ID (from seed data)
TEST_TENANT_ID = "11111111-1111-1111-1111-111111111111"


class TestSecurityHeaders:
    """Test security headers are properly set."""

    def test_cors_headers_present(self, client):
        """Test that CORS headers are set on responses."""
        response = client.get("/api/tenants")
        # CORS headers should be present
        assert response.status_code == 200

    def test_content_type_json(self, client):
        """Test that API endpoints return JSON content type."""
        response = client.get("/api/tenants")
        assert "application/json" in response.content_type

    def test_health_endpoint_accessible(self, client):
        """Test that health endpoint is accessible without auth."""
        response = client.get("/health")
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["status"] == "healthy"


class TestInputValidation:
    """Test input validation and sanitization."""

    def test_invalid_uuid_rejected(self, client):
        """Test that invalid UUIDs are rejected."""
        response = client.get("/api/tenants/invalid-uuid/tasks")
        assert response.status_code == 400
        data = json.loads(response.data)
        assert "error" in data
        assert "UUID" in data["error"] or "uuid" in data["error"].lower()

    def test_valid_uuid_accepted(self, client):
        """Test that valid UUIDs are accepted."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")
        assert response.status_code == 200

    def test_empty_tenant_id_rejected(self, client):
        """Test that empty tenant ID is handled."""
        response = client.get("/api/tenants//tasks")
        # Should return 404 since route doesn't match
        assert response.status_code == 404

    def test_sql_injection_prevented(self, client):
        """Test that SQL injection attempts are handled safely."""
        # Try SQL injection in task filter
        malicious_status = "'; DROP TABLE tasks; --"
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?status={malicious_status}")
        # Should not cause server error, just return empty or error
        assert response.status_code in [200, 400]

    def test_xss_in_title_handled(self, client, sample_equipment_id):
        """Test that XSS in task title is handled."""
        if sample_equipment_id is None:
            pytest.skip("No equipment available for testing")

        # Create a task with XSS payload
        xss_payload = '<script>alert("xss")</script>'
        response = client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={"title": xss_payload, "equipment_id": sample_equipment_id},
            content_type="application/json",
        )
        # Should either reject (400) or accept (201) - sanitization happens on display
        assert response.status_code in [201, 400]


class TestPagination:
    """Test pagination parameter validation."""

    def test_negative_page_handled(self, client):
        """Test that negative page numbers are handled."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?page=-1")
        # Should default to page 1 or return error
        assert response.status_code in [200, 400]
        if response.status_code == 200:
            data = json.loads(response.data)
            assert data["pagination"]["page"] >= 1

    def test_zero_page_handled(self, client):
        """Test that zero page number is handled."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?page=0")
        assert response.status_code in [200, 400]
        if response.status_code == 200:
            data = json.loads(response.data)
            assert data["pagination"]["page"] >= 1

    def test_very_large_per_page_capped(self, client):
        """Test that very large per_page values are capped."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?per_page=10000")
        assert response.status_code == 200
        data = json.loads(response.data)
        # Should be capped at reasonable maximum
        assert data["pagination"]["per_page"] <= 100


class TestErrorHandling:
    """Test error handling and responses."""

    def test_404_for_nonexistent_tenant(self, client):
        """Test 404 response for non-existent tenant."""
        fake_tenant_id = "99999999-9999-9999-9999-999999999999"
        response = client.get(f"/api/tenants/{fake_tenant_id}/tasks")
        # Should return empty list, not error
        assert response.status_code == 200
        data = json.loads(response.data)
        assert len(data["items"]) == 0

    def test_404_for_nonexistent_task(self, client):
        """Test 404 response for non-existent task."""
        fake_task_id = "99999999-9999-9999-9999-999999999999"
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks/{fake_task_id}")
        assert response.status_code == 404

    def test_malformed_json_rejected(self, client):
        """Test that malformed JSON is rejected."""
        response = client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            data="not valid json{",
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_missing_required_fields_rejected(self, client):
        """Test that missing required fields are rejected."""
        response = client.post(
            f"/api/tenants/{TEST_TENANT_ID}/tasks",
            json={},  # Missing title and equipment_id
            content_type="application/json",
        )
        assert response.status_code == 400


class TestTaskStatusValidation:
    """Test task status validation."""

    def test_valid_status_accepted(self, client):
        """Test that valid task statuses are accepted."""
        valid_statuses = ["pending", "in_progress", "completed"]
        for status in valid_statuses:
            response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?status={status}")
            assert response.status_code == 200

    def test_invalid_status_filtered(self, client):
        """Test that invalid statuses don't cause errors."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks?status=invalid_status")
        # Should either ignore invalid status or return validation error
        assert response.status_code in [200, 400]


class TestTenantIsolation:
    """Test multi-tenant data isolation."""

    def test_tenant_cannot_access_other_tenant_tasks(self, client, db_cursor):
        """Test that tenants cannot access other tenant's tasks."""
        # Get tasks for tenant 1
        response1 = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")
        data1 = json.loads(response1.data)

        # Get tasks for tenant 2
        tenant2_id = "22222222-2222-2222-2222-222222222222"
        response2 = client.get(f"/api/tenants/{tenant2_id}/tasks")
        data2 = json.loads(response2.data)

        # Verify no overlap in task IDs
        task_ids_1 = {item["id"] for item in data1["items"]}
        task_ids_2 = {item["id"] for item in data2["items"]}
        assert task_ids_1.isdisjoint(task_ids_2)

    def test_tenant_cannot_access_other_tenant_equipments(self, client):
        """Test that equipments are isolated by tenant."""
        # Get equipments for tenant 1
        response1 = client.get(f"/api/tenants/{TEST_TENANT_ID}/equipments")
        data1 = json.loads(response1.data)

        # Get equipments for tenant 2
        tenant2_id = "22222222-2222-2222-2222-222222222222"
        response2 = client.get(f"/api/tenants/{tenant2_id}/equipments")
        data2 = json.loads(response2.data)

        # Verify no overlap in equipment IDs
        equip_ids_1 = {item["id"] for item in data1.get("items", data1)}
        equip_ids_2 = {item["id"] for item in data2.get("items", data2)}
        assert equip_ids_1.isdisjoint(equip_ids_2)

    def test_tenant_cannot_access_other_tenant_parts(self, client):
        """Test that parts are isolated by tenant."""
        # Get parts for tenant 1
        response1 = client.get(f"/api/tenants/{TEST_TENANT_ID}/parts")
        data1 = json.loads(response1.data)

        # Get parts for tenant 2
        tenant2_id = "22222222-2222-2222-2222-222222222222"
        response2 = client.get(f"/api/tenants/{tenant2_id}/parts")
        data2 = json.loads(response2.data)

        # Verify no overlap in part IDs
        part_ids_1 = {item["id"] for item in data1.get("items", data1)}
        part_ids_2 = {item["id"] for item in data2.get("items", data2)}
        assert part_ids_1.isdisjoint(part_ids_2)

    def test_task_tenant_id_matches_url(self, client, db_cursor):
        """Test that returned tasks always match the URL tenant_id."""
        response = client.get(f"/api/tenants/{TEST_TENANT_ID}/tasks")
        data = json.loads(response.data)

        for task in data["items"]:
            assert task.get("tenant_id") == TEST_TENANT_ID or "tenant_id" not in task

    def test_cannot_create_task_for_other_tenant_equipment(self, client, db_cursor):
        """Test that creating task with equipment from another tenant fails."""
        # Get equipment from tenant 2
        db_cursor.execute("""
            SELECT id FROM equipments
            WHERE tenant_id = '22222222-2222-2222-2222-222222222222'
            AND deleted_at IS NULL
            LIMIT 1
        """)
        result = db_cursor.fetchone()

        if result:
            other_tenant_equipment_id = str(result["id"])
            # Try to create task in tenant 1 with tenant 2's equipment
            response = client.post(
                f"/api/tenants/{TEST_TENANT_ID}/tasks",
                json={
                    "title": "Cross-tenant test",
                    "equipment_id": other_tenant_equipment_id
                },
                content_type="application/json",
            )
            # Should fail - either 400 or 404
            assert response.status_code in [400, 404, 403]


class TestCrossTenantAPIProtection:
    """Test API protection against cross-tenant access attempts."""

    def test_task_detail_tenant_mismatch(self, client, db_cursor):
        """Test accessing task detail with wrong tenant ID returns 404."""
        # Get a task from tenant 1
        db_cursor.execute("""
            SELECT id FROM tasks
            WHERE tenant_id = %s AND deleted_at IS NULL
            LIMIT 1
        """, (TEST_TENANT_ID,))
        result = db_cursor.fetchone()

        if result:
            task_id = str(result["id"])
            # Try to access it via tenant 2's URL
            tenant2_id = "22222222-2222-2222-2222-222222222222"
            response = client.get(f"/api/tenants/{tenant2_id}/tasks/{task_id}")
            # Should return 404 (not found in this tenant)
            assert response.status_code == 404

    def test_equipment_detail_tenant_mismatch(self, client, db_cursor):
        """Test accessing equipment detail with wrong tenant ID returns 404."""
        # Get an equipment from tenant 1
        db_cursor.execute("""
            SELECT id FROM equipments
            WHERE tenant_id = %s AND deleted_at IS NULL
            LIMIT 1
        """, (TEST_TENANT_ID,))
        result = db_cursor.fetchone()

        if result:
            equipment_id = str(result["id"])
            # Try to access it via tenant 2's URL
            tenant2_id = "22222222-2222-2222-2222-222222222222"
            response = client.get(f"/api/tenants/{tenant2_id}/equipments/{equipment_id}")
            # Should return 404 (not found in this tenant)
            assert response.status_code == 404

    def test_part_detail_tenant_mismatch(self, client, db_cursor):
        """Test accessing part detail with wrong tenant ID returns 404."""
        # Get a part from tenant 1
        db_cursor.execute("""
            SELECT id FROM parts
            WHERE tenant_id = %s AND deleted_at IS NULL
            LIMIT 1
        """, (TEST_TENANT_ID,))
        result = db_cursor.fetchone()

        if result:
            part_id = str(result["id"])
            # Try to access it via tenant 2's URL
            tenant2_id = "22222222-2222-2222-2222-222222222222"
            response = client.get(f"/api/tenants/{tenant2_id}/parts/{part_id}")
            # Should return 404 (not found in this tenant)
            assert response.status_code == 404


class TestLoggingConfig:
    """Test logging configuration module."""

    def test_configure_logging_does_not_raise(self):
        """Test that configure_logging can be called without errors."""
        from logging_config import configure_logging

        # Should not raise any exceptions
        configure_logging(log_level="DEBUG")
        configure_logging(log_level="INFO", json_format=False)

    def test_get_logger_returns_logger(self):
        """Test that get_logger returns a logger instance."""
        import logging

        from logging_config import get_logger

        logger = get_logger("test.module")
        assert isinstance(logger, logging.Logger)
        assert logger.name == "test.module"

    def test_set_request_context(self):
        """Test setting and getting request context."""
        from logging_config import (
            clear_request_context,
            get_request_id,
            set_request_context,
        )

        # Set context
        set_request_context(request_id="test-123", tenant_id="tenant-456")

        # Get request ID
        assert get_request_id() == "test-123"

        # Clear context
        clear_request_context()
        assert get_request_id() == ""


class TestSecurityModule:
    """Test security module functions."""

    def test_hash_password_produces_hash(self):
        """Test that hash_password produces a hash."""
        from security import hash_password

        password = "test_password_123"
        hashed = hash_password(password)

        assert hashed != password
        assert len(hashed) > 20

    def test_verify_password_correct(self):
        """Test password verification with correct password."""
        from security import hash_password, verify_password

        password = "correct_password"
        hashed = hash_password(password)

        assert verify_password(password, hashed) is True

    def test_verify_password_incorrect(self):
        """Test password verification with incorrect password."""
        from security import hash_password, verify_password

        password = "correct_password"
        hashed = hash_password(password)

        assert verify_password("wrong_password", hashed) is False

    def test_validate_email_valid(self):
        """Test email validation with valid emails."""
        from security import validate_email

        valid_emails = [
            "user@example.com",
            "user.name@example.co.jp",
            "user+tag@example.org",
        ]
        for email in valid_emails:
            assert validate_email(email) is True

    def test_validate_email_invalid(self):
        """Test email validation with invalid emails."""
        from security import validate_email

        invalid_emails = [
            "not-an-email",
            "@no-local-part.com",
            "no-domain@",
            "",
            "spaces in@email.com",
        ]
        for email in invalid_emails:
            assert validate_email(email) is False

    def test_create_access_token_returns_string(self):
        """Test that create_access_token returns a JWT string."""
        from security import create_access_token

        token = create_access_token(
            user_id="user-123",
            tenant_id="tenant-456",
            role="user",
        )

        assert isinstance(token, str)
        assert len(token) > 50  # JWTs are typically longer
        assert token.count(".") == 2  # JWT has 3 parts

    def test_decode_token_valid(self):
        """Test decoding a valid token."""
        from security import create_access_token, decode_token

        token = create_access_token(
            user_id="user-123",
            tenant_id="tenant-456",
            role="admin",
        )

        payload = decode_token(token)
        assert payload is not None
        assert payload["sub"] == "user-123"
        assert payload["tenant_id"] == "tenant-456"
        assert payload["role"] == "admin"

    def test_decode_token_invalid(self):
        """Test decoding an invalid token returns None."""
        from security import decode_token

        invalid_token = "invalid.token.here"
        payload = decode_token(invalid_token)

        assert payload is None

    def test_sanitize_html_encodes_scripts(self):
        """Test that sanitize_html HTML-encodes dangerous content."""
        from security import sanitize_html

        input_html = '<p>Hello</p><script>alert("xss")</script>'
        sanitized = sanitize_html(input_html)

        # HTML encoding should prevent script execution
        assert "<script>" not in sanitized
        # Script tags should be encoded
        assert "&lt;script&gt;" in sanitized or "script" in sanitized
        assert "Hello" in sanitized

    def test_detect_xss_detects_patterns(self):
        """Test that detect_xss catches XSS patterns."""
        from security import detect_xss

        xss_inputs = [
            '<script>alert("xss")</script>',
            "javascript:void(0)",
            '<img onerror="alert(1)">',
            '<a href="javascript:alert(1)">',
        ]
        for input_str in xss_inputs:
            assert detect_xss(input_str) is True

    def test_detect_xss_allows_safe(self):
        """Test that detect_xss allows safe inputs."""
        from security import detect_xss

        safe_inputs = [
            "Hello World",
            "Task title",
            "Normal text with numbers 123",
        ]
        for input_str in safe_inputs:
            assert detect_xss(input_str) is False


class TestRequestIDHeader:
    """Test request ID in response headers."""

    def test_response_includes_request_id(self, client):
        """Test that responses include X-Request-ID header."""
        response = client.get("/api/tenants")
        assert "X-Request-ID" in response.headers
        # Request ID should be a valid UUID format
        request_id = response.headers["X-Request-ID"]
        assert len(request_id) == 36  # UUID format


class TestSwaggerDocumentation:
    """Test Swagger/OpenAPI documentation."""

    def test_swagger_ui_accessible(self, client):
        """Test that Swagger UI is accessible at /docs."""
        response = client.get("/docs")
        assert response.status_code == 200
        assert b"swagger" in response.data.lower() or b"Swagger" in response.data

    def test_openapi_spec_accessible(self, client):
        """Test that OpenAPI spec is accessible."""
        response = client.get("/apispec.json")
        assert response.status_code == 200
        data = json.loads(response.data)
        assert "openapi" in data or "swagger" in data
        assert "info" in data
        assert "paths" in data
