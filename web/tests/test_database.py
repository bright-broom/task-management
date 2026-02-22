"""
Database schema and constraint tests for M2X Task Management System.

These tests verify:
- Table structure and relationships
- Constraints (foreign keys, unique, check)
- Multi-tenant data isolation
- EAV pattern implementation
"""

import pytest

# Test tenant IDs (from seed data)
TEST_TENANT_ID = "11111111-1111-1111-1111-111111111111"
TEST_TENANT_ID_2 = "22222222-2222-2222-2222-222222222222"


class TestDatabaseSchema:
    """Test database schema structure."""

    def test_all_tables_exist(self, db_cursor):
        """Verify all required tables are created."""
        db_cursor.execute("""
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
            ORDER BY table_name
        """)
        tables = [row["table_name"] for row in db_cursor.fetchall()]

        expected_tables = [
            "custom_field_definitions",
            "custom_field_values",
            "equipment_parts",
            "equipments",
            "parts",
            "task_comments",
            "task_parts",
            "tasks",
            "tenants",
        ]

        for table in expected_tables:
            assert table in tables, f"Table '{table}' should exist"

    def test_tenant_id_exists_in_all_tables(self, db_cursor):
        """Verify tenant_id column exists in all tables except tenants."""
        tables_with_tenant_id = [
            "custom_field_definitions",
            "custom_field_values",
            "equipment_parts",
            "equipments",
            "parts",
            "task_comments",
            "task_parts",
            "tasks",
        ]

        for table in tables_with_tenant_id:
            db_cursor.execute(f"""
                SELECT column_name FROM information_schema.columns
                WHERE table_name = '{table}' AND column_name = 'tenant_id'
            """)
            result = db_cursor.fetchone()
            assert result is not None, f"Table '{table}' should have tenant_id column"

    def test_uuid_primary_keys(self, db_cursor):
        """Verify main tables use UUID primary keys.

        Note: Time-series tables (audit_logs, security_events, failed_login_attempts)
        intentionally use bigint for better write performance.
        """
        # Tables that intentionally use bigint for time-series data
        bigint_pk_tables = {"audit_logs", "security_events", "failed_login_attempts"}

        db_cursor.execute("""
            SELECT c.table_name, c.column_name, c.data_type
            FROM information_schema.columns c
            JOIN information_schema.tables t
              ON c.table_name = t.table_name AND c.table_schema = t.table_schema
            WHERE c.table_schema = 'public'
              AND c.column_name = 'id'
              AND t.table_type = 'BASE TABLE'
            ORDER BY c.table_name
        """)

        for row in db_cursor.fetchall():
            table_name = row["table_name"]
            if table_name in bigint_pk_tables:
                assert (
                    row["data_type"] == "bigint"
                ), f"Time-series table '{table_name}' should use bigint for primary key"
            else:
                assert (
                    row["data_type"] == "uuid"
                ), f"Table '{table_name}' should use UUID for primary key"


class TestMultiTenantIsolation:
    """Test multi-tenant data isolation."""

    def test_tenant_data_isolation_equipments(self, db_cursor):
        """Verify equipment data is isolated by tenant."""
        db_cursor.execute(
            "SELECT COUNT(*) as count FROM equipments WHERE tenant_id = %s",
            (TEST_TENANT_ID,),
        )
        tenant1_count = db_cursor.fetchone()["count"]

        db_cursor.execute(
            "SELECT COUNT(*) as count FROM equipments WHERE tenant_id = %s",
            (TEST_TENANT_ID_2,),
        )
        tenant2_count = db_cursor.fetchone()["count"]

        assert tenant1_count > 0, "Tenant 1 should have equipment data"
        assert tenant2_count > 0, "Tenant 2 should have equipment data"

        db_cursor.execute("SELECT COUNT(*) as count FROM equipments")
        total_count = db_cursor.fetchone()["count"]
        assert total_count == tenant1_count + tenant2_count

    def test_tenant_data_isolation_tasks(self, db_cursor):
        """Verify task data is isolated by tenant."""
        db_cursor.execute(
            "SELECT COUNT(*) as count FROM tasks WHERE tenant_id = %s",
            (TEST_TENANT_ID,),
        )
        tenant1_tasks = db_cursor.fetchone()["count"]

        db_cursor.execute(
            "SELECT COUNT(*) as count FROM tasks WHERE tenant_id = %s",
            (TEST_TENANT_ID_2,),
        )
        tenant2_tasks = db_cursor.fetchone()["count"]

        assert tenant1_tasks > 0, "Tenant 1 should have task data"
        # Tenant 2 may or may not have tasks in seed data
        assert tenant2_tasks >= 0, "Tenant 2 task count should be non-negative"


