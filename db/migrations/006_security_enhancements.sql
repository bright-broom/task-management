-- ============================================================================
-- M2X: セキュリティ強化マイグレーション
-- ============================================================================
--
-- 【概要】
-- グローバル基準のセキュリティ要件に対応するためのDB拡張
--
-- 【実装項目】
-- 1. セキュリティイベントログテーブル
-- 2. APIキー管理テーブル
-- 3. セッション管理テーブル
-- 4. 失敗したログイン試行の追跡
-- 5. IPブロックリスト
-- 6. パスワードポリシー設定
--
-- 【準拠規格】
-- - OWASP Top 10
-- - NIST 800-63B (Digital Identity Guidelines)
-- - ISO 27001
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: セキュリティイベントタイプ
-- ============================================================================

CREATE TYPE security_event_type AS ENUM (
    -- 認証関連
    'login_success',
    'login_failure',
    'logout',
    'password_change',
    'password_reset_request',
    'password_reset_complete',
    'mfa_enabled',
    'mfa_disabled',
    'mfa_challenge_success',
    'mfa_challenge_failure',

    -- セッション関連
    'session_created',
    'session_expired',
    'session_revoked',
    'session_hijack_attempt',

    -- アカウント関連
    'account_created',
    'account_locked',
    'account_unlocked',
    'account_deleted',
    'role_changed',
    'permission_denied',

    -- API関連
    'api_key_created',
    'api_key_revoked',
    'api_key_used',
    'rate_limit_exceeded',

    -- データアクセス関連
    'sensitive_data_accessed',
    'bulk_data_export',
    'cross_tenant_attempt',

    -- 脅威検知
    'suspicious_activity',
    'brute_force_detected',
    'sql_injection_attempt',
    'xss_attempt',
    'csrf_violation'
);

COMMENT ON TYPE security_event_type IS 'セキュリティイベントの種類';

-- ============================================================================
-- SECTION 2: セキュリティイベントログテーブル
-- ============================================================================
-- 全てのセキュリティ関連イベントを記録する不変ログ

CREATE TABLE security_events (
    id BIGSERIAL PRIMARY KEY,

    -- イベント情報
    event_type security_event_type NOT NULL,
    event_time TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- 対象情報
    tenant_id UUID,
    user_id UUID,
    target_resource VARCHAR(255),  -- 例: "tasks", "users", etc.
    target_id UUID,

    -- リクエスト情報
    ip_address INET,
    user_agent TEXT,
    request_method VARCHAR(10),
    request_path TEXT,
    request_id UUID,

    -- イベント詳細
    details JSONB DEFAULT '{}',
    severity VARCHAR(20) DEFAULT 'info',  -- 'debug', 'info', 'warning', 'error', 'critical'

    -- 地理情報（オプション）
    geo_country VARCHAR(2),
    geo_city VARCHAR(100),

    -- パーティショニング用（トリガーで自動設定）
    year_month VARCHAR(7)
);

-- year_month自動設定トリガー
CREATE OR REPLACE FUNCTION set_security_event_year_month()
RETURNS TRIGGER AS $$
BEGIN
    NEW.year_month := TO_CHAR(NEW.event_time, 'YYYY-MM');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_security_events_year_month
    BEFORE INSERT ON security_events
    FOR EACH ROW EXECUTE FUNCTION set_security_event_year_month();

-- インデックス
CREATE INDEX idx_security_events_type ON security_events(event_type, event_time DESC);
CREATE INDEX idx_security_events_tenant ON security_events(tenant_id, event_time DESC);
CREATE INDEX idx_security_events_user ON security_events(user_id, event_time DESC);
CREATE INDEX idx_security_events_ip ON security_events(ip_address, event_time DESC);
CREATE INDEX idx_security_events_severity ON security_events(severity, event_time DESC) WHERE severity IN ('warning', 'error', 'critical');
CREATE INDEX idx_security_events_time ON security_events USING BRIN (event_time);
CREATE INDEX idx_security_events_year_month ON security_events(year_month);

