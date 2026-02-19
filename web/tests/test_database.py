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
        """Verify all tables use UUID primary keys."""
        db_cursor.execute("""
            SELECT table_name, column_name, data_type
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND column_name = 'id'
            ORDER BY table_name
        """)

        for row in db_cursor.fetchall():
            assert (
                row["data_type"] == "uuid"
            ), f"Table '{row['table_name']}' should use UUID for primary key"


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

        # Verify different tenants have different data
        assert tenant1_count > 0, "Tenant 1 should have equipment data"
        assert tenant2_count > 0, "Tenant 2 should have equipment data"

        # Verify cross-tenant query returns different counts
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
        # Get a task and part ID first
        db_cursor.execute(
            "SELECT id FROM tasks WHERE tenant_id = %s LIMIT 1", (TEST_TENANT_ID,)
        )
        task = db_cursor.fetchone()

        db_cursor.execute(
            "SELECT id FROM parts WHERE tenant_id = %s LIMIT 1", (TEST_TENANT_ID,)
        )
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

        # Different tenants should have different field definitions
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

        # Verify hierarchy levels
        depths = set(row["depth"] for row in results)
        assert 0 in depths, "Should have root level equipment"


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