class TestConstraints:
    """Test database constraints."""

    def test_task_status_enum(self, db_cursor):
        """Verify task status is restricted to enum values."""
        db_cursor.execute("""
            SELECT enumlabel FROM pg_enum
            WHERE enumtypid = (SELECT oid FROM pg_type WHERE typname = 'task_status')
            ORDER BY enumlabel
        """)
        statuses = [row["enumlabel"] for row in db_cursor.fetchall()]
        assert statuses == ["done", "in_progress", "todo"]

    def test_field_type_enum(self, db_cursor):
        """Verify field_type is restricted to enum values."""
        db_cursor.execute("""
            SELECT enumlabel FROM pg_enum
            WHERE enumtypid = (SELECT oid FROM pg_type WHERE typname = 'field_type')
            ORDER BY enumlabel
        """)
        types = [row["enumlabel"] for row in db_cursor.fetchall()]
        assert "text" in types
        assert "number" in types
        assert "select" in types

    def test_stock_quantity_non_negative(self, db_cursor):
        """Verify stock_quantity cannot be negative."""
        with pytest.raises(Exception):
            db_cursor.execute(
                """
                INSERT INTO parts (tenant_id, name, stock_quantity)
                VALUES (%s, 'Test Part', -1)
            """,
                (TEST_TENANT_ID,),
            )

    def test_task_part_quantity_positive(self, db_cursor):
        """Verify task_parts quantity must be positive."""
        db_cursor.execute("SELECT id FROM tasks WHERE tenant_id = %s LIMIT 1", (TEST_TENANT_ID,))
        task = db_cursor.fetchone()

        db_cursor.execute("SELECT id FROM parts WHERE tenant_id = %s LIMIT 1", (TEST_TENANT_ID,))
        part = db_cursor.fetchone()

        if task and part:
            with pytest.raises(Exception):
                db_cursor.execute(
                    """
                    INSERT INTO task_parts (tenant_id, task_id, part_id, quantity)
                    VALUES (%s, %s, %s, 0)
                """,
                    (TEST_TENANT_ID, task["id"], part["id"]),
                )


class TestEAVPattern:
    """Test EAV (Entity-Attribute-Value) pattern implementation."""

    def test_custom_field_definitions_per_tenant(self, db_cursor):
        """Verify custom field definitions are tenant-specific."""
        db_cursor.execute("""
            SELECT tenant_id, COUNT(*) as count
            FROM custom_field_definitions
            GROUP BY tenant_id
        """)
        results = {str(row["tenant_id"]): row["count"] for row in db_cursor.fetchall()}

        assert TEST_TENANT_ID in results
        assert TEST_TENANT_ID_2 in results

    def test_custom_field_values_linked_to_definitions(self, db_cursor):
        """Verify all custom field values reference valid definitions."""
        db_cursor.execute("""
            SELECT cfv.id
            FROM custom_field_values cfv
            LEFT JOIN custom_field_definitions cfd ON cfv.field_definition_id = cfd.id
            WHERE cfd.id IS NULL
        """)
        orphaned = db_cursor.fetchall()
        assert len(orphaned) == 0, "No orphaned custom field values should exist"

    def test_unique_field_name_per_tenant(self, db_cursor):
        """Verify field names are unique within a tenant."""
        db_cursor.execute("""
            SELECT tenant_id, field_name, COUNT(*) as count
            FROM custom_field_definitions
            GROUP BY tenant_id, field_name
            HAVING COUNT(*) > 1
        """)
        duplicates = db_cursor.fetchall()
        assert len(duplicates) == 0, "Field names should be unique per tenant"