-- セキュリティイベントは削除・変更不可
CREATE OR REPLACE FUNCTION prevent_security_event_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Security events cannot be modified or deleted (compliance requirement)';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER prevent_security_event_update
    BEFORE UPDATE OR DELETE ON security_events
    FOR EACH ROW EXECUTE FUNCTION prevent_security_event_modification();

COMMENT ON TABLE security_events IS 'セキュリティイベントログ（不変、コンプライアンス用）';

-- ============================================================================
-- SECTION 3: APIキー管理テーブル
-- ============================================================================

CREATE TABLE api_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,

    -- キー情報
    key_prefix VARCHAR(8) NOT NULL,  -- 表示用プレフィックス（例: "m2x_live"）
    key_hash VARCHAR(255) NOT NULL,  -- SHA-256ハッシュ
    name VARCHAR(255) NOT NULL,
    description TEXT,

    -- スコープと権限
    scopes TEXT[] DEFAULT ARRAY['read'],  -- 'read', 'write', 'admin'
    allowed_ips INET[],  -- IPホワイトリスト（空=全て許可）

    -- 使用状況
    last_used_at TIMESTAMP WITH TIME ZONE,
    last_used_ip INET,
    usage_count BIGINT DEFAULT 0,

    -- 有効期限
    expires_at TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT TRUE,

    -- 監査
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID,
    revoked_at TIMESTAMP WITH TIME ZONE,
    revoked_by UUID,
    revoke_reason TEXT,

    -- 制約
    CONSTRAINT chk_key_prefix_format CHECK (key_prefix ~ '^[a-z0-9_]+$')
);

-- インデックス
CREATE INDEX idx_api_keys_tenant ON api_keys(tenant_id);
CREATE INDEX idx_api_keys_user ON api_keys(user_id);
CREATE INDEX idx_api_keys_prefix ON api_keys(key_prefix);
CREATE INDEX idx_api_keys_active ON api_keys(tenant_id, is_active) WHERE is_active = TRUE;

-- RLS
ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;

CREATE POLICY api_keys_tenant_isolation ON api_keys
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

COMMENT ON TABLE api_keys IS 'APIキー管理テーブル';
COMMENT ON COLUMN api_keys.key_hash IS 'APIキーのSHA-256ハッシュ（平文は保存しない）';
COMMENT ON COLUMN api_keys.scopes IS '許可されたスコープ配列';

-- ============================================================================
-- SECTION 4: セッション管理テーブル
-- ============================================================================

CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- セッション情報
    session_token_hash VARCHAR(255) NOT NULL,  -- SHA-256ハッシュ
    refresh_token_hash VARCHAR(255),

    -- デバイス情報
    device_fingerprint VARCHAR(255),
    user_agent TEXT,
    ip_address INET,

    -- 有効期限
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    refresh_expires_at TIMESTAMP WITH TIME ZONE,

    -- ステータス
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_activity_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- 無効化情報
    revoked_at TIMESTAMP WITH TIME ZONE,
    revoke_reason VARCHAR(50),  -- 'logout', 'expired', 'security', 'admin'

    -- インデックス最適化
    CONSTRAINT uq_session_token UNIQUE (session_token_hash)
);

-- インデックス
CREATE INDEX idx_user_sessions_user ON user_sessions(user_id, is_active) WHERE is_active = TRUE;
CREATE INDEX idx_user_sessions_tenant ON user_sessions(tenant_id);
CREATE INDEX idx_user_sessions_expires ON user_sessions(expires_at) WHERE is_active = TRUE;
CREATE INDEX idx_user_sessions_token ON user_sessions(session_token_hash) WHERE is_active = TRUE;

