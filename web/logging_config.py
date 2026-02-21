"""Backward compatibility re-export for logging module.

This module re-exports from infrastructure.logging for backward compatibility.
New code should import from infrastructure.logging directly.
"""

from infrastructure.logging import (
    ConsoleLogFormatter,
    StructuredLogFormatter,
    StructuredSecurityLogger,
    clear_request_context,
    configure_logging,
    get_logger,
    get_request_id,
    log_function_call,
    request_id_var,
    set_request_context,
    setup_flask_logging,
    tenant_id_var,
    user_id_var,
)

__all__ = [
    "request_id_var",
    "tenant_id_var",
    "user_id_var",
    "StructuredLogFormatter",
    "ConsoleLogFormatter",
    "StructuredSecurityLogger",
    "configure_logging",
    "get_logger",
    "get_request_id",
    "set_request_context",
    "clear_request_context",
    "log_function_call",
    "setup_flask_logging",
]
