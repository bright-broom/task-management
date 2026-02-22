"""
M2X Task Management - 構造化ログ設定モジュール

JSON形式の構造化ログを提供し、以下を実現:
- リクエストID、テナントID、ユーザーIDの自動付与
- ログ集約基盤（ELK, Datadog等）との連携準備
- 環境別のログレベル設定
- 一貫したログフォーマット
"""

from __future__ import annotations

import json
import logging
import os
import sys
import uuid
from contextvars import ContextVar
from datetime import datetime, timezone
from functools import wraps
from typing import Any, Callable, TypeVar

# ============================================================================
# Context Variables for Request-scoped Data
# ============================================================================

request_id_var: ContextVar[str] = ContextVar("request_id", default="")
tenant_id_var: ContextVar[str] = ContextVar("tenant_id", default="")
user_id_var: ContextVar[str] = ContextVar("user_id", default="")

F = TypeVar("F", bound=Callable[..., Any])


def set_request_context(
    request_id: str | None = None,
    tenant_id: str | None = None,
    user_id: str | None = None,
) -> None:
    """
    リクエストコンテキストを設定。

    Args:
        request_id: リクエストID（Noneの場合は自動生成）
        tenant_id: テナントID
        user_id: ユーザーID
    """
    if request_id:
        request_id_var.set(request_id)
    elif not request_id_var.get():
        request_id_var.set(str(uuid.uuid4()))

    if tenant_id:
        tenant_id_var.set(tenant_id)

    if user_id:
        user_id_var.set(user_id)


def clear_request_context() -> None:
    """リクエストコンテキストをクリア。"""
    request_id_var.set("")
    tenant_id_var.set("")
    user_id_var.set("")


def get_request_id() -> str:
    """現在のリクエストIDを取得。"""
    return request_id_var.get()


# ============================================================================
# JSON Log Formatter
# ============================================================================


class StructuredLogFormatter(logging.Formatter):
    """
    JSON形式の構造化ログフォーマッター。

    出力形式:
    {
        "timestamp": "2026-02-20T12:34:56.789Z",
        "level": "INFO",
        "logger": "web.app",
        "message": "Request processed",
        "request_id": "uuid",
        "tenant_id": "uuid",
        "user_id": "uuid",
        "extra": {...}
    }
    """

    def __init__(self, include_hostname: bool = True) -> None:
        super().__init__()
        self.include_hostname = include_hostname
        self._hostname = os.environ.get("HOSTNAME", os.environ.get("HOST", "unknown"))
        self._service = os.environ.get("SERVICE_NAME", "m2x-task-management")
        self._environment = os.environ.get("ENVIRONMENT", "development")

    def format(self, record: logging.LogRecord) -> str:
        """ログレコードをJSON形式にフォーマット。"""
        log_data: dict[str, Any] = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        log_data["service"] = self._service
        log_data["environment"] = self._environment

        if self.include_hostname:
            log_data["hostname"] = self._hostname

        request_id = request_id_var.get()
        if request_id:
            log_data["request_id"] = request_id

        tenant_id = tenant_id_var.get()
        if tenant_id:
            log_data["tenant_id"] = tenant_id

        user_id = user_id_var.get()
        if user_id:
            log_data["user_id"] = user_id

        log_data["source"] = {
            "file": record.pathname,
            "line": record.lineno,
            "function": record.funcName,
        }

        if record.exc_info:
            log_data["exception"] = {
                "type": record.exc_info[0].__name__ if record.exc_info[0] else None,
                "message": str(record.exc_info[1]) if record.exc_info[1] else None,
                "traceback": self.formatException(record.exc_info),
            }

        extra_fields = {}
        standard_fields = {
            "name",
            "msg",
            "args",
            "created",
            "filename",
            "funcName",
            "levelname",
            "levelno",
            "lineno",
            "module",
            "msecs",
            "pathname",
            "process",
            "processName",
            "relativeCreated",
            "stack_info",
            "exc_info",
            "exc_text",
            "thread",
            "threadName",
            "message",
            "taskName",
        }

        for key, value in record.__dict__.items():
            if key not in standard_fields and not key.startswith("_"):
                try:
                    json.dumps(value)  # JSONシリアライズ可能かチェック
                    extra_fields[key] = value
                except (TypeError, ValueError):
                    extra_fields[key] = str(value)

        if extra_fields:
            log_data["extra"] = extra_fields

        return json.dumps(log_data, ensure_ascii=False, default=str)


