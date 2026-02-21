"""Custom exceptions for M2X Task Management System."""

from __future__ import annotations


class M2XError(Exception):
    """Base exception for M2X application."""

    def __init__(self, message: str, code: str | None = None):
        self.message = message
        self.code = code or self.__class__.__name__
        super().__init__(self.message)


class ValidationError(M2XError):
    """Raised when input validation fails."""

    def __init__(self, message: str, field: str | None = None):
        self.field = field
        super().__init__(message, "VALIDATION_ERROR")


class NotFoundError(M2XError):
    """Raised when a resource is not found."""

    def __init__(self, resource: str, identifier: str | None = None):
        self.resource = resource
        self.identifier = identifier
        message = f"{resource} not found"
        if identifier:
            message = f"{resource} with id '{identifier}' not found"
        super().__init__(message, "NOT_FOUND")


class AuthenticationError(M2XError):
    """Raised when authentication fails."""

    def __init__(self, message: str = "Authentication required"):
        super().__init__(message, "AUTHENTICATION_ERROR")


class AuthorizationError(M2XError):
    """Raised when authorization fails."""

    def __init__(self, message: str = "Permission denied"):
        super().__init__(message, "AUTHORIZATION_ERROR")


class OptimisticLockError(M2XError):
    """Raised when optimistic locking conflict occurs."""

    def __init__(self, resource: str = "Resource"):
        message = f"{resource} has been modified by another user"
        super().__init__(message, "OPTIMISTIC_LOCK_ERROR")


class DatabaseError(M2XError):
    """Raised when a database operation fails."""

    def __init__(self, message: str = "Database operation failed"):
        super().__init__(message, "DATABASE_ERROR")


class RateLimitError(M2XError):
    """Raised when rate limit is exceeded."""

    def __init__(self, message: str = "Rate limit exceeded"):
        super().__init__(message, "RATE_LIMIT_ERROR")