-- RLS
ALTER TABLE user_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_sessions_tenant_isolation ON user_sessions
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- 期限切れセッションの自動無効化トリガー
CREATE OR REPLACE FUNCTION invalidate_expired_sessions()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_active = TRUE AND NEW.expires_at < CURRENT_TIMESTAMP THEN
        NEW.is_active := FALSE;
        NEW.revoked_at := CURRENT_TIMESTAMP;
        NEW.revoke_reason := 'expired';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_invalidate_expired_sessions
    BEFORE UPDATE ON user_sessions
    FOR EACH ROW EXECUTE FUNCTION invalidate_expired_sessions();

COMMENT ON TABLE user_sessions IS 'ユーザーセッション管理テーブル';

-- ============================================================================
-- SECTION 5: 失敗したログイン試行追跡
-- ============================================================================

CREATE TABLE failed_login_attempts (
    id BIGSERIAL PRIMARY KEY,
    tenant_id UUID,
    email VARCHAR(255),
    ip_address INET NOT NULL,
    user_agent TEXT,
    attempted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    failure_reason VARCHAR(50),  -- 'invalid_password', 'account_locked', 'account_not_found', 'mfa_failed'
    request_id UUID
);

-- インデックス
CREATE INDEX idx_failed_logins_ip ON failed_login_attempts(ip_address, attempted_at DESC);
CREATE INDEX idx_failed_logins_email ON failed_login_attempts(email, attempted_at DESC);
CREATE INDEX idx_failed_logins_time ON failed_login_attempts USING BRIN (attempted_at);

-- 古いレコードを自動削除（30日以上前）
CREATE OR REPLACE FUNCTION cleanup_old_failed_logins()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM failed_login_attempts
    WHERE attempted_at < CURRENT_TIMESTAMP - INTERVAL '30 days';

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON TABLE failed_login_attempts IS '失敗したログイン試行の追跡（ブルートフォース検出用）';

-- ============================================================================
-- SECTION 6: IPブロックリスト
-- ============================================================================

CREATE TABLE ip_blocklist (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ip_address INET NOT NULL,
    ip_range CIDR,  -- IPレンジでのブロック

    -- ブロック理由
    reason VARCHAR(50) NOT NULL,  -- 'brute_force', 'suspicious_activity', 'manual', 'abuse'
    details TEXT,

    -- 有効期限
    blocked_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE,  -- NULLは永久ブロック
    is_active BOOLEAN DEFAULT TRUE,

    -- 監査
    blocked_by UUID,
    unblocked_at TIMESTAMP WITH TIME ZONE,
    unblocked_by UUID,

    -- 制約
    CONSTRAINT chk_ip_or_range CHECK (ip_address IS NOT NULL OR ip_range IS NOT NULL)
);

-- インデックス
CREATE INDEX idx_ip_blocklist_address ON ip_blocklist(ip_address) WHERE is_active = TRUE;
CREATE INDEX idx_ip_blocklist_range ON ip_blocklist(ip_range) WHERE is_active = TRUE;
CREATE INDEX idx_ip_blocklist_expires ON ip_blocklist(expires_at) WHERE is_active = TRUE AND expires_at IS NOT NULL;

-- IPがブロックされているかチェックする関数
CREATE OR REPLACE FUNCTION is_ip_blocked(check_ip INET)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM ip_blocklist
        WHERE is_active = TRUE
          AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
          AND (
              ip_address = check_ip
              OR (ip_range IS NOT NULL AND check_ip << ip_range)
          )
    );
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON TABLE ip_blocklist IS 'IPブロックリスト';
COMMENT ON FUNCTION is_ip_blocked(INET) IS '指定IPがブロックされているかチェック';

-- ============================================================================
-- SECTION 7: パスワードポリシー設定
-- ============================================================================