class ConsoleLogFormatter(logging.Formatter):
    """
    開発環境向けのコンソールフォーマッター。

    カラー出力と読みやすいフォーマットを提供。
    """

    COLORS = {
        "DEBUG": "\033[36m",  # Cyan
        "INFO": "\033[32m",  # Green
        "WARNING": "\033[33m",  # Yellow
        "ERROR": "\033[31m",  # Red
        "CRITICAL": "\033[35m",  # Magenta
    }
    RESET = "\033[0m"

    def format(self, record: logging.LogRecord) -> str:
        """ログレコードを読みやすい形式にフォーマット。"""
        color = self.COLORS.get(record.levelname, "")
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]

        context_parts = []
        request_id = request_id_var.get()
        if request_id:
            context_parts.append(f"req={request_id[:8]}")
        tenant_id = tenant_id_var.get()
        if tenant_id:
            context_parts.append(f"tenant={tenant_id[:8]}")
        user_id = user_id_var.get()
        if user_id:
            context_parts.append(f"user={user_id[:8]}")

        context_str = f" [{', '.join(context_parts)}]" if context_parts else ""

        base = (
            f"{timestamp} {color}{record.levelname:8}{self.RESET} "
            f"{record.name}{context_str}: {record.getMessage()}"
        )

        if record.exc_info:
            base += f"\n{self.formatException(record.exc_info)}"

        return base


# ============================================================================
# Logger Configuration
# ============================================================================


def configure_logging(
    log_level: str | None = None,
    json_format: bool | None = None,
    stream: Any = None,
) -> None:
    """
    アプリケーションのログ設定を構成。

    Args:
        log_level: ログレベル（DEBUG, INFO, WARNING, ERROR, CRITICAL）
        json_format: JSON形式で出力するか（None時は環境に応じて自動判定）
        stream: 出力先ストリーム（デフォルトはsys.stderr）

    環境変数:
        LOG_LEVEL: ログレベル（デフォルト: INFO）
        LOG_FORMAT: 'json' または 'console'（デフォルト: 環境に応じて自動）
        ENVIRONMENT: 'production', 'staging', 'development' など
    """
    level_str = log_level or os.environ.get("LOG_LEVEL", "INFO")
    level = getattr(logging, level_str.upper(), logging.INFO)

    if json_format is None:
        log_format = os.environ.get("LOG_FORMAT", "")
        environment = os.environ.get("ENVIRONMENT", "development")
        json_format = log_format.lower() == "json" or environment in (
            "production",
            "staging",
        )

    if stream is None:
        stream = sys.stderr

    root_logger = logging.getLogger()
    root_logger.setLevel(level)

    for handler in root_logger.handlers[:]:
        root_logger.removeHandler(handler)

    handler = logging.StreamHandler(stream)
    handler.setLevel(level)

    if json_format:
        handler.setFormatter(StructuredLogFormatter())
    else:
        handler.setFormatter(ConsoleLogFormatter())

    root_logger.addHandler(handler)

    # ライブラリの冗長ログを抑制
    logging.getLogger("werkzeug").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)


def get_logger(name: str) -> logging.Logger:
    """
    名前付きロガーを取得。

    Args:
        name: ロガー名

    Returns:
        設定済みのロガー
    """
    return logging.getLogger(name)


# ============================================================================
# Logging Decorators
# ============================================================================


def log_function_call(logger: logging.Logger | None = None) -> Callable[[F], F]:
    """
    関数の呼び出しと結果をログに記録するデコレータ。

    Args:
        logger: 使用するロガー（Noneの場合は関数のモジュールから取得）

    Returns:
        デコレータ関数
    """

    def decorator(func: F) -> F:
        nonlocal logger
        if logger is None:
            logger = logging.getLogger(func.__module__)

        @wraps(func)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            func_name = func.__qualname__
            logger.debug(
                f"Calling {func_name}",
                extra={
                    "function": func_name,
                    "args_count": len(args),
                    "kwargs_keys": list(kwargs.keys()),
                },
            )

            try:
                result = func(*args, **kwargs)
                logger.debug(f"{func_name} completed successfully", extra={"function": func_name})
                return result
            except Exception as e:
                logger.error(
                    f"{func_name} failed: {e}",
                    extra={"function": func_name, "error_type": type(e).__name__},
                    exc_info=True,
                )
                raise

        return wrapper  # type: ignore[return-value]

    return decorator


