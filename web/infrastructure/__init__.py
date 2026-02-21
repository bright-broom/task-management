"""Infrastructure module for M2X Task Management System."""

from infrastructure.database import (
    close_connection_pool,
    get_connection_pool,
    get_db_connection,
    get_db_cursor,
    tenant_context,
)
from infrastructure.logging import (
    configure_logging,
    get_logger,
    setup_flask_logging,
)
from infrastructure.metrics import (
    get_metrics,
    increment_counter,
    init_metrics,
    metrics_endpoint,
    observe_histogram,
    record_login_failure,
    record_login_success,
    record_task_completed,
    record_task_created,
    set_gauge,
)

__all__ = [
    # Database
    "get_connection_pool",
    "close_connection_pool",
    "get_db_connection",
    "get_db_cursor",
    "tenant_context",
    # Logging
    "configure_logging",
    "get_logger",
    "setup_flask_logging",
    # Metrics
    "init_metrics",
    "metrics_endpoint",
    "increment_counter",
    "observe_histogram",
    "set_gauge",
    "get_metrics",
    "record_task_created",
    "record_task_completed",
    "record_login_success",
    "record_login_failure",
]
