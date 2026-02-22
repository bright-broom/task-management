"""
pytest fixtures for M2X Task Management System tests.
"""

import os

import psycopg2
import pytest
from psycopg2.extras import RealDictCursor

# Test database URL (uses the same DB but could be configured separately)
TEST_DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    "postgresql://m2x_user:m2x_password@localhost:5432/m2x_task_management",
)

# Set DATABASE_URL for Flask app to use the test database
os.environ["DATABASE_URL"] = TEST_DATABASE_URL
os.environ["TESTING"] = "true"

# Test tenant ID (from seed data)
TEST_TENANT_ID = "11111111-1111-1111-1111-111111111111"
TEST_TENANT_ID_2 = "22222222-2222-2222-2222-222222222222"
TEST_USER_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"


@pytest.fixture(scope="session")
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

    flask_app.config["TESTING"] = True
    return flask_app


@pytest.fixture
def client(app):
    """Create Flask test client."""
    return app.test_client()


@pytest.fixture
def sample_task_id(db_cursor):
    """Get a sample task ID from the database."""
    db_cursor.execute("SELECT id FROM tasks WHERE tenant_id = %s LIMIT 1", (TEST_TENANT_ID,))
    result = db_cursor.fetchone()
    return str(result["id"]) if result else None


@pytest.fixture
def sample_equipment_id(db_cursor):
    """Get a sample equipment ID from the database."""
    db_cursor.execute("SELECT id FROM equipments WHERE tenant_id = %s LIMIT 1", (TEST_TENANT_ID,))
    result = db_cursor.fetchone()
    return str(result["id"]) if result else None


@pytest.fixture
def auth_token():
    """Generate a valid JWT access token for testing."""
    from security import create_access_token

    return create_access_token(
        user_id=TEST_USER_ID,
        tenant_id=TEST_TENANT_ID,
        role="user",
    )


@pytest.fixture
def admin_token():
    """Generate a valid JWT access token with admin role."""
    from security import create_access_token

    return create_access_token(
        user_id=TEST_USER_ID,
        tenant_id=TEST_TENANT_ID,
        role="admin",
    )


@pytest.fixture
def tenant2_token():
    """Generate a valid JWT access token for tenant 2."""
    from security import create_access_token

    return create_access_token(
        user_id="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        tenant_id=TEST_TENANT_ID_2,
        role="user",
    )


@pytest.fixture
def auth_headers(auth_token):
    """HTTP headers with Authorization for authenticated requests."""
    return {"Authorization": f"Bearer {auth_token}"}


@pytest.fixture
def admin_headers(admin_token):
    """HTTP headers with Authorization for admin requests."""
    return {"Authorization": f"Bearer {admin_token}"}


@pytest.fixture
def auth_client(client, auth_headers):
    """Test client wrapper that adds auth headers to all requests."""

    class AuthenticatedClient:
        def __init__(self, test_client, headers):
            self._client = test_client
            self._headers = headers

        def get(self, *args, **kwargs):
            headers = kwargs.pop("headers", {})
            headers.update(self._headers)
            return self._client.get(*args, headers=headers, **kwargs)

        def post(self, *args, **kwargs):
            headers = kwargs.pop("headers", {})
            headers.update(self._headers)
            return self._client.post(*args, headers=headers, **kwargs)

        def patch(self, *args, **kwargs):
            headers = kwargs.pop("headers", {})
            headers.update(self._headers)
            return self._client.patch(*args, headers=headers, **kwargs)

        def delete(self, *args, **kwargs):
            headers = kwargs.pop("headers", {})
            headers.update(self._headers)
            return self._client.delete(*args, headers=headers, **kwargs)

        def put(self, *args, **kwargs):
            headers = kwargs.pop("headers", {})
            headers.update(self._headers)
            return self._client.put(*args, headers=headers, **kwargs)

    return AuthenticatedClient(client, auth_headers)
