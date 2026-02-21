"""Utilities module for M2X Task Management System."""

from core.exceptions import DatabaseError, OptimisticLockError, RateLimitError
from utils.security import (
    SecurityEventLogger,
    check_password_strength,
    create_access_token,
    create_refresh_token,
    decode_token,
    detect_xss,
    generate_api_key,
    hash_password,
    init_security,
    rate_limit,
    sanitize_html,
    validate_email,
    verify_password,
)
from utils.validators import (
    DEFAULT_PAGE_SIZE,
    MAX_PAGE_SIZE,
    PaginationParams,
    build_optimistic_update,
    build_pagination_response,
    get_request_user_context,
    is_valid_uuid,
    sanitize_string,
    validate_required_fields,
    validate_uuid,
    validate_version,
)

__all__ = [
    # Security
    "init_security",
    "rate_limit",
    "hash_password",
    "verify_password",
    "check_password_strength",
    "validate_email",
    "create_access_token",
    "create_refresh_token",
    "decode_token",
    "sanitize_html",
    "detect_xss",
    "generate_api_key",
    "SecurityEventLogger",
    # Validators
    "DEFAULT_PAGE_SIZE",
    "MAX_PAGE_SIZE",
    "PaginationParams",
    "is_valid_uuid",
    "validate_uuid",
    "validate_required_fields",
    "sanitize_string",
    "validate_version",
    "build_optimistic_update",
    "get_request_user_context",
    "build_pagination_response",
    # Exceptions (re-exported from core.exceptions)
    "OptimisticLockError",
    "DatabaseError",
    "RateLimitError",
]
