"""
Prometheus metrics for M2X Task Management System.

This module provides:
- Request latency histogram
- Request counter by endpoint and status
- Database connection pool metrics
- Custom business metrics
"""

from __future__ import annotations

import time
from functools import wraps
from typing import Any, Callable, TypeVar

from flask import Flask, Response, g, request

F = TypeVar("F", bound=Callable[..., Any])

# In-memory metrics (use prometheus_client in production)
_metrics: dict[str, Any] = {
    "http_requests_total": {},
    "http_request_duration_seconds": [],
    "db_pool_connections_active": 0,
    "db_pool_connections_idle": 0,
    "tasks_created_total": 0,
    "tasks_completed_total": 0,
    "auth_login_success_total": 0,
    "auth_login_failure_total": 0,
}


def increment_counter(name: str, labels: dict[str, str] | None = None) -> None:
    key = f"{name}_{labels}" if labels else name
    if key not in _metrics["http_requests_total"]:
        _metrics["http_requests_total"][key] = 0
    _metrics["http_requests_total"][key] += 1


def observe_histogram(name: str, value: float) -> None:
    _metrics["http_request_duration_seconds"].append(value)
    if len(_metrics["http_request_duration_seconds"]) > 1000:
        _metrics["http_request_duration_seconds"] = _metrics["http_request_duration_seconds"][
            -1000:
        ]


def set_gauge(name: str, value: float) -> None:
    _metrics[name] = value


def get_metrics() -> dict[str, Any]:
    return _metrics.copy()


def track_request_metrics(f: F) -> F:

    @wraps(f)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        start_time = time.time()
        try:
            result = f(*args, **kwargs)
            status = result[1] if isinstance(result, tuple) else 200
            increment_counter(
                "http_requests",
                {
                    "method": request.method,
                    "endpoint": request.endpoint or "unknown",
                    "status": str(status),
                },
            )
            return result
        finally:
            duration = time.time() - start_time
            observe_histogram("http_request_duration", duration)

    return wrapper  # type: ignore


def init_metrics(app: Flask) -> None:
    @app.before_request
    def start_timer() -> None:
        g.start_time = time.time()

    @app.after_request
    def record_metrics(response: Response) -> Response:
        if hasattr(g, "start_time"):
            duration = time.time() - g.start_time
            observe_histogram("http_request_duration", duration)
            increment_counter(
                "http_requests",
                {
                    "method": request.method,
                    "endpoint": request.endpoint or "unknown",
                    "status": str(response.status_code),
                },
            )
        return response


def metrics_endpoint() -> tuple[Response, int]:
    """Return metrics in Prometheus format."""
    from flask import Response

    metrics = get_metrics()

    lines = [
        "# HELP http_requests_total Total number of HTTP requests",
        "# TYPE http_requests_total counter",
    ]

    for key, value in metrics["http_requests_total"].items():
        lines.append(f"http_requests_total{{{key}}} {value}")

    lines.extend(
        [
            "",
            "# HELP http_request_duration_seconds HTTP request latency",
            "# TYPE http_request_duration_seconds histogram",
        ]
    )

    durations = metrics["http_request_duration_seconds"]
    if durations:
        avg_duration = sum(durations) / len(durations)
        lines.append(f"http_request_duration_seconds_sum {sum(durations)}")
        lines.append(f"http_request_duration_seconds_count {len(durations)}")
        lines.append(f"http_request_duration_seconds_avg {avg_duration:.6f}")

    lines.extend(
        [
            "",
            "# HELP tasks_created_total Total tasks created",
            "# TYPE tasks_created_total counter",
            f"tasks_created_total {metrics['tasks_created_total']}",
            "",
            "# HELP tasks_completed_total Total tasks completed",
            "# TYPE tasks_completed_total counter",
            f"tasks_completed_total {metrics['tasks_completed_total']}",
            "",
            "# HELP auth_login_success_total Successful login attempts",
            "# TYPE auth_login_success_total counter",
            f"auth_login_success_total {metrics['auth_login_success_total']}",
            "",
            "# HELP auth_login_failure_total Failed login attempts",
            "# TYPE auth_login_failure_total counter",
            f"auth_login_failure_total {metrics['auth_login_failure_total']}",
        ]
    )

    return Response("\n".join(lines), mimetype="text/plain"), 200


def record_task_created() -> None:
    _metrics["tasks_created_total"] += 1


def record_task_completed() -> None:
    _metrics["tasks_completed_total"] += 1


def record_login_success() -> None:
    _metrics["auth_login_success_total"] += 1


def record_login_failure() -> None:
    _metrics["auth_login_failure_total"] += 1
