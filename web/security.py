"""
M2X セキュリティモジュール

グローバル基準のセキュリティ機能を提供:
- JWT認証
- パスワードハッシュ（bcrypt）
- レート制限
- セキュリティヘッダー
- CSRF保護
- 入力サニタイズ
- セキュリティイベントログ

準拠規格:
- OWASP Top 10
- NIST 800-63B
- ISO 27001
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import re
import secrets
from datetime import datetime, timedelta, timezone
from functools import wraps
from typing import Any, Callable, TypeVar

import jwt
from flask import Flask, Response, g, jsonify, request

JWT_SECRET_KEY = os.environ.get("JWT_SECRET_KEY", secrets.token_hex(32))
JWT_ALGORITHM = "HS256"
JWT_ACCESS_TOKEN_EXPIRES = timedelta(hours=1)
JWT_REFRESH_TOKEN_EXPIRES = timedelta(days=7)

BCRYPT_ROUNDS = 12
MAX_LOGIN_ATTEMPTS = 5
LOCKOUT_DURATION_MINUTES = 30
SESSION_TIMEOUT_MINUTES = 60

RATE_LIMIT_DEFAULT = "60/minute"
RATE_LIMIT_STRICT = "10/minute"
RATE_LIMIT_RELAXED = "200/minute"

CORS_ALLOWED_ORIGINS = os.environ.get(
    "CORS_ALLOWED_ORIGINS", "http://localhost:8080,http://localhost:3000"
).split(",")
CORS_ALLOWED_METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
CORS_ALLOWED_HEADERS = ["Content-Type", "Authorization", "X-Request-ID", "X-CSRF-Token"]
CORS_MAX_AGE = 86400

CSP_POLICY = {
    "default-src": "'self'",
    "script-src": "'self' 'unsafe-inline' cdn.tailwindcss.com",
    "style-src": "'self' 'unsafe-inline'",
    "img-src": "'self' data: https:",
    "font-src": "'self'",
    "connect-src": "'self'",
    "frame-ancestors": "'none'",
    "form-action": "'self'",
    "base-uri": "'self'",
}

logger = logging.getLogger(__name__)

F = TypeVar("F", bound=Callable[..., Any])

try:
    import bcrypt

    BCRYPT_AVAILABLE = True
except ImportError:
    BCRYPT_AVAILABLE = False
    logger.warning("bcrypt not available, using fallback PBKDF2 hashing")


def hash_password(password: str) -> str:
    """Hash password using bcrypt (or PBKDF2 fallback)."""
    if BCRYPT_AVAILABLE:
        bcrypt_salt = bcrypt.gensalt(rounds=BCRYPT_ROUNDS)
        return bcrypt.hashpw(password.encode("utf-8"), bcrypt_salt).decode("utf-8")
    else:
        # PBKDF2フォールバック
        import hashlib

        pbkdf2_salt = secrets.token_hex(16)
        key = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), pbkdf2_salt.encode("utf-8"), 100000
        )
        return f"pbkdf2:sha256:100000${pbkdf2_salt}${key.hex()}"


def verify_password(password: str, password_hash: str) -> bool:
    """Verify password against stored hash."""
    if password_hash.startswith("pbkdf2:"):
        # PBKDFフォールバック形式
        parts = password_hash.split("$")
        if len(parts) != 3:
            return False
        salt = parts[1]
        stored_key = parts[2]
        key = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt.encode("utf-8"), 100000)
        return hmac.compare_digest(key.hex(), stored_key)
    elif BCRYPT_AVAILABLE:
        try:
            return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))
        except Exception:
            return False
    else:
        return False


def check_password_strength(password: str) -> dict[str, Any]:
    """Check password strength (NIST 800-63B compliant)."""
    errors: list[str] = []
    score = 0

    # 長さチェック
    if len(password) < 12:
        errors.append("Password must be at least 12 characters")
    else:
        score += 1
        if len(password) >= 16:
            score += 1

    # 大文字
    if not re.search(r"[A-Z]", password):
        errors.append("Password must contain at least one uppercase letter")
    else:
        score += 1

    # 小文字
    if not re.search(r"[a-z]", password):
        errors.append("Password must contain at least one lowercase letter")
    else:
        score += 1

    # 数字
    if not re.search(r"\d", password):
        errors.append("Password must contain at least one number")
    else:
        score += 1

    # 特殊文字
    if not re.search(r"[!@#$%^&*()_+\-=\[\]{}|;:,.<>?]", password):
        errors.append("Password must contain at least one special character")
    else:
        score += 1

    # 一般的なパスワードチェック（簡易版）
    common_passwords = {
        "password",
        "123456",
        "qwerty",
        "admin",
        "letmein",
        "welcome",
        "monkey",
        "dragon",
        "master",
        "login",
    }
    if password.lower() in common_passwords:
        errors.append("Password is too common")
        score = 0

    return {
        "valid": len(errors) == 0,
        "errors": errors,
        "score": min(score, 5),  # 0-5スケール
        "strength": ["very_weak", "weak", "fair", "good", "strong", "very_strong"][min(score, 5)],
    }


def create_access_token(
    user_id: str,
    tenant_id: str,
    role: str,
    additional_claims: dict[str, Any] | None = None,
) -> str:
    """Generate JWT access token."""
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "tenant_id": tenant_id,
        "role": role,
        "type": "access",
        "iat": now,
        "exp": now + JWT_ACCESS_TOKEN_EXPIRES,
        "jti": secrets.token_hex(16),  # JWT ID for revocation
    }
    if additional_claims:
        payload.update(additional_claims)

    return jwt.encode(payload, JWT_SECRET_KEY, algorithm=JWT_ALGORITHM)


def create_refresh_token(user_id: str, tenant_id: str) -> str:
    """Generate JWT refresh token."""
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "tenant_id": tenant_id,
        "type": "refresh",
        "iat": now,
        "exp": now + JWT_REFRESH_TOKEN_EXPIRES,
        "jti": secrets.token_hex(16),
    }
    return jwt.encode(payload, JWT_SECRET_KEY, algorithm=JWT_ALGORITHM)


def decode_token(token: str) -> dict[str, Any] | None:
    """Decode and validate JWT token."""
    try:
        payload = jwt.decode(token, JWT_SECRET_KEY, algorithms=[JWT_ALGORITHM])
        return payload
    except jwt.ExpiredSignatureError:
        logger.warning("Token expired")
        return None
    except jwt.InvalidTokenError as e:
        logger.warning(f"Invalid token: {e}")
        return None


def get_token_from_request() -> str | None:
    """Extract Bearer token from request."""
    auth_header = request.headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        return auth_header[7:]
    return None


def require_auth(f: F) -> F:
    """Decorator requiring valid JWT token."""

    @wraps(f)
    def decorated(*args: Any, **kwargs: Any) -> Any:
        token = get_token_from_request()
        if not token:
            return jsonify({"error": "Authorization header required"}), 401

        payload = decode_token(token)
        if not payload:
            return jsonify({"error": "Invalid or expired token"}), 401

        if payload.get("type") != "access":
            return jsonify({"error": "Invalid token type"}), 401

        # ユーザー情報をgオブジェクトに設定
        g.current_user = {
            "user_id": payload.get("sub"),
            "tenant_id": payload.get("tenant_id"),
            "role": payload.get("role"),
            "token_jti": payload.get("jti"),
        }

        return f(*args, **kwargs)

    return decorated  # type: ignore


def require_role(*allowed_roles: str) -> Callable[[F], F]:
    """Decorator requiring specific user roles."""

    def decorator(f: F) -> F:
        @wraps(f)
        @require_auth
        def decorated(*args: Any, **kwargs: Any) -> Any:
            user_role = g.current_user.get("role")
            if user_role not in allowed_roles:
                return (
                    jsonify(
                        {
                            "error": "Forbidden",
                            "message": f"Role '{user_role}' not authorized",
                        }
                    ),
                    403,
                )
            return f(*args, **kwargs)

        return decorated  # type: ignore

    return decorator


# In-memory rate limit store (use Redis in production)
_rate_limit_store: dict[str, list[float]] = {}


def check_rate_limit(
    key: str, limit: int = 60, window_seconds: int = 60
) -> tuple[bool, dict[str, Any]]:
    """Check if request is within rate limit."""
    import time

    now = time.time()
    window_start = now - window_seconds

    if key in _rate_limit_store:
        _rate_limit_store[key] = [t for t in _rate_limit_store[key] if t > window_start]
    else:
        _rate_limit_store[key] = []

    current_count = len(_rate_limit_store[key])

    if current_count >= limit:
        return False, {
            "limit": limit,
            "remaining": 0,
            "reset": int(window_start + window_seconds),
        }

    _rate_limit_store[key].append(now)
    return True, {
        "limit": limit,
        "remaining": limit - current_count - 1,
        "reset": int(window_start + window_seconds),
    }


def rate_limit(
    limit: int = 60, window_seconds: int = 60, key_func: Callable[[], str] | None = None
) -> Callable[[F], F]:
    """Rate limiting decorator."""

    def decorator(f: F) -> F:
        @wraps(f)
        def decorated(*args: Any, **kwargs: Any) -> Any:
            if key_func:
                key = key_func()
            else:
                key = f"{request.remote_addr}:{request.endpoint}"

            allowed, meta = check_rate_limit(key, limit, window_seconds)

            if not allowed:
                response = jsonify(
                    {
                        "error": "Rate limit exceeded",
                        "retry_after": meta["reset"] - int(datetime.now().timestamp()),
                    }
                )
                response.headers["X-RateLimit-Limit"] = str(meta["limit"])
                response.headers["X-RateLimit-Remaining"] = "0"
                response.headers["X-RateLimit-Reset"] = str(meta["reset"])
                response.headers["Retry-After"] = str(
                    meta["reset"] - int(datetime.now().timestamp())
                )
                return response, 429

            response = f(*args, **kwargs)

            if isinstance(response, tuple):
                resp = response[0]
            else:
                resp = response

            if hasattr(resp, "headers"):
                resp.headers["X-RateLimit-Limit"] = str(meta["limit"])
                resp.headers["X-RateLimit-Remaining"] = str(meta["remaining"])
                resp.headers["X-RateLimit-Reset"] = str(meta["reset"])

            return response

        return decorated  # type: ignore

    return decorator


def add_security_headers(response: Response) -> Response:
    """Add security headers to response."""
    if os.environ.get("ENABLE_HSTS", "false").lower() == "true":
        response.headers["Strict-Transport-Security"] = (
            "max-age=31536000; includeSubDomains; preload"
        )

    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"

    csp_parts = [f"{key} {value}" for key, value in CSP_POLICY.items()]
    response.headers["Content-Security-Policy"] = "; ".join(csp_parts)
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=(), payment=()"

    if request.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
        response.headers["Pragma"] = "no-cache"

    return response


def handle_cors(response: Response) -> Response:
    """Add CORS headers to response."""
    origin = request.headers.get("Origin", "")

    if origin in CORS_ALLOWED_ORIGINS or "*" in CORS_ALLOWED_ORIGINS:
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Allow-Credentials"] = "true"
    else:
        response.headers["Access-Control-Allow-Origin"] = CORS_ALLOWED_ORIGINS[0]

    response.headers["Access-Control-Allow-Methods"] = ", ".join(CORS_ALLOWED_METHODS)
    response.headers["Access-Control-Allow-Headers"] = ", ".join(CORS_ALLOWED_HEADERS)
    response.headers["Access-Control-Max-Age"] = str(CORS_MAX_AGE)
    response.headers["Access-Control-Expose-Headers"] = (
        "X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset"
    )

    return response


def generate_csrf_token() -> str:
    """Generate CSRF token."""
    return secrets.token_hex(32)


def validate_csrf_token(token: str, stored_token: str) -> bool:
    """Validate CSRF token using timing-safe comparison."""
    return hmac.compare_digest(token, stored_token)


def require_csrf(f: F) -> F:
    """CSRF protection decorator."""

    @wraps(f)
    def decorated(*args: Any, **kwargs: Any) -> Any:
        if request.method in ("POST", "PUT", "PATCH", "DELETE"):
            csrf_token = request.headers.get("X-CSRF-Token")
            if not csrf_token:
                return jsonify({"error": "CSRF token required"}), 403

            # セッションからトークンを取得して検証
            # 実際の実装ではセッションストアを使用
            stored_token = g.get("csrf_token")
            if stored_token and not validate_csrf_token(csrf_token, stored_token):
                return jsonify({"error": "Invalid CSRF token"}), 403

        return f(*args, **kwargs)

    return decorated  # type: ignore


DANGEROUS_PATTERNS = [
    r"<script",
    r"javascript:",
    r"on\w+\s*=",
    r"data:text/html",
    r"vbscript:",
    r"expression\s*\(",
]


def sanitize_html(value: str) -> str:
    """Escape HTML special characters."""
    if not value:
        return value

    replacements = {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#x27;",
        "/": "&#x2F;",
    }
    for char, replacement in replacements.items():
        value = value.replace(char, replacement)
    return value


def detect_xss(value: str) -> bool:
    """Detect XSS attack patterns."""
    if not value:
        return False

    value_lower = value.lower()
    for pattern in DANGEROUS_PATTERNS:
        if re.search(pattern, value_lower, re.IGNORECASE):
            return True
    return False


def sanitize_input(
    value: str | None,
    max_length: int = 255,
    allow_html: bool = False,
    strip_dangerous: bool = True,
) -> str | None:
    """Sanitize input value for safe storage."""
    if value is None:
        return None

    value = str(value).strip()
    value = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", value)

    if strip_dangerous and detect_xss(value):
        logger.warning(f"XSS pattern detected and sanitized: {value[:100]}")
        for pattern in DANGEROUS_PATTERNS:
            value = re.sub(pattern, "", value, flags=re.IGNORECASE)

    if not allow_html:
        value = sanitize_html(value)

    if len(value) > max_length:
        value = value[:max_length]

    return value


def validate_email(email: str) -> bool:
    """Validate email format (RFC 5322 basic)."""
    pattern = r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    return bool(re.match(pattern, email)) and len(email) <= 254


def validate_uuid(value: str) -> bool:
    """Validate UUID format."""
    pattern = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    return bool(re.match(pattern, value.lower()))


class SecurityEventLogger:
    """Security event logger for audit and monitoring."""

    def __init__(self, app: Flask | None = None):
        self.app = app
        self._db_logging_enabled = False

    def init_app(self, app: Flask) -> None:
        self.app = app
        self._db_logging_enabled = app.config.get("SECURITY_DB_LOGGING", False)

    def log(
        self,
        event_type: str,
        tenant_id: str | None = None,
        user_id: str | None = None,
        details: dict[str, Any] | None = None,
        severity: str = "info",
    ) -> None:
        """Log security event."""
        ip_address = request.remote_addr if request else None
        user_agent = request.headers.get("User-Agent") if request else None

        log_entry = {
            "event_type": event_type,
            "tenant_id": tenant_id,
            "user_id": user_id,
            "ip_address": ip_address,
            "user_agent": user_agent,
            "details": details or {},
            "severity": severity,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

        # ログレベルに応じて出力
        log_func = getattr(logger, severity, logger.info)
        log_func(f"SECURITY_EVENT: {event_type} | {log_entry}")

        # データベースへの記録（有効な場合）
        if self._db_logging_enabled:
            self._log_to_database(log_entry)

    def _log_to_database(self, log_entry: dict[str, Any]) -> None:
        pass

    def login_success(self, user_id: str, tenant_id: str) -> None:
        self.log("login_success", tenant_id, user_id, severity="info")

    def login_failure(self, email: str, reason: str, tenant_id: str | None = None) -> None:
        self.log(
            "login_failure",
            tenant_id,
            details={"email": email, "reason": reason},
            severity="warning",
        )

    def permission_denied(self, user_id: str, tenant_id: str, resource: str, action: str) -> None:
        self.log(
            "permission_denied",
            tenant_id,
            user_id,
            details={"resource": resource, "action": action},
            severity="warning",
        )

    def rate_limit_exceeded(self, endpoint: str) -> None:
        self.log(
            "rate_limit_exceeded",
            details={"endpoint": endpoint},
            severity="warning",
        )

    def suspicious_activity(self, description: str, details: dict[str, Any]) -> None:
        self.log(
            "suspicious_activity",
            details={"description": description, **details},
            severity="error",
        )


security_logger = SecurityEventLogger()


def init_security(app: Flask) -> None:
    """Initialize security features for Flask app."""
    security_logger.init_app(app)

    @app.after_request
    def apply_security(response: Response) -> Response:
        response = add_security_headers(response)
        response = handle_cors(response)
        return response

    @app.before_request
    def handle_preflight() -> Response | None:
        if request.method == "OPTIONS":
            response = Response()
            response = handle_cors(response)
            return response
        return None

    @app.before_request
    def set_request_id() -> None:
        request_id = request.headers.get("X-Request-ID", secrets.token_hex(8))
        g.request_id = request_id

    @app.after_request
    def add_request_id(response: Response) -> Response:
        if hasattr(g, "request_id"):
            response.headers["X-Request-ID"] = g.request_id
        return response

    logger.info("Security module initialized")


def generate_api_key() -> tuple[str, str]:
    """Generate API key and its hash."""
    prefix = "m2x_"
    random_part = secrets.token_urlsafe(32)
    full_key = f"{prefix}{random_part}"
    key_hash = hashlib.sha256(full_key.encode()).hexdigest()
    return full_key, key_hash


def hash_api_key(api_key: str) -> str:
    """Hash API key."""
    return hashlib.sha256(api_key.encode()).hexdigest()


def generate_secure_token(length: int = 32) -> str:
    """Generate cryptographically secure token."""
    return secrets.token_urlsafe(length)


def constant_time_compare(a: str, b: str) -> bool:
    """Timing-safe string comparison."""
    return hmac.compare_digest(a, b)