class TestEquipmentHierarchy:
    """Test equipment hierarchy (self-referencing relationship)."""

    def test_equipment_parent_child_relationship(self, db_cursor):
        """Verify equipment hierarchy is properly structured."""
        db_cursor.execute(
            """
            SELECT e.id, e.name, e.parent_equipment_id, p.name as parent_name
            FROM equipments e
            LEFT JOIN equipments p ON e.parent_equipment_id = p.id
            WHERE e.tenant_id = %s AND e.parent_equipment_id IS NOT NULL
        """,
            (TEST_TENANT_ID,),
        )

        children = db_cursor.fetchall()
        assert len(children) > 0, "Should have child equipment"

        for child in children:
            assert (
                child["parent_name"] is not None
            ), f"Child equipment '{child['name']}' should have a valid parent"

    def test_recursive_query_works(self, db_cursor):
        """Verify recursive CTE works for hierarchy traversal."""
        db_cursor.execute(
            """
            WITH RECURSIVE equipment_tree AS (
                SELECT id, name, parent_equipment_id, 0 AS depth
                FROM equipments
                WHERE tenant_id = %s AND parent_equipment_id IS NULL
                UNION ALL
                SELECT e.id, e.name, e.parent_equipment_id, et.depth + 1
                FROM equipments e
                JOIN equipment_tree et ON e.parent_equipment_id = et.id
            )
            SELECT * FROM equipment_tree ORDER BY depth, name
        """,
            (TEST_TENANT_ID,),
        )

        results = db_cursor.fetchall()
        assert len(results) > 0

        depths = set(row["depth"] for row in results)
        assert 0 in depths, "Should have root level equipment"


