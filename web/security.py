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

# ============================================================================
# Configuration
# ============================================================================

# JWT設定
JWT_SECRET_KEY = os.environ.get("JWT_SECRET_KEY", secrets.token_hex(32))
JWT_ALGORITHM = "HS256"
JWT_ACCESS_TOKEN_EXPIRES = timedelta(hours=1)
JWT_REFRESH_TOKEN_EXPIRES = timedelta(days=7)

# セキュリティ設定
BCRYPT_ROUNDS = 12
MAX_LOGIN_ATTEMPTS = 5
LOCKOUT_DURATION_MINUTES = 30
SESSION_TIMEOUT_MINUTES = 60

# レート制限設定
RATE_LIMIT_DEFAULT = "60/minute"
RATE_LIMIT_STRICT = "10/minute"
RATE_LIMIT_RELAXED = "200/minute"

# CORS設定
CORS_ALLOWED_ORIGINS = os.environ.get(
    "CORS_ALLOWED_ORIGINS", "http://localhost:8080,http://localhost:3000"
).split(",")
CORS_ALLOWED_METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
CORS_ALLOWED_HEADERS = ["Content-Type", "Authorization", "X-Request-ID", "X-CSRF-Token"]
CORS_MAX_AGE = 86400  # 24 hours

# CSP設定
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

# ============================================================================
# Password Hashing (bcrypt-compatible with fallback)
# ============================================================================

try:
    import bcrypt

    BCRYPT_AVAILABLE = True
except ImportError:
    BCRYPT_AVAILABLE = False
    logger.warning("bcrypt not available, using fallback PBKDF2 hashing")


def hash_password(password: str) -> str:
    """
    パスワードをハッシュ化。

    bcryptが利用可能な場合はbcryptを使用、
    そうでない場合はPBKDF2-SHA256にフォールバック。

    Args:
        password: 平文パスワード

    Returns:
        ハッシュ化されたパスワード
    """
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
    """
    パスワードを検証。

    Args:
        password: 平文パスワード
        password_hash: 保存されているハッシュ

    Returns:
        パスワードが一致する場合True
    """
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
    """
    パスワード強度をチェック。

    NIST 800-63B準拠の要件:
    - 最小12文字
    - 大文字、小文字、数字、特殊文字を含む
    - 一般的なパスワードでないこと

    Args:
        password: チェック対象のパスワード

    Returns:
        強度チェック結果
    """
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


# ============================================================================
# JWT Token Management
# ============================================================================


def create_access_token(
    user_id: str,
    tenant_id: str,
    role: str,
    additional_claims: dict[str, Any] | None = None,
) -> str:
    """
    JWTアクセストークンを生成。

    Args:
        user_id: ユーザーID
        tenant_id: テナントID
        role: ユーザーロール
        additional_claims: 追加のクレーム

    Returns:
        JWTトークン文字列
    """
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
    """
    JWTリフレッシュトークンを生成。

    Args:
        user_id: ユーザーID
        tenant_id: テナントID

    Returns:
        JWTリフレッシュトークン
    """
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
    """
    JWTトークンをデコード・検証。

    Args:
        token: JWTトークン文字列

    Returns:
        ペイロード辞書、無効な場合はNone
    """
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
    """
    リクエストからBearerトークンを取得。

    Returns:
        トークン文字列、見つからない場合はNone
    """
    auth_header = request.headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        return auth_header[7:]
    return None


# ============================================================================
# Authentication Decorators
# ============================================================================


def require_auth(f: F) -> F:
    """
    認証必須デコレータ。

    JWTトークンを検証し、ユーザー情報をg.current_userに設定。
    """

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
    """
    ロールベースアクセス制御デコレータ。

    Args:
        allowed_roles: 許可されるロールのリスト

    Usage:
        @require_role('admin', 'manager')
        def admin_only_endpoint():
            ...
    """

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


# ============================================================================
# Rate Limiting
# ============================================================================

# シンプルなインメモリレート制限（本番環境ではRedis推奨）
_rate_limit_store: dict[str, list[float]] = {}


def check_rate_limit(
    key: str, limit: int = 60, window_seconds: int = 60
) -> tuple[bool, dict[str, Any]]:
    """
    レート制限をチェック。

    Args:
        key: レート制限キー（例: IP + エンドポイント）
        limit: ウィンドウ内の最大リクエスト数
        window_seconds: ウィンドウサイズ（秒）

    Returns:
        (許可されるか, メタデータ)のタプル
    """
    import time

    now = time.time()
    window_start = now - window_seconds

    # 古いエントリを削除
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
    """
    レート制限デコレータ。

    Args:
        limit: ウィンドウ内の最大リクエスト数
        window_seconds: ウィンドウサイズ（秒）
        key_func: レート制限キーを生成する関数

    Usage:
        @rate_limit(limit=10, window_seconds=60)
        def limited_endpoint():
            ...
    """

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

            # レート制限ヘッダーを追加
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