CREATE TABLE password_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,  -- NULLはグローバルデフォルト

    -- 長さ要件
    min_length INTEGER NOT NULL DEFAULT 12,
    max_length INTEGER NOT NULL DEFAULT 128,

    -- 複雑性要件
    require_uppercase BOOLEAN DEFAULT TRUE,
    require_lowercase BOOLEAN DEFAULT TRUE,
    require_numbers BOOLEAN DEFAULT TRUE,
    require_special_chars BOOLEAN DEFAULT TRUE,
    special_chars_allowed VARCHAR(100) DEFAULT '!@#$%^&*()_+-=[]{}|;:,.<>?',

    -- パスワード履歴
    password_history_count INTEGER DEFAULT 5,  -- 過去N個のパスワードは再利用不可

    -- 有効期限
    max_age_days INTEGER DEFAULT 90,  -- 0は無期限
    warning_days_before_expiry INTEGER DEFAULT 14,

    -- ロックアウト
    max_failed_attempts INTEGER DEFAULT 5,
    lockout_duration_minutes INTEGER DEFAULT 30,

    -- MFA要件
    require_mfa BOOLEAN DEFAULT FALSE,
    mfa_grace_period_days INTEGER DEFAULT 7,

    -- 監査
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- 制約
    CONSTRAINT uq_password_policy_tenant UNIQUE (tenant_id),
    CONSTRAINT chk_min_length CHECK (min_length >= 8),
    CONSTRAINT chk_max_length CHECK (max_length <= 256 AND max_length >= min_length),
    CONSTRAINT chk_history_count CHECK (password_history_count >= 0 AND password_history_count <= 24),
    CONSTRAINT chk_max_age CHECK (max_age_days >= 0),
    CONSTRAINT chk_lockout CHECK (max_failed_attempts >= 1 AND lockout_duration_minutes >= 1)
);

-- デフォルトポリシーを挿入
INSERT INTO password_policies (tenant_id, min_length, require_mfa)
VALUES (NULL, 12, FALSE);

-- RLS
ALTER TABLE password_policies ENABLE ROW LEVEL SECURITY;

CREATE POLICY password_policies_tenant_isolation ON password_policies
    FOR ALL
    USING (tenant_id IS NULL OR tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

COMMENT ON TABLE password_policies IS 'テナント別パスワードポリシー設定';

-- ============================================================================
-- SECTION 8: パスワード履歴テーブル
-- ============================================================================

CREATE TABLE password_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- インデックス
CREATE INDEX idx_password_history_user ON password_history(user_id, created_at DESC);

COMMENT ON TABLE password_history IS 'パスワード履歴（再利用防止用）';

-- ============================================================================
-- SECTION 9: レート制限設定テーブル
-- ============================================================================

CREATE TABLE rate_limit_configs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,  -- NULLはグローバル

    -- エンドポイント設定
    endpoint_pattern VARCHAR(255) NOT NULL,  -- 例: '/api/tenants/*/tasks'
    http_method VARCHAR(10),  -- NULL = 全メソッド

    -- 制限設定
    requests_per_minute INTEGER DEFAULT 60,
    requests_per_hour INTEGER DEFAULT 1000,
    requests_per_day INTEGER DEFAULT 10000,

    -- バースト許容
    burst_size INTEGER DEFAULT 10,

    -- 有効フラグ
    is_active BOOLEAN DEFAULT TRUE,

    -- 監査
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- 制約
    CONSTRAINT uq_rate_limit_endpoint UNIQUE (tenant_id, endpoint_pattern, http_method)
);

-- デフォルトのグローバルレート制限を挿入
INSERT INTO rate_limit_configs (tenant_id, endpoint_pattern, requests_per_minute, requests_per_hour) VALUES
    (NULL, '/api/*', 60, 1000),
    (NULL, '/api/*/tasks', 30, 500),
    (NULL, '/health', 120, 3600);

COMMENT ON TABLE rate_limit_configs IS 'APIレート制限設定';

-- ============================================================================
-- SECTION 10: usersテーブルのセキュリティ拡張
-- ============================================================================

