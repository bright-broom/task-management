"""Application configuration for M2X Task Management System."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from functools import lru_cache


@dataclass(frozen=True)
class DatabaseConfig:
    """Database configuration."""

    url: str = field(
        default_factory=lambda: os.environ.get(
            "DATABASE_URL", "postgresql://m2x_user:m2x_password@localhost:5432/m2x_db"
        )
    )
    pool_min_conn: int = 1
    pool_max_conn: int = 10


@dataclass(frozen=True)
class SecurityConfig:
    """Security configuration."""

    secret_key: str = field(
        default_factory=lambda: os.environ.get("SECRET_KEY", os.urandom(32).hex())
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
