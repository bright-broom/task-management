"""Backward compatibility re-export for metrics module.

This module re-exports from infrastructure.metrics for backward compatibility.
New code should import from infrastructure.metrics directly.
"""

from infrastructure.metrics import (
    _metrics,
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
    track_request_metrics,
)

__all__ = [
    "_metrics",
    "increment_counter",
    "observe_histogram",
    "set_gauge",
    "get_metrics",
    "track_request_metrics",
    "init_metrics",
    "metrics_endpoint",
    "record_task_created",
    "record_task_completed",
    "record_login_success",
    "record_login_failure",
]