-- パスワード関連フィールドの追加（既存の場合はスキップ）
DO $$
BEGIN
    -- パスワード有効期限
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'password_expires_at') THEN
        ALTER TABLE users ADD COLUMN password_expires_at TIMESTAMP WITH TIME ZONE;
    END IF;

    -- MFAシークレット
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'mfa_secret') THEN
        ALTER TABLE users ADD COLUMN mfa_secret VARCHAR(255);
    END IF;

    -- MFA有効フラグ
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'mfa_enabled') THEN
        ALTER TABLE users ADD COLUMN mfa_enabled BOOLEAN DEFAULT FALSE;
    END IF;

    -- MFAバックアップコード
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'mfa_backup_codes') THEN
        ALTER TABLE users ADD COLUMN mfa_backup_codes TEXT[];
    END IF;

    -- メール確認済みフラグ
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'email_verified') THEN
        ALTER TABLE users ADD COLUMN email_verified BOOLEAN DEFAULT FALSE;
    END IF;

    -- メール確認トークン
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'email_verification_token') THEN
        ALTER TABLE users ADD COLUMN email_verification_token VARCHAR(255);
    END IF;

    -- パスワードリセットトークン
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'password_reset_token') THEN
        ALTER TABLE users ADD COLUMN password_reset_token VARCHAR(255);
    END IF;

    -- パスワードリセットトークン有効期限
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'password_reset_expires') THEN
        ALTER TABLE users ADD COLUMN password_reset_expires TIMESTAMP WITH TIME ZONE;
    END IF;

    -- 許可されたIPアドレス
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'allowed_ips') THEN
        ALTER TABLE users ADD COLUMN allowed_ips INET[];
    END IF;
END;
$$;

-- ============================================================================
-- SECTION 11: セキュリティヘルパー関数
-- ============================================================================

-- ブルートフォース検出関数
CREATE OR REPLACE FUNCTION check_brute_force(
    p_ip_address INET,
    p_email VARCHAR(255) DEFAULT NULL,
    p_window_minutes INTEGER DEFAULT 15,
    p_max_attempts INTEGER DEFAULT 5
) RETURNS BOOLEAN AS $$
DECLARE
    attempt_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO attempt_count
    FROM failed_login_attempts
    WHERE ip_address = p_ip_address
      AND attempted_at > CURRENT_TIMESTAMP - (p_window_minutes || ' minutes')::INTERVAL;

    IF attempt_count >= p_max_attempts THEN
        RETURN TRUE;  -- ブルートフォース検出
    END IF;

    -- メールベースのチェック
    IF p_email IS NOT NULL THEN
        SELECT COUNT(*) INTO attempt_count
        FROM failed_login_attempts
        WHERE email = p_email
          AND attempted_at > CURRENT_TIMESTAMP - (p_window_minutes || ' minutes')::INTERVAL;

        IF attempt_count >= p_max_attempts THEN
            RETURN TRUE;
        END IF;
    END IF;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION check_brute_force(INET, VARCHAR, INTEGER, INTEGER) IS 'ブルートフォース攻撃を検出';

-- セキュリティイベント記録関数
CREATE OR REPLACE FUNCTION log_security_event(
    p_event_type security_event_type,
    p_tenant_id UUID DEFAULT NULL,
    p_user_id UUID DEFAULT NULL,
    p_ip_address INET DEFAULT NULL,
    p_details JSONB DEFAULT '{}',
    p_severity VARCHAR(20) DEFAULT 'info'
) RETURNS BIGINT AS $$
DECLARE
    event_id BIGINT;
BEGIN
    INSERT INTO security_events (
        event_type, tenant_id, user_id, ip_address, details, severity
    ) VALUES (
        p_event_type, p_tenant_id, p_user_id, p_ip_address, p_details, p_severity
    )
    RETURNING id INTO event_id;

    RETURN event_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION log_security_event(security_event_type, UUID, UUID, INET, JSONB, VARCHAR) IS 'セキュリティイベントを記録';