# ============================================================================
# Flask Integration
# ============================================================================


def setup_flask_logging(app: Any) -> None:
    """
    Flaskアプリケーションにログミドルウェアを設定。

    Args:
        app: Flaskアプリケーションインスタンス
    """
    from flask import g, request

    logger = get_logger("web.request")

    @app.before_request
    def before_request() -> None:
        """リクエスト開始時の処理。"""
        request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
        set_request_context(request_id=request_id)
        g.request_id = request_id
        g.request_start_time = datetime.now(timezone.utc)

        logger.info(
            f"Request started: {request.method} {request.path}",
            extra={
                "method": request.method,
                "path": request.path,
                "remote_addr": request.remote_addr,
                "user_agent": request.user_agent.string,
            },
        )

    @app.after_request
    def after_request(response: Any) -> Any:
        """リクエスト完了時の処理。"""
        if hasattr(g, "request_id"):
            response.headers["X-Request-ID"] = g.request_id

        duration_ms = 0.0
        if hasattr(g, "request_start_time"):
            duration = datetime.now(timezone.utc) - g.request_start_time
            duration_ms = duration.total_seconds() * 1000

        logger.info(
            f"Request completed: {request.method} {request.path} -> {response.status_code}",
            extra={
                "method": request.method,
                "path": request.path,
                "status_code": response.status_code,
                "duration_ms": round(duration_ms, 2),
                "content_length": response.content_length,
            },
        )

        return response

    @app.teardown_request
    def teardown_request(exception: BaseException | None = None) -> None:
        """リクエスト終了時のクリーンアップ。"""
        if exception:
            logger.error(
                f"Request failed with exception: {exception}",
                extra={"error_type": type(exception).__name__},
                exc_info=True,
            )
        clear_request_context()


# ============================================================================
# Security Event Logger Integration
# ============================================================================


class StructuredSecurityLogger:
    """
    セキュリティイベント用の構造化ロガー。

    セキュリティ監査に必要な情報を構造化形式で記録。
    """

    def __init__(self) -> None:
        self.logger = get_logger("security")

    def log_event(
        self,
        event_type: str,
        severity: str,
        message: str,
        **context: Any,
    ) -> None:
        """
        セキュリティイベントを記録。

        Args:
            event_type: イベントタイプ（auth_success, auth_failure, rate_limit等）
            severity: 重要度（low, medium, high, critical）
            message: イベントメッセージ
            **context: 追加コンテキスト
        """
        extra = {
            "event_type": event_type,
            "severity": severity,
            "security_event": True,
            **context,
        }

        level_map = {
            "low": logging.INFO,
            "medium": logging.WARNING,
            "high": logging.ERROR,
            "critical": logging.CRITICAL,
        }
        level = level_map.get(severity, logging.INFO)

        self.logger.log(level, message, extra=extra)

    def auth_success(self, user_id: str, method: str, **context: Any) -> None:
        """認証成功イベント。"""
        self.log_event(
            "auth_success",
            "low",
            f"Authentication successful for user {user_id}",
            user_id=user_id,
            auth_method=method,
            **context,
        )

    def auth_failure(self, reason: str, **context: Any) -> None:
        """認証失敗イベント。"""
        self.log_event(
            "auth_failure",
            "medium",
            f"Authentication failed: {reason}",
            failure_reason=reason,
            **context,
        )

    def rate_limit_exceeded(self, ip_address: str, endpoint: str, **context: Any) -> None:
        """レート制限超過イベント。"""
        self.log_event(
            "rate_limit_exceeded",
            "medium",
            f"Rate limit exceeded for {ip_address} on {endpoint}",
            ip_address=ip_address,
            endpoint=endpoint,
            **context,
        )

    def suspicious_activity(self, description: str, **context: Any) -> None:
        """不審なアクティビティイベント。"""
        self.log_event(
            "suspicious_activity",
            "high",
            f"Suspicious activity detected: {description}",
            **context,
        )

    def security_violation(self, description: str, **context: Any) -> None:
        """セキュリティ違反イベント。"""
        self.log_event(
            "security_violation",
            "critical",
            f"Security violation: {description}",
            **context,
        )


structured_security_logger = StructuredSecurityLogger()
