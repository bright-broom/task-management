"""
pytest fixtures for M2X Task Management System tests.
"""
import os
import pytest
import psycopg2
from psycopg2.extras import RealDictCursor

# Test database URL (uses the same DB but could be configured separately)
TEST_DATABASE_URL = os.environ.get(
    'TEST_DATABASE_URL',
    'postgresql://m2x_user:m2x_password@localhost:5432/m2x_task_management'
)

# Test tenant ID (from seed data)
TEST_TENANT_ID = '11111111-1111-1111-1111-111111111111'
TEST_TENANT_ID_2 = '22222222-2222-2222-2222-222222222222'


@pytest.fixture(scope='session')
def db_connection():
    """Create a database connection for the test session."""
    conn = psycopg2.connect(TEST_DATABASE_URL, cursor_factory=RealDictCursor)
    yield conn
    conn.close()


@pytest.fixture
def db_cursor(db_connection):
    """Create a cursor for each test."""
    cursor = db_connection.cursor()
    yield cursor
    db_connection.rollback()  # Rollback any changes after each test
    cursor.close()


@pytest.fixture
def app():
    """Create Flask application for testing."""
    # Import here to avoid circular imports
    import sys
    sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
    from app import app as flask_app

    flask_app.config['TESTING'] = True
    return flask_app


@pytest.fixture
def client(app):
    """Create Flask test client."""
    return app.test_client()


@pytest.fixture
def sample_task_id(db_cursor):
    """Get a sample task ID from the database."""
    db_cursor.execute(
        "SELECT id FROM tasks WHERE tenant_id = %s LIMIT 1",
        (TEST_TENANT_ID,)
    )
    result = db_cursor.fetchone()
    return str(result['id']) if result else None


@pytest.fixture
def sample_equipment_id(db_cursor):
    """Get a sample equipment ID from the database."""
    db_cursor.execute(
        "SELECT id FROM equipments WHERE tenant_id = %s LIMIT 1",
        (TEST_TENANT_ID,)
    )
    result = db_cursor.fetchone()
    return str(result['id']) if result else None
