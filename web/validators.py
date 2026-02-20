"""
Validation utilities for M2X Task Management System.

This module provides:
- UUID validation decorator
- Required fields validation decorator
- String sanitization
- Optimistic locking utilities
- Pagination parameters
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from functools import wraps
from typing import Any, Callable, TypeVar

from flask import jsonify, request

F = TypeVar("F", bound=Callable[..., Any])

DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100


@dataclass
class PaginationParams:
    """Pagination parameters extracted from request."""

    page: int = 1
    per_page: int = DEFAULT_PAGE_SIZE
    sort_by: str | None = None
    sort_order: str = "asc"

    @classmethod
    def from_request(
        cls,
        default_sort: str | None = None,
        default_order: str = "desc",
    ) -> PaginationParams:
        """Extract pagination parameters from request args."""
        try:
            page = max(1, int(request.args.get("page", 1)))
        except (ValueError, TypeError):
            page = 1

        try:
            per_page = min(
                MAX_PAGE_SIZE, max(1, int(request.args.get("per_page", DEFAULT_PAGE_SIZE)))
            )
        except (ValueError, TypeError):
            per_page = DEFAULT_PAGE_SIZE

        sort_by = request.args.get("sort_by", default_sort)
        sort_order = request.args.get("sort_order", default_order)
        if sort_order not in ("asc", "desc"):
            sort_order = default_order

        return cls(page=page, per_page=per_page, sort_by=sort_by, sort_order=sort_order)

    @property
    def offset(self) -> int:
        """Calculate SQL offset."""
        return (self.page - 1) * self.per_page


def is_valid_uuid(value: str) -> bool:
    """Check if string is a valid UUID."""
    try:
        uuid.UUID(str(value))
        return True
    except (ValueError, AttributeError):
        return False


def validate_uuid(param_name: str) -> Callable[[F], F]:
    """Decorator to validate UUID parameters."""

    def decorator(f: F) -> F:
        @wraps(f)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            param_value = kwargs.get(param_name)
            if param_value and not is_valid_uuid(param_value):
                return (
                    jsonify(
                        {
                            "error": "Invalid UUID format",
                            "parameter": param_name,
                            "value": param_value,
                        }
                    ),
                    400,
                )
            return f(*args, **kwargs)

        return wrapper  # type: ignore

    return decorator


def validate_required_fields(required: list[str]) -> Callable[[F], F]:
    """Decorator to validate required JSON fields."""

    def decorator(f: F) -> F:
        @wraps(f)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            if not request.is_json:
                return jsonify({"error": "Content-Type must be application/json"}), 400

            data = request.get_json()
            if not data:
                return jsonify({"error": "Request body is required"}), 400

            missing = [field for field in required if field not in data or data[field] is None]
            if missing:
                return (
                    jsonify(
                        {
                            "error": "Missing required fields",
                            "fields": missing,
                        }
                    ),
                    400,
                )
            return f(*args, **kwargs)

        return wrapper  # type: ignore

    return decorator


def sanitize_string(value: str | None, max_length: int = 255) -> str | None:
    """Sanitize and truncate string input."""
    if value is None:
        return None
    return str(value).strip()[:max_length]


class OptimisticLockError(Exception):
    """Optimistic lock conflict error."""

    pass


def validate_version(data: dict[str, Any], field: str = "version") -> int | None:
    """Extract and validate version number for optimistic locking."""
    version = data.get(field)
    if version is None:
        return None
    try:
        v = int(version)
        if v < 1:
            raise ValueError("Version must be a positive integer")
        return v
    except (TypeError, ValueError) as e:
        raise ValueError(f"Invalid version format: {e}") from e


def build_optimistic_update(
    updates: list[str],
    params: list[Any],
    current_version: int | None,
) -> tuple[list[str], list[Any]]:
    """Add version increment for optimistic locking."""
    if current_version is not None:
        updates.append("version = version + 1")
    return updates, params


def get_request_user_context() -> tuple[str | None, str | None]:
    """Get user context from request headers (development only)."""
    user_id = request.headers.get("X-User-ID")
    user_name = request.headers.get("X-User-Name")
    return user_id, user_name


def build_pagination_response(
    items: list[Any],
    pagination: PaginationParams,
    total: int,
) -> dict[str, Any]:
    """Build standard pagination response."""
    return {
        "items": items,
        "pagination": {
            "page": pagination.page,
            "per_page": pagination.per_page,
            "total": total,
            "total_pages": (total + pagination.per_page - 1) // pagination.per_page,
        },
    }