# ============================================================================
# Security Headers Middleware
# ============================================================================


def add_security_headers(response: Response) -> Response:
    """
    セキュリティヘッダーをレスポンスに追加。

    追加されるヘッダー:
    - Strict-Transport-Security (HSTS)
    - X-Content-Type-Options
    - X-Frame-Options
    - X-XSS-Protection
    - Content-Security-Policy
    - Referrer-Policy
    - Permissions-Policy

    Args:
        response: Flaskレスポンスオブジェクト

    Returns:
        ヘッダー追加済みレスポンス
    """
    # HSTS (本番環境でHTTPS使用時)
    if os.environ.get("ENABLE_HSTS", "false").lower() == "true":
        response.headers["Strict-Transport-Security"] = (
            "max-age=31536000; includeSubDomains; preload"
        )

    # コンテンツタイプスニッフィング防止
    response.headers["X-Content-Type-Options"] = "nosniff"

    # クリックジャッキング防止
    response.headers["X-Frame-Options"] = "DENY"

    # XSSフィルター（レガシーブラウザ用）
    response.headers["X-XSS-Protection"] = "1; mode=block"

    # CSP
    csp_parts = [f"{key} {value}" for key, value in CSP_POLICY.items()]
    response.headers["Content-Security-Policy"] = "; ".join(csp_parts)

    # リファラーポリシー
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"

    # パーミッションポリシー
    response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=(), payment=()"

    # キャッシュ制御（API用）
    if request.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
        response.headers["Pragma"] = "no-cache"

    return response


def handle_cors(response: Response) -> Response:
    """
    CORSヘッダーを追加。

    Args:
        response: Flaskレスポンスオブジェクト

    Returns:
        CORS対応レスポンス
    """
    origin = request.headers.get("Origin", "")

    # オリジン検証
    if origin in CORS_ALLOWED_ORIGINS or "*" in CORS_ALLOWED_ORIGINS:
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Allow-Credentials"] = "true"
    else:
        # 不明なオリジンの場合は最初の許可オリジンを設定
        response.headers["Access-Control-Allow-Origin"] = CORS_ALLOWED_ORIGINS[0]

    response.headers["Access-Control-Allow-Methods"] = ", ".join(CORS_ALLOWED_METHODS)
    response.headers["Access-Control-Allow-Headers"] = ", ".join(CORS_ALLOWED_HEADERS)
    response.headers["Access-Control-Max-Age"] = str(CORS_MAX_AGE)
    response.headers["Access-Control-Expose-Headers"] = (
        "X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset"
    )

    return response


# ============================================================================
# CSRF Protection
# ============================================================================


def generate_csrf_token() -> str:
    """CSRFトークンを生成。"""
    return secrets.token_hex(32)


def validate_csrf_token(token: str, stored_token: str) -> bool:
    """
    CSRFトークンを検証。

    タイミングセーフな比較を使用。
    """
    return hmac.compare_digest(token, stored_token)


def require_csrf(f: F) -> F:
    """
    CSRF保護デコレータ。

    POSTリクエストでX-CSRF-Tokenヘッダーを検証。
    """

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


# ============================================================================
# Input Sanitization
# ============================================================================

# 危険な文字パターン
DANGEROUS_PATTERNS = [
    r"<script",
    r"javascript:",
    r"on\w+\s*=",
    r"data:text/html",
    r"vbscript:",
    r"expression\s*\(",
]


def sanitize_html(value: str) -> str:
    """
    HTML特殊文字をエスケープ。

    Args:
        value: 入力文字列

    Returns:
        エスケープ済み文字列
    """
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
    """
    XSS攻撃パターンを検出。

    Args:
        value: チェック対象文字列

    Returns:
        XSSパターンが検出された場合True
    """
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
    """
    入力値を安全にサニタイズ。

    Args:
        value: 入力値
        max_length: 最大長
        allow_html: HTMLを許可するか
        strip_dangerous: 危険なパターンを除去するか

    Returns:
        サニタイズ済みの値
    """
    if value is None:
        return None

    # 文字列に変換
    value = str(value)

    # 前後の空白を除去
    value = value.strip()

    # 制御文字を除去（改行・タブ以外）
    value = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", value)

    # XSSパターンの検出と除去
    if strip_dangerous and detect_xss(value):
        logger.warning(f"XSS pattern detected and sanitized: {value[:100]}")
        for pattern in DANGEROUS_PATTERNS:
            value = re.sub(pattern, "", value, flags=re.IGNORECASE)

    # HTMLエスケープ
    if not allow_html:
        value = sanitize_html(value)

    # 長さ制限
    if len(value) > max_length:
        value = value[:max_length]

    return value