-- アクティブセッション数取得
CREATE OR REPLACE FUNCTION get_active_session_count(p_user_id UUID)
RETURNS INTEGER AS $$
BEGIN
    RETURN (
        SELECT COUNT(*)
        FROM user_sessions
        WHERE user_id = p_user_id
          AND is_active = TRUE
          AND expires_at > CURRENT_TIMESTAMP
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- 古いセッションを無効化
CREATE OR REPLACE FUNCTION revoke_user_sessions(
    p_user_id UUID,
    p_reason VARCHAR(50) DEFAULT 'security',
    p_except_session_id UUID DEFAULT NULL
) RETURNS INTEGER AS $$
DECLARE
    revoked_count INTEGER;
BEGIN
    UPDATE user_sessions
    SET is_active = FALSE,
        revoked_at = CURRENT_TIMESTAMP,
        revoke_reason = p_reason
    WHERE user_id = p_user_id
      AND is_active = TRUE
      AND (p_except_session_id IS NULL OR id != p_except_session_id);

    GET DIAGNOSTICS revoked_count = ROW_COUNT;
    RETURN revoked_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION revoke_user_sessions(UUID, VARCHAR, UUID) IS 'ユーザーの全セッションを無効化';

-- ============================================================================
-- SECTION 12: セキュリティビュー
-- ============================================================================

-- 最近のセキュリティイベント
CREATE OR REPLACE VIEW v_recent_security_events AS
SELECT
    se.id,
    se.event_type,
    se.event_time,
    se.tenant_id,
    t.name AS tenant_name,
    se.user_id,
    u.display_name AS user_name,
    se.ip_address,
    se.severity,
    se.details
FROM security_events se
LEFT JOIN tenants t ON se.tenant_id = t.id
LEFT JOIN users u ON se.user_id = u.id
WHERE se.event_time > CURRENT_TIMESTAMP - INTERVAL '24 hours'
ORDER BY se.event_time DESC;

COMMENT ON VIEW v_recent_security_events IS '過去24時間のセキュリティイベント';

-- 失敗したログイン試行のサマリー
CREATE OR REPLACE VIEW v_failed_login_summary AS
SELECT
    ip_address,
    email,
    COUNT(*) AS attempt_count,
    MIN(attempted_at) AS first_attempt,
    MAX(attempted_at) AS last_attempt,
    ARRAY_AGG(DISTINCT failure_reason) AS failure_reasons
FROM failed_login_attempts
WHERE attempted_at > CURRENT_TIMESTAMP - INTERVAL '24 hours'
GROUP BY ip_address, email
HAVING COUNT(*) >= 3
ORDER BY attempt_count DESC;

COMMENT ON VIEW v_failed_login_summary IS '失敗したログイン試行のサマリー（3回以上）';

-- アクティブなブロック一覧
CREATE OR REPLACE VIEW v_active_blocks AS
SELECT
    id,
    ip_address,
    ip_range,
    reason,
    blocked_at,
    expires_at,
    CASE
        WHEN expires_at IS NULL THEN 'permanent'
        ELSE 'temporary'
    END AS block_type
FROM ip_blocklist
WHERE is_active = TRUE
  AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
ORDER BY blocked_at DESC;

COMMENT ON VIEW v_active_blocks IS '現在アクティブなIPブロック';

-- ============================================================================
-- 完了メッセージ
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE 'セキュリティ強化マイグレーション完了';
    RAISE NOTICE '- セキュリティイベントログ: 作成済';
    RAISE NOTICE '- APIキー管理: 作成済';
    RAISE NOTICE '- セッション管理: 作成済';
    RAISE NOTICE '- 失敗ログイン追跡: 作成済';
    RAISE NOTICE '- IPブロックリスト: 作成済';
    RAISE NOTICE '- パスワードポリシー: 作成済';
    RAISE NOTICE '- セキュリティヘルパー関数: 作成済';
END;
$$;
