"""Application configuration for M2X Task Management System."""

from __future__ import annotations

import os
import sys
import warnings
from dataclasses import dataclass, field
from functools import lru_cache


def _get_env_required(key: str, default: str | None = None) -> str:
    """Get environment variable, warn in production if using default."""
    value = os.environ.get(key)
    if value:
        return value

    is_production = os.environ.get("FLASK_ENV") == "production"
    is_testing = os.environ.get("TESTING", "false").lower() == "true"

    if is_production and not is_testing:
        if default is None:
            print(f"CRITICAL: {key} must be set in production", file=sys.stderr)
            sys.exit(1)
        else:
            warnings.warn(
                f"Security Warning: {key} not set, using insecure default. "
                f"Set {key} environment variable in production.",
                RuntimeWarning,
                stacklevel=3,
            )

    return default or ""


@dataclass(frozen=True)
class DatabaseConfig:
    """Database configuration."""

    url: str = field(
        default_factory=lambda: _get_env_required(
            "DATABASE_URL", "postgresql://m2x_user:m2x_password@localhost:5432/m2x_db"
        )
    )
    pool_min_conn: int = 1
    pool_max_conn: int = 10


@dataclass(frozen=True)
class SecurityConfig:
    """Security configuration."""

    secret_key: str = field(
        default_factory=lambda: _get_env_required("SECRET_KEY", os.urandom(32).hex())
    )
    jwt_secret_key: str = field(
        default_factory=lambda: _get_env_required("JWT_SECRET_KEY", os.urandom(32).hex())
    )
    jwt_algorithm: str = "HS256"
    jwt_access_token_expire_minutes: int = 30
    jwt_refresh_token_expire_days: int = 7
    bcrypt_rounds: int = 12
    rate_limit_requests: int = 100
    rate_limit_window_seconds: int = 60


@dataclass(frozen=True)
class LoggingConfig:
    """Logging configuration."""

    level: str = field(default_factory=lambda: os.environ.get("LOG_LEVEL", "INFO"))
    format: str = "json"
    db_logging: bool = field(
        default_factory=lambda: os.environ.get("SECURITY_DB_LOGGING", "false").lower() == "true"
    )


@dataclass(frozen=True)
class Config:
    """Main application configuration."""

    debug: bool = field(
        default_factory=lambda: os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    )
    testing: bool = False
    json_as_ascii: bool = False

    database: DatabaseConfig = field(default_factory=DatabaseConfig)
    security: SecurityConfig = field(default_factory=SecurityConfig)
    logging: LoggingConfig = field(default_factory=LoggingConfig)


@lru_cache(maxsize=1)
def get_config() -> Config:
    """Get cached application configuration."""
    return Config()