def validate_email(email: str) -> bool:
    """
    メールアドレス形式を検証。

    RFC 5322準拠の基本検証。
    """
    pattern = r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    return bool(re.match(pattern, email)) and len(email) <= 254


def validate_uuid(value: str) -> bool:
    """UUID形式を検証。"""
    pattern = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    return bool(re.match(pattern, value.lower()))


# ============================================================================
# Security Event Logging
# ============================================================================


class SecurityEventLogger:
    """セキュリティイベントロガー。"""

    def __init__(self, app: Flask | None = None):
        self.app = app
        self._db_logging_enabled = False

    def init_app(self, app: Flask) -> None:
        """Flaskアプリを初期化。"""
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
        """
        セキュリティイベントを記録。

        Args:
            event_type: イベントタイプ
            tenant_id: テナントID
            user_id: ユーザーID
            details: 追加詳細
            severity: 重要度 ('debug', 'info', 'warning', 'error', 'critical')
        """
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
        """データベースにイベントを記録。"""
        # 実装はアプリケーション固有
        pass

    def login_success(self, user_id: str, tenant_id: str) -> None:
        """ログイン成功を記録。"""
        self.log("login_success", tenant_id, user_id, severity="info")

    def login_failure(self, email: str, reason: str, tenant_id: str | None = None) -> None:
        """ログイン失敗を記録。"""
        self.log(
            "login_failure",
            tenant_id,
            details={"email": email, "reason": reason},
            severity="warning",
        )

    def permission_denied(self, user_id: str, tenant_id: str, resource: str, action: str) -> None:
        """権限拒否を記録。"""
        self.log(
            "permission_denied",
            tenant_id,
            user_id,
            details={"resource": resource, "action": action},
            severity="warning",
        )

    def rate_limit_exceeded(self, endpoint: str) -> None:
        """レート制限超過を記録。"""
        self.log(
            "rate_limit_exceeded",
            details={"endpoint": endpoint},
            severity="warning",
        )

    def suspicious_activity(self, description: str, details: dict[str, Any]) -> None:
        """不審なアクティビティを記録。"""
        self.log(
            "suspicious_activity",
            details={"description": description, **details},
            severity="error",
        )


# グローバルインスタンス
security_logger = SecurityEventLogger()

# ============================================================================
# Flask Integration
# ============================================================================


def init_security(app: Flask) -> None:
    """
    Flaskアプリにセキュリティ機能を統合。

    Args:
        app: Flaskアプリケーション
    """
    # セキュリティロガー初期化
    security_logger.init_app(app)

    # レスポンス後処理
    @app.after_request
    def apply_security(response: Response) -> Response:
        response = add_security_headers(response)
        response = handle_cors(response)
        return response

    # OPTIONSリクエストのハンドリング（CORS preflight）
    @app.before_request
    def handle_preflight() -> Response | None:
        if request.method == "OPTIONS":
            response = Response()
            response = handle_cors(response)
            return response
        return None

    # リクエストIDの設定
    @app.before_request
    def set_request_id() -> None:
        request_id = request.headers.get("X-Request-ID", secrets.token_hex(8))
        g.request_id = request_id

    # リクエストIDをレスポンスに追加
    @app.after_request
    def add_request_id(response: Response) -> Response:
        if hasattr(g, "request_id"):
            response.headers["X-Request-ID"] = g.request_id
        return response

    logger.info("Security module initialized")


# ============================================================================
# Utility Functions
# ============================================================================


def generate_api_key() -> tuple[str, str]:
    """
    APIキーを生成。

    Returns:
        (平文キー, ハッシュ)のタプル
    """
    # プレフィックス + ランダム部分
    prefix = "m2x_"
    random_part = secrets.token_urlsafe(32)
    full_key = f"{prefix}{random_part}"

    # SHA-256ハッシュ
    key_hash = hashlib.sha256(full_key.encode()).hexdigest()

    return full_key, key_hash


def hash_api_key(api_key: str) -> str:
    """APIキーをハッシュ化。"""
    return hashlib.sha256(api_key.encode()).hexdigest()


def generate_secure_token(length: int = 32) -> str:
    """暗号学的に安全なトークンを生成。"""
    return secrets.token_urlsafe(length)


def constant_time_compare(a: str, b: str) -> bool:
    """タイミングセーフな文字列比較。"""
    return hmac.compare_digest(a, b)