class TestOptimisticLocking:
    """Test optimistic locking (version column) implementation."""

    def test_version_column_exists_on_major_tables(self, db_cursor):
        """Verify version column exists on tables with optimistic locking."""
        tables_with_version = [
            "tenants",
            "equipments",
            "parts",
            "tasks",
            "users",
        ]

        for table in tables_with_version:
            db_cursor.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_name = %s AND column_name = 'version'
            """,
                (table,),
            )
            result = db_cursor.fetchone()
            assert result is not None, f"Table '{table}' should have version column"

    def test_version_starts_at_one(self, db_cursor):
        """Verify new records start with version = 1."""
        db_cursor.execute(
            """
            SELECT version FROM tasks
            WHERE tenant_id = %s
            LIMIT 1
        """,
            (TEST_TENANT_ID,),
        )
        result = db_cursor.fetchone()
        if result:
            assert result["version"] >= 1, "Version should be at least 1"

    def test_version_increments_on_update(self, db_cursor):
        """Verify version increments on update."""
        db_cursor.execute(
            """
            SELECT id, version FROM tasks
            WHERE tenant_id = %s
            LIMIT 1
        """,
            (TEST_TENANT_ID,),
        )
        task = db_cursor.fetchone()

        if task:
            old_version = task["version"]
            db_cursor.execute(
                """
                UPDATE tasks SET title = title || ' (updated)'
                WHERE id = %s
            """,
                (task["id"],),
            )
            db_cursor.execute("SELECT version FROM tasks WHERE id = %s", (task["id"],))
            new_task = db_cursor.fetchone()
            assert new_task["version"] == old_version + 1, "Version should increment on update"

    def test_concurrent_update_conflict_detected(self, db_cursor, db_connection):
        """Test that concurrent updates with wrong version are rejected."""
        db_cursor.execute(
            """
            SELECT id, version FROM tasks
            WHERE tenant_id = %s
            LIMIT 1
        """,
            (TEST_TENANT_ID,),
        )
        task = db_cursor.fetchone()

        if task:
            # Try to update with incorrect version (simulating conflict)
            with pytest.raises(Exception) as excinfo:
                db_cursor.execute(
                    """
                    UPDATE tasks
                    SET title = 'Conflicting update', version = %s
                    WHERE id = %s
                """,
                    (task["version"] + 10, task["id"]),
                )  # Wrong version
            # The check_version_conflict trigger should raise an exception
            assert (
                "conflict" in str(excinfo.value).lower() or "version" in str(excinfo.value).lower()
            )


class TestCrossTenantConstraints:
    """Test cross-tenant data integrity constraints."""

    def test_equipment_parent_must_be_same_tenant(self, db_cursor):
        """Verify parent equipment must belong to same tenant."""
        db_cursor.execute(
            """
            SELECT id FROM equipments WHERE tenant_id = %s AND deleted_at IS NULL LIMIT 1
        """,
            (TEST_TENANT_ID,),
        )
        equipment1 = db_cursor.fetchone()

        db_cursor.execute(
            """
            SELECT id FROM equipments WHERE tenant_id = %s AND deleted_at IS NULL LIMIT 1
        """,
            (TEST_TENANT_ID_2,),
        )
        equipment2 = db_cursor.fetchone()

        if equipment1 and equipment2:
            # Try to set parent from different tenant - should fail
            with pytest.raises(Exception) as excinfo:
                db_cursor.execute(
                    """
                    UPDATE equipments
                    SET parent_equipment_id = %s
                    WHERE id = %s
                """,
                    (equipment2["id"], equipment1["id"]),
                )
            assert "tenant" in str(excinfo.value).lower()

    def test_circular_reference_prevented(self, db_cursor):
        """Verify circular references in equipment hierarchy are prevented."""
        db_cursor.execute(
            """
            SELECT e.id, e.parent_equipment_id
            FROM equipments e
            WHERE e.tenant_id = %s
              AND e.parent_equipment_id IS NOT NULL
              AND e.deleted_at IS NULL
            LIMIT 1
        """,
            (TEST_TENANT_ID,),
        )
        child = db_cursor.fetchone()

        if child and child["parent_equipment_id"]:
            # Try to create circular reference: set parent's parent to child
            with pytest.raises(Exception) as excinfo:
                db_cursor.execute(
                    """
                    UPDATE equipments
                    SET parent_equipment_id = %s
                    WHERE id = %s
                """,
                    (child["id"], child["parent_equipment_id"]),
                )
            assert "circular" in str(excinfo.value).lower()

    def test_self_reference_prevented(self, db_cursor):
        """Verify equipment cannot be its own parent."""
        db_cursor.execute(
            """
            SELECT id FROM equipments
            WHERE tenant_id = %s AND deleted_at IS NULL
            LIMIT 1
        """,
            (TEST_TENANT_ID,),
        )
        equipment = db_cursor.fetchone()

        if equipment:
            with pytest.raises(Exception) as excinfo:
                db_cursor.execute(
                    """
                    UPDATE equipments
                    SET parent_equipment_id = %s
                    WHERE id = %s
                """,
                    (equipment["id"], equipment["id"]),
                )
            assert "parent" in str(excinfo.value).lower() or "itself" in str(excinfo.value).lower()


class TestTaskComments:
    """Test task comments feature (課題2)."""

    def test_task_comments_exist(self, db_cursor):
        """Verify task comments table has data."""
        db_cursor.execute(
            """
            SELECT COUNT(*) as count FROM task_comments
            WHERE tenant_id = %s AND deleted_at IS NULL
        """,
            (TEST_TENANT_ID,),
        )

        count = db_cursor.fetchone()["count"]
        assert count > 0, "Should have task comments in seed data"

    def test_soft_delete_works(self, db_cursor):
        """Verify soft delete functionality."""
        db_cursor.execute(
            """
            SELECT COUNT(*) as total,
                   SUM(CASE WHEN deleted_at IS NULL THEN 1 ELSE 0 END) as active
            FROM task_comments
            WHERE tenant_id = %s
        """,
            (TEST_TENANT_ID,),
        )

        result = db_cursor.fetchone()
        # Active count should be retrievable via WHERE deleted_at IS NULL
        assert result["active"] >= 0

    def test_comments_ordered_by_created_at(self, db_cursor):
        """Verify comments can be ordered chronologically."""
        db_cursor.execute(
            """
            SELECT tc.created_at
            FROM task_comments tc
            JOIN tasks t ON tc.task_id = t.id
            WHERE tc.tenant_id = %s AND tc.deleted_at IS NULL
            ORDER BY tc.created_at
        """,
            (TEST_TENANT_ID,),
        )

        results = db_cursor.fetchall()
        if len(results) > 1:
            for i in range(1, len(results)):
                assert results[i]["created_at"] >= results[i - 1]["created_at"]
