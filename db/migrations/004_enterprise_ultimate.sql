-- ============================================================================
-- M2X: エンタープライズ究極機能 - 完全なグローバル基準DB設計
-- ============================================================================
--
-- 【追加準拠規格】
-- - NIST SP 800-207 (Zero Trust Architecture)
-- - ISO 27018 (Cloud Privacy)
-- - ISO 22301:2019 (Business Continuity - Enhanced)
-- - MITRE ATT&CK Framework
-- - OWASP API Security Top 10
-- - EU AI Act (AI Governance)
-- - DORA (Digital Operational Resilience Act)
-- - ISO 27701 PIMS (Privacy Information Management)
--
-- 【このファイルの実装項目】
-- 1. Zero Trust Architecture
-- 2. 高度なIAM（PAM, JIT Access, Session Recording）
-- 3. API Security & Gateway Management
-- 4. 暗号学的監査証跡（不変性保証）
-- 5. イベントソーシング基盤
-- 6. マルチリージョン・データ主権
-- 7. キャパシティ計画・コスト管理
-- 8. リリース管理・Feature Flags
-- 9. MLOps・AIガバナンス
-- 10. 高度な可観測性（分散トレーシング、カオスエンジニアリング）
-- 11. コンプライアンス自動化
-- 12. サードパーティリスク管理
-- 13. ナレッジマネジメント
-- 14. PostgreSQL Row-Level Security実装
-- 15. 全文検索・地理空間サポート
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: Zero Trust Architecture (NIST SP 800-207)
-- ============================================================================

-- デバイス信頼レベル
CREATE TYPE device_trust_level AS ENUM (
    'untrusted',      -- 未検証デバイス
    'basic',          -- 基本認証済み
    'verified',       -- 検証済み（MDM登録等）
    'managed',        -- 完全管理下
    'privileged'      -- 特権デバイス
);

-- ネットワーク信頼レベル
CREATE TYPE network_trust_level AS ENUM (
    'untrusted',      -- パブリックネットワーク
    'semi_trusted',   -- VPN経由
    'trusted',        -- 社内ネットワーク
    'highly_trusted'  -- セキュアゾーン
);

-- デバイスインベントリ
CREATE TABLE device_inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,

    -- デバイス識別
    device_fingerprint VARCHAR(512) NOT NULL,
    device_name VARCHAR(255),
    device_type VARCHAR(50),  -- 'desktop', 'laptop', 'mobile', 'tablet', 'iot'
    os_type VARCHAR(50),
    os_version VARCHAR(100),

    -- セキュリティ状態
    trust_level device_trust_level DEFAULT 'untrusted',
    is_mdm_enrolled BOOLEAN DEFAULT FALSE,
    is_encrypted BOOLEAN DEFAULT FALSE,
    has_screen_lock BOOLEAN DEFAULT FALSE,
    antivirus_status VARCHAR(50),
    last_patch_date DATE,

    -- 証明書
    certificate_thumbprint VARCHAR(128),
    certificate_expiry TIMESTAMP WITH TIME ZONE,

    -- 登録情報
    registered_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT TRUE,

    CONSTRAINT uq_device_fingerprint UNIQUE (tenant_id, device_fingerprint)
);

CREATE INDEX idx_device_inventory_user ON device_inventory(user_id);
CREATE INDEX idx_device_inventory_trust ON device_inventory(tenant_id, trust_level);

COMMENT ON TABLE device_inventory IS 'Zero Trust: デバイスインベントリ（NIST SP 800-207）';

-- 継続的認証セッション
CREATE TABLE continuous_auth_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id UUID REFERENCES device_inventory(id),

    -- セッション情報
    session_token_hash VARCHAR(512) NOT NULL,

    -- コンテキスト情報
    network_trust network_trust_level DEFAULT 'untrusted',
    ip_address INET,
    geolocation JSONB,  -- {"country": "JP", "city": "Tokyo", "lat": 35.6762, "lon": 139.6503}
    user_agent TEXT,

    -- リスクスコア（0-100、高いほど危険）
    risk_score INTEGER DEFAULT 0,
    risk_factors JSONB DEFAULT '[]',

    -- 認証強度
    auth_assurance_level INTEGER DEFAULT 1,  -- 1-4 (NIST SP 800-63-3)
    mfa_verified BOOLEAN DEFAULT FALSE,
    last_step_up_auth TIMESTAMP WITH TIME ZONE,

    -- セッション管理
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_activity_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    terminated_reason VARCHAR(100),

    -- 行動分析
    typical_behavior_profile JSONB
);

CREATE INDEX idx_continuous_auth_user ON continuous_auth_sessions(user_id, is_active);
CREATE INDEX idx_continuous_auth_risk ON continuous_auth_sessions(risk_score DESC) WHERE is_active = TRUE;
CREATE INDEX idx_continuous_auth_expires ON continuous_auth_sessions(expires_at) WHERE is_active = TRUE;

COMMENT ON TABLE continuous_auth_sessions IS 'Zero Trust: 継続的認証セッション（リスクベース認証）';

-- マイクロセグメンテーションポリシー
CREATE TABLE network_segmentation_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- ポリシー定義
    policy_name VARCHAR(255) NOT NULL,
    description TEXT,

    -- ソース条件
    source_conditions JSONB NOT NULL,
    -- {"user_roles": ["admin"], "device_trust": ["managed"], "network": ["trusted"]}

    -- ターゲットリソース
    target_resources JSONB NOT NULL,
    -- {"service": "database", "actions": ["read", "write"]}

    -- アクセス決定
    decision VARCHAR(20) NOT NULL DEFAULT 'deny',  -- 'allow', 'deny', 'step_up_auth'
    step_up_requirements JSONB,  -- {"require_mfa": true, "require_device_check": true}

    -- 有効期間
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    valid_until TIMESTAMP WITH TIME ZONE,

    -- 監査
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID,
    is_active BOOLEAN DEFAULT TRUE,

    priority INTEGER DEFAULT 100  -- 低い数値が高優先
);

CREATE INDEX idx_network_seg_tenant ON network_segmentation_policies(tenant_id, is_active);

COMMENT ON TABLE network_segmentation_policies IS 'Zero Trust: マイクロセグメンテーションポリシー';

-- ============================================================================
-- SECTION 2: 高度なIAM（Privileged Access Management）
-- ============================================================================

-- 特権アクセス管理
CREATE TABLE privileged_access_management (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- アクセス対象
    resource_type VARCHAR(100) NOT NULL,  -- 'database', 'server', 'application', 'secret'
    resource_identifier VARCHAR(500) NOT NULL,

    -- アクセス設定
    access_level VARCHAR(50) NOT NULL,  -- 'read', 'write', 'admin', 'root'
    justification_required BOOLEAN DEFAULT TRUE,
    approval_required BOOLEAN DEFAULT TRUE,
    approval_workflow_id UUID,

    -- JIT（Just-In-Time）設定
    jit_enabled BOOLEAN DEFAULT TRUE,
    max_checkout_duration INTERVAL DEFAULT '4 hours',
    auto_revoke BOOLEAN DEFAULT TRUE,

    -- セッション記録
    session_recording_required BOOLEAN DEFAULT TRUE,
    keystroke_logging BOOLEAN DEFAULT FALSE,

    -- 認証要件
    require_mfa BOOLEAN DEFAULT TRUE,
    require_ticket_reference BOOLEAN DEFAULT FALSE,
    allowed_time_windows JSONB,  -- [{"day": "weekday", "start": "09:00", "end": "18:00"}]

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_pam_resource ON privileged_access_management(tenant_id, resource_type);

COMMENT ON TABLE privileged_access_management IS 'PAM: 特権アクセス管理設定';

-- JITアクセスリクエスト
CREATE TABLE jit_access_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    pam_policy_id UUID REFERENCES privileged_access_management(id),

    -- リクエスト者
    requester_id UUID NOT NULL REFERENCES users(id),

    -- リクエスト内容
    justification TEXT NOT NULL,
    ticket_reference VARCHAR(100),
    requested_duration INTERVAL NOT NULL,

    -- 承認状態
    status VARCHAR(20) DEFAULT 'pending',  -- 'pending', 'approved', 'rejected', 'expired', 'revoked'
    approved_by UUID REFERENCES users(id),
    approved_at TIMESTAMP WITH TIME ZONE,
    rejection_reason TEXT,

    -- アクセス期間
    access_starts_at TIMESTAMP WITH TIME ZONE,
    access_ends_at TIMESTAMP WITH TIME ZONE,

    -- 実際の使用
    checked_out_at TIMESTAMP WITH TIME ZONE,
    checked_in_at TIMESTAMP WITH TIME ZONE,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_jit_requester ON jit_access_requests(requester_id, status);
CREATE INDEX idx_jit_status ON jit_access_requests(status, access_ends_at);

COMMENT ON TABLE jit_access_requests IS 'JIT: Just-In-Timeアクセスリクエスト';

-- セッション記録
CREATE TABLE session_recordings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    jit_request_id UUID REFERENCES jit_access_requests(id),
    user_id UUID NOT NULL REFERENCES users(id),

    -- セッション情報
    session_start TIMESTAMP WITH TIME ZONE NOT NULL,
    session_end TIMESTAMP WITH TIME ZONE,
    duration_seconds INTEGER,

    -- 記録データ（実際はS3等に保存）
    recording_storage_path VARCHAR(1000),
    recording_size_bytes BIGINT,
    recording_format VARCHAR(50),  -- 'asciinema', 'video', 'keystroke'

    -- メタデータ
    commands_executed INTEGER DEFAULT 0,
    sensitive_actions_detected INTEGER DEFAULT 0,
    anomalies_detected JSONB DEFAULT '[]',

    -- 保持
    retention_until DATE,
    is_archived BOOLEAN DEFAULT FALSE,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_session_rec_user ON session_recordings(user_id, session_start DESC);
CREATE INDEX idx_session_rec_jit ON session_recordings(jit_request_id);

COMMENT ON TABLE session_recordings IS 'PAM: 特権セッション記録';

-- ============================================================================
-- SECTION 3: API Security & Gateway Management (OWASP API Security)
-- ============================================================================
-- Note: api_keys table is defined in 001_schema.sql

-- OAuth/OIDCクライアント設定
CREATE TABLE oauth_clients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- クライアント情報
    client_id VARCHAR(255) NOT NULL UNIQUE,
    client_secret_hash VARCHAR(512),  -- Confidentialクライアントのみ
    client_type VARCHAR(20) NOT NULL,  -- 'confidential', 'public'

    name VARCHAR(255) NOT NULL,
    description TEXT,
    logo_url VARCHAR(500),

    -- リダイレクトURI
    redirect_uris JSONB NOT NULL DEFAULT '[]',
    post_logout_redirect_uris JSONB DEFAULT '[]',

    -- スコープ
    allowed_scopes JSONB NOT NULL DEFAULT '["openid", "profile"]',
    default_scopes JSONB DEFAULT '["openid"]',

    -- グラント設定
    allowed_grant_types JSONB NOT NULL DEFAULT '["authorization_code"]',
    -- ["authorization_code", "refresh_token", "client_credentials", "device_code"]

    -- トークン設定
    access_token_ttl_seconds INTEGER DEFAULT 3600,
    refresh_token_ttl_seconds INTEGER DEFAULT 86400,
    id_token_ttl_seconds INTEGER DEFAULT 3600,

    -- PKCE
    require_pkce BOOLEAN DEFAULT TRUE,

    -- 状態
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_oauth_clients_tenant ON oauth_clients(tenant_id);

COMMENT ON TABLE oauth_clients IS 'OAuth 2.0/OIDCクライアント設定';

-- APIレート制限ログ
CREATE TABLE api_rate_limit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- 識別子
    client_identifier VARCHAR(255) NOT NULL,  -- API key prefix, client_id, or IP
    identifier_type VARCHAR(20) NOT NULL,     -- 'api_key', 'oauth_client', 'ip'

    -- エンドポイント
    endpoint VARCHAR(500) NOT NULL,
    method VARCHAR(10) NOT NULL,

    -- 制限情報
    window_start TIMESTAMP WITH TIME ZONE NOT NULL,
    request_count INTEGER NOT NULL,
    limit_exceeded BOOLEAN DEFAULT FALSE,

    -- 日時
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 時系列最適化
CREATE INDEX idx_rate_limit_client ON api_rate_limit_log(client_identifier, window_start DESC);
CREATE INDEX idx_rate_limit_time ON api_rate_limit_log USING BRIN (recorded_at);

COMMENT ON TABLE api_rate_limit_log IS 'APIレート制限ログ';

-- ============================================================================
-- SECTION 4: 暗号学的監査証跡（Cryptographic Audit Trail）
-- ============================================================================

-- 不変監査ログ（Merkle Tree構造）
CREATE TABLE immutable_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- イベント情報
    sequence_number BIGSERIAL NOT NULL UNIQUE,  -- 順序保証用
    event_type VARCHAR(100) NOT NULL,
    event_timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- コンテキスト
    tenant_id UUID,
    user_id UUID,
    session_id UUID,

    -- イベントデータ
    event_data JSONB NOT NULL,

    -- 暗号学的整合性
    previous_hash VARCHAR(128),
    event_hash VARCHAR(128) NOT NULL,  -- SHA-512ハッシュ

    -- Merkle Tree
    merkle_leaf_hash VARCHAR(128) NOT NULL,
    merkle_root_hash VARCHAR(128),      -- ブロック確定時に設定
    block_number BIGINT,                -- ブロック番号
    block_timestamp TIMESTAMP WITH TIME ZONE,

    -- 署名（オプション）
    signature VARCHAR(1024),            -- 署名（HSM署名等）
    signature_algorithm VARCHAR(50),    -- 'ECDSA-P256', 'Ed25519'

    -- 検証
    is_verified BOOLEAN DEFAULT FALSE,
    verification_timestamp TIMESTAMP WITH TIME ZONE
);

-- 順序アクセス最適化
CREATE INDEX idx_immutable_audit_block ON immutable_audit_log(block_number, id);
CREATE INDEX idx_immutable_audit_tenant ON immutable_audit_log(tenant_id, event_timestamp DESC);
CREATE INDEX idx_immutable_audit_type ON immutable_audit_log(event_type, event_timestamp DESC);

COMMENT ON TABLE immutable_audit_log IS '暗号学的に保護された不変監査ログ（ブロックチェーン類似）';

-- 監査ログブロック
CREATE TABLE audit_log_blocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    block_number BIGSERIAL NOT NULL UNIQUE,

    -- ブロック情報
    previous_block_hash VARCHAR(128),
    merkle_root VARCHAR(128) NOT NULL,

    -- ブロック範囲
    first_event_id UUID NOT NULL,
    last_event_id UUID NOT NULL,
    event_count INTEGER NOT NULL,

    -- タイムスタンプ
    block_timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- ブロックハッシュ
    block_hash VARCHAR(128) NOT NULL,

    -- 署名（Timestamping Authority）
    tsa_signature VARCHAR(2048),
    tsa_timestamp TIMESTAMP WITH TIME ZONE,
    tsa_certificate_chain TEXT
);

COMMENT ON TABLE audit_log_blocks IS '監査ログブロック（不変性保証のためのブロック単位の封印）';

-- ============================================================================
-- SECTION 5: イベントソーシング基盤
-- ============================================================================

-- イベントストア
CREATE TABLE event_store (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sequence_number BIGSERIAL NOT NULL UNIQUE,

    -- 集約（Aggregate）
    aggregate_type VARCHAR(100) NOT NULL,  -- 'Task', 'Equipment', 'User'
    aggregate_id UUID NOT NULL,

    -- イベント
    event_type VARCHAR(100) NOT NULL,       -- 'TaskCreated', 'TaskStatusChanged'
    event_version INTEGER NOT NULL,         -- 集約のバージョン

    -- データ
    event_data JSONB NOT NULL,
    metadata JSONB DEFAULT '{}',

    -- コンテキスト
    tenant_id UUID,
    user_id UUID,
    correlation_id UUID,                    -- リクエスト追跡用
    causation_id UUID,                      -- 原因イベントID

    -- タイムスタンプ
    occurred_at TIMESTAMP WITH TIME ZONE NOT NULL,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_aggregate_version UNIQUE (aggregate_type, aggregate_id, event_version)
);

CREATE INDEX idx_event_store_aggregate ON event_store(aggregate_type, aggregate_id, event_version);
CREATE INDEX idx_event_store_type ON event_store(event_type, occurred_at DESC);
CREATE INDEX idx_event_store_correlation ON event_store(correlation_id);
CREATE INDEX idx_event_store_time ON event_store USING BRIN (occurred_at);

COMMENT ON TABLE event_store IS 'イベントソーシング: イベントストア';

-- スナップショット（パフォーマンス最適化）
CREATE TABLE event_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    aggregate_type VARCHAR(100) NOT NULL,
    aggregate_id UUID NOT NULL,

    -- スナップショット
    snapshot_version INTEGER NOT NULL,
    snapshot_data JSONB NOT NULL,

    -- メタデータ
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    events_since_snapshot INTEGER DEFAULT 0,

    CONSTRAINT uq_snapshot UNIQUE (aggregate_type, aggregate_id, snapshot_version)
);

CREATE INDEX idx_event_snapshots ON event_snapshots(aggregate_type, aggregate_id, snapshot_version DESC);

COMMENT ON TABLE event_snapshots IS 'イベントソーシング: 集約スナップショット';

-- ============================================================================
-- SECTION 6: マルチリージョン・データ主権
-- ============================================================================

-- データ主権地域
CREATE TABLE data_sovereignty_regions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- 地域情報
    region_code VARCHAR(20) NOT NULL UNIQUE,  -- 'eu', 'us', 'apac', 'jp'
    region_name VARCHAR(100) NOT NULL,

    -- 適用法規
    applicable_regulations JSONB NOT NULL,
    -- ["GDPR", "CCPA", "APPI", "PDPA"]

    -- データセンター情報
    data_centers JSONB NOT NULL,
    -- [{"code": "eu-west-1", "country": "IE", "provider": "AWS"}]

    -- 制約
    data_residency_required BOOLEAN DEFAULT FALSE,
    cross_border_transfer_allowed BOOLEAN DEFAULT TRUE,
    allowed_transfer_destinations JSONB,  -- ["eu", "adequacy_countries"]

    -- 暗号化要件
    encryption_at_rest_required BOOLEAN DEFAULT TRUE,
    encryption_in_transit_required BOOLEAN DEFAULT TRUE,
    key_residency_required BOOLEAN DEFAULT FALSE,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE data_sovereignty_regions IS 'データ主権地域定義';

-- テナントデータ配置
CREATE TABLE tenant_data_placement (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- プライマリリージョン
    primary_region_id UUID NOT NULL REFERENCES data_sovereignty_regions(id),

    -- レプリケーション
    replica_regions JSONB DEFAULT '[]',  -- リージョンIDのリスト
    replication_mode VARCHAR(20) DEFAULT 'async',  -- 'sync', 'async', 'none'

    -- データカテゴリ別配置
    data_placement_rules JSONB DEFAULT '{}',
    -- {"pii": {"regions": ["eu"], "encryption": "required"}, "analytics": {"regions": ["*"]}}

    -- クロスボーダー転送
    cross_border_transfers_enabled BOOLEAN DEFAULT FALSE,
    transfer_impact_assessment_completed BOOLEAN DEFAULT FALSE,
    standard_contractual_clauses_signed BOOLEAN DEFAULT FALSE,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_tenant_placement UNIQUE (tenant_id)
);

CREATE INDEX idx_tenant_placement_region ON tenant_data_placement(primary_region_id);

COMMENT ON TABLE tenant_data_placement IS 'テナントデータ配置設定（データ主権対応）';

-- ============================================================================
-- SECTION 7: キャパシティ計画・コスト管理
-- ============================================================================

-- リソース使用量メトリクス
CREATE TABLE resource_usage_metrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- 計測期間
    period_start TIMESTAMP WITH TIME ZONE NOT NULL,
    period_end TIMESTAMP WITH TIME ZONE NOT NULL,
    granularity VARCHAR(20) NOT NULL,  -- 'hourly', 'daily', 'monthly'

    -- コンピュート
    cpu_hours DECIMAL(15,4),
    memory_gb_hours DECIMAL(15,4),

    -- ストレージ
    storage_gb DECIMAL(15,4),
    storage_iops BIGINT,

    -- ネットワーク
    bandwidth_gb_in DECIMAL(15,4),
    bandwidth_gb_out DECIMAL(15,4),

    -- API
    api_calls BIGINT,
    api_errors BIGINT,

    -- データベース
    db_connections_peak INTEGER,
    db_queries BIGINT,
    db_storage_gb DECIMAL(15,4),

    -- カスタムメトリクス
    custom_metrics JSONB DEFAULT '{}',

    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_resource_usage_tenant ON resource_usage_metrics(tenant_id, period_start DESC);
CREATE INDEX idx_resource_usage_period ON resource_usage_metrics USING BRIN (period_start);

COMMENT ON TABLE resource_usage_metrics IS 'リソース使用量メトリクス（キャパシティ計画用）';

-- コスト配分・チャージバック
CREATE TABLE cost_allocation (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- 請求期間
    billing_period_start DATE NOT NULL,
    billing_period_end DATE NOT NULL,

    -- コスト項目
    cost_category VARCHAR(100) NOT NULL,  -- 'compute', 'storage', 'network', 'api', 'support'
    cost_subcategory VARCHAR(100),

    -- 使用量
    usage_quantity DECIMAL(15,4),
    usage_unit VARCHAR(50),

    -- コスト
    unit_cost DECIMAL(15,6),
    total_cost DECIMAL(15,2) NOT NULL,
    currency VARCHAR(3) NOT NULL DEFAULT 'USD',

    -- 配分
    allocation_method VARCHAR(50),  -- 'direct', 'proportional', 'fixed'
    allocation_percentage DECIMAL(5,2),

    -- 予算
    budget_id UUID,
    budget_consumed_percentage DECIMAL(5,2),

    -- メタデータ
    tags JSONB DEFAULT '{}',

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_cost_allocation UNIQUE (tenant_id, billing_period_start, cost_category, cost_subcategory)
);

CREATE INDEX idx_cost_allocation_tenant ON cost_allocation(tenant_id, billing_period_start DESC);
CREATE INDEX idx_cost_allocation_category ON cost_allocation(cost_category);

COMMENT ON TABLE cost_allocation IS 'コスト配分・チャージバック';

-- 予算管理
CREATE TABLE budgets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- 予算情報
    budget_name VARCHAR(255) NOT NULL,
    description TEXT,

    -- 期間
    budget_type VARCHAR(20) NOT NULL,  -- 'monthly', 'quarterly', 'annual'
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,

    -- 金額
    total_amount DECIMAL(15,2) NOT NULL,
    currency VARCHAR(3) NOT NULL DEFAULT 'USD',

    -- カテゴリ別配分
    category_allocations JSONB DEFAULT '{}',
    -- {"compute": 5000, "storage": 2000, "network": 1000}

    -- アラート
    alert_thresholds JSONB DEFAULT '[50, 80, 90, 100]',
    alert_recipients JSONB DEFAULT '[]',

    -- 現在の状態
    current_spend DECIMAL(15,2) DEFAULT 0,
    forecast_spend DECIMAL(15,2),

    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_budgets_tenant ON budgets(tenant_id, is_active);

COMMENT ON TABLE budgets IS '予算管理';

-- ============================================================================
-- SECTION 8: リリース管理・Feature Flags
-- ============================================================================

-- Feature Flags
CREATE TABLE feature_flags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- フラグ情報
    flag_key VARCHAR(100) NOT NULL UNIQUE,
    flag_name VARCHAR(255) NOT NULL,
    description TEXT,

    -- デフォルト状態
    is_enabled BOOLEAN DEFAULT FALSE,

    -- ターゲティング
    targeting_rules JSONB DEFAULT '[]',
    -- [{"condition": {"tenant_id": "xxx"}, "variation": true}, {"condition": {"user_role": "admin"}, "variation": true}]

    -- バリエーション（A/Bテスト用）
    variations JSONB DEFAULT '{"on": true, "off": false}',
    default_variation VARCHAR(100) DEFAULT 'off',

    -- ロールアウト
    rollout_percentage INTEGER DEFAULT 0,  -- 0-100
    rollout_strategy VARCHAR(50) DEFAULT 'random',  -- 'random', 'user_id_hash', 'gradual'

    -- スケジュール
    scheduled_enable_at TIMESTAMP WITH TIME ZONE,
    scheduled_disable_at TIMESTAMP WITH TIME ZONE,

    -- メタデータ
    tags JSONB DEFAULT '[]',
    owner VARCHAR(255),

    -- 監査
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID,
    last_modified_by UUID,

    -- 状態
    is_archived BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_feature_flags_key ON feature_flags(flag_key) WHERE is_archived = FALSE;
CREATE INDEX idx_feature_flags_tags ON feature_flags USING GIN (tags);

COMMENT ON TABLE feature_flags IS 'Feature Flags（機能フラグ管理）';

-- Feature Flag評価ログ
CREATE TABLE feature_flag_evaluations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    flag_id UUID NOT NULL REFERENCES feature_flags(id),

    -- コンテキスト
    tenant_id UUID,
    user_id UUID,
    session_id UUID,

    -- 評価結果
    variation_key VARCHAR(100) NOT NULL,
    variation_value JSONB NOT NULL,

    -- 評価理由
    evaluation_reason VARCHAR(50),  -- 'targeting_match', 'rollout', 'default'
    matched_rule_index INTEGER,

    evaluated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- パーティショニング用（日次）
CREATE INDEX idx_ff_eval_flag ON feature_flag_evaluations(flag_id, evaluated_at DESC);
CREATE INDEX idx_ff_eval_time ON feature_flag_evaluations USING BRIN (evaluated_at);

COMMENT ON TABLE feature_flag_evaluations IS 'Feature Flag評価ログ';

-- リリース管理
CREATE TABLE releases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- リリース情報
    version VARCHAR(50) NOT NULL,
    release_name VARCHAR(255),
    description TEXT,
    release_notes TEXT,

    -- タイプ
    release_type VARCHAR(50) NOT NULL,  -- 'major', 'minor', 'patch', 'hotfix'

    -- 状態
    status VARCHAR(50) DEFAULT 'draft',  -- 'draft', 'scheduled', 'in_progress', 'completed', 'rolled_back'

    -- スケジュール
    scheduled_at TIMESTAMP WITH TIME ZONE,
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,

    -- デプロイメント
    deployment_strategy VARCHAR(50) DEFAULT 'rolling',  -- 'rolling', 'blue_green', 'canary'
    canary_percentage INTEGER,
    rollback_on_failure BOOLEAN DEFAULT TRUE,

    -- 関連Feature Flags
    associated_feature_flags JSONB DEFAULT '[]',

    -- 承認
    requires_approval BOOLEAN DEFAULT TRUE,
    approved_by UUID,
    approved_at TIMESTAMP WITH TIME ZONE,

    -- メタデータ
    git_commit_sha VARCHAR(50),
    git_branch VARCHAR(255),
    build_number VARCHAR(100),

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID
);

CREATE INDEX idx_releases_version ON releases(version);
CREATE INDEX idx_releases_status ON releases(status, scheduled_at);

COMMENT ON TABLE releases IS 'リリース管理';

-- ============================================================================
-- SECTION 9: MLOps・AIガバナンス（EU AI Act対応）
-- ============================================================================

-- AIモデルレジストリ
CREATE TABLE ai_model_registry (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- モデル情報
    model_name VARCHAR(255) NOT NULL,
    model_version VARCHAR(50) NOT NULL,
    model_type VARCHAR(100),  -- 'classification', 'regression', 'nlp', 'computer_vision'

    -- リスク分類（EU AI Act）
    ai_act_risk_level VARCHAR(50),  -- 'unacceptable', 'high', 'limited', 'minimal'
    risk_assessment_completed BOOLEAN DEFAULT FALSE,

    -- モデルアーティファクト
    artifact_path VARCHAR(1000),
    artifact_hash VARCHAR(128),
    framework VARCHAR(100),  -- 'tensorflow', 'pytorch', 'scikit-learn'

    -- トレーニング情報
    training_dataset_id UUID,
    training_started_at TIMESTAMP WITH TIME ZONE,
    training_completed_at TIMESTAMP WITH TIME ZONE,
    training_metrics JSONB,
    -- {"accuracy": 0.95, "f1_score": 0.93, "auc": 0.97}

    -- バリデーション
    validation_dataset_id UUID,
    validation_metrics JSONB,

    -- 説明可能性
    explainability_method VARCHAR(100),  -- 'SHAP', 'LIME', 'Integrated Gradients'
    feature_importance JSONB,

    -- バイアス検出
    bias_metrics JSONB,
    fairness_assessment_completed BOOLEAN DEFAULT FALSE,

    -- ステータス
    status VARCHAR(50) DEFAULT 'development',  -- 'development', 'staging', 'production', 'deprecated'
    approved_for_production BOOLEAN DEFAULT FALSE,
    approved_by UUID,
    approved_at TIMESTAMP WITH TIME ZONE,

    -- ライフサイクル
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deprecated_at TIMESTAMP WITH TIME ZONE,

    CONSTRAINT uq_model_version UNIQUE (tenant_id, model_name, model_version)
);

CREATE INDEX idx_ai_model_tenant ON ai_model_registry(tenant_id);
CREATE INDEX idx_ai_model_status ON ai_model_registry(status);

COMMENT ON TABLE ai_model_registry IS 'AIモデルレジストリ（EU AI Act対応）';

-- AI推論ログ
CREATE TABLE ai_inference_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    model_id UUID NOT NULL REFERENCES ai_model_registry(id),
    tenant_id UUID,
    user_id UUID,

    -- リクエスト
    request_id UUID NOT NULL,
    input_data_hash VARCHAR(128),  -- 入力データのハッシュ（再現性用）
    input_features JSONB,          -- 匿名化された特徴量

    -- 推論結果
    prediction JSONB NOT NULL,
    confidence_score DECIMAL(5,4),

    -- 説明
    explanation JSONB,

    -- パフォーマンス
    inference_time_ms INTEGER,

    -- フィードバック
    human_feedback VARCHAR(50),  -- 'correct', 'incorrect', 'uncertain'
    feedback_timestamp TIMESTAMP WITH TIME ZONE,

    -- 監査
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_ai_inference_model ON ai_inference_log(model_id, created_at DESC);
CREATE INDEX idx_ai_inference_time ON ai_inference_log USING BRIN (created_at);

COMMENT ON TABLE ai_inference_log IS 'AI推論ログ（監査・モニタリング用）';

-- データセット管理
CREATE TABLE ml_datasets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- データセット情報
    dataset_name VARCHAR(255) NOT NULL,
    dataset_version VARCHAR(50) NOT NULL,
    description TEXT,

    -- タイプ
    dataset_type VARCHAR(50),  -- 'training', 'validation', 'test', 'production'

    -- メタデータ
    record_count BIGINT,
    feature_count INTEGER,
    feature_schema JSONB,

    -- ストレージ
    storage_path VARCHAR(1000),
    storage_format VARCHAR(50),  -- 'parquet', 'csv', 'tfrecord'
    size_bytes BIGINT,

    -- リネージ
    source_datasets JSONB DEFAULT '[]',
    transformation_pipeline_id UUID,

    -- 品質
    data_quality_score DECIMAL(5,2),
    quality_issues JSONB DEFAULT '[]',

    -- プライバシー
    contains_pii BOOLEAN DEFAULT FALSE,
    anonymization_method VARCHAR(100),
    privacy_impact_assessment_id UUID,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID,

    CONSTRAINT uq_dataset_version UNIQUE (tenant_id, dataset_name, dataset_version)
);

CREATE INDEX idx_ml_datasets_tenant ON ml_datasets(tenant_id);

COMMENT ON TABLE ml_datasets IS 'MLデータセット管理';

-- ============================================================================
-- SECTION 10: 高度な可観測性（Distributed Tracing, Chaos Engineering）
-- ============================================================================

-- 分散トレース
CREATE TABLE distributed_traces (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- トレース識別
    trace_id VARCHAR(64) NOT NULL,
    span_id VARCHAR(32) NOT NULL,
    parent_span_id VARCHAR(32),

    -- オペレーション
    operation_name VARCHAR(255) NOT NULL,
    service_name VARCHAR(100) NOT NULL,

    -- タイミング
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE,
    duration_ms INTEGER,

    -- コンテキスト
    tenant_id UUID,
    user_id UUID,

    -- タグ・ログ
    tags JSONB DEFAULT '{}',
    logs JSONB DEFAULT '[]',

    -- ステータス
    status_code VARCHAR(20),  -- 'OK', 'ERROR', 'UNSET'
    error_message TEXT,

    -- バゲージ（コンテキスト伝播）
    baggage JSONB DEFAULT '{}'
);

-- 時系列クエリ最適化
CREATE INDEX idx_traces_trace_id ON distributed_traces(trace_id, start_time);
CREATE INDEX idx_traces_service ON distributed_traces(service_name, start_time DESC);
CREATE INDEX idx_traces_time ON distributed_traces USING BRIN (start_time);
CREATE INDEX idx_traces_error ON distributed_traces(service_name, start_time DESC) WHERE status_code = 'ERROR';

COMMENT ON TABLE distributed_traces IS '分散トレーシング（OpenTelemetry対応）';

-- カオスエンジニアリング実験
CREATE TABLE chaos_experiments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- 実験情報
    experiment_name VARCHAR(255) NOT NULL,
    description TEXT,
    hypothesis TEXT NOT NULL,

    -- ターゲット
    target_service VARCHAR(100) NOT NULL,
    target_environment VARCHAR(50) NOT NULL,  -- 'staging', 'production'

    -- 故障注入タイプ
    fault_type VARCHAR(100) NOT NULL,
    -- 'latency', 'error', 'resource_stress', 'network_partition', 'instance_termination'

    fault_configuration JSONB NOT NULL,
    -- {"latency_ms": 500, "percentage": 10} or {"error_code": 500, "percentage": 5}

    -- セーフティ
    blast_radius VARCHAR(50),  -- 'single_instance', 'percentage', 'full'
    abort_conditions JSONB DEFAULT '[]',
    -- [{"metric": "error_rate", "threshold": 0.1, "operator": ">"}]

    rollback_procedure TEXT,

    -- スケジュール
    scheduled_at TIMESTAMP WITH TIME ZONE,
    started_at TIMESTAMP WITH TIME ZONE,
    ended_at TIMESTAMP WITH TIME ZONE,
    duration_seconds INTEGER,

    -- 結果
    status VARCHAR(50) DEFAULT 'draft',  -- 'draft', 'scheduled', 'running', 'completed', 'aborted'
    hypothesis_validated BOOLEAN,
    findings TEXT,
    metrics_during_experiment JSONB,

    -- 承認
    approved_by UUID,
    approved_at TIMESTAMP WITH TIME ZONE,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID
);

CREATE INDEX idx_chaos_exp_tenant ON chaos_experiments(tenant_id);
CREATE INDEX idx_chaos_exp_status ON chaos_experiments(status);

COMMENT ON TABLE chaos_experiments IS 'カオスエンジニアリング実験管理';

-- ============================================================================
-- SECTION 11: コンプライアンス自動化
-- ============================================================================

-- コンプライアンスフレームワーク
CREATE TABLE compliance_frameworks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- フレームワーク情報
    framework_code VARCHAR(50) NOT NULL UNIQUE,  -- 'ISO27001', 'SOC2', 'GDPR'
    framework_name VARCHAR(255) NOT NULL,
    version VARCHAR(50),

    -- メタデータ
    description TEXT,
    governing_body VARCHAR(255),
    official_url VARCHAR(500),

    -- 構造
    control_count INTEGER,

    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE compliance_frameworks IS 'コンプライアンスフレームワーク定義';

-- コンプライアンスコントロール
CREATE TABLE compliance_controls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    framework_id UUID NOT NULL REFERENCES compliance_frameworks(id),

    -- コントロール識別
    control_id VARCHAR(100) NOT NULL,  -- 'A.5.1.1', 'CC1.1'
    control_name VARCHAR(500) NOT NULL,

    -- 階層
    parent_control_id UUID REFERENCES compliance_controls(id),

    -- 詳細
    description TEXT,
    implementation_guidance TEXT,

    -- カテゴリ
    control_type VARCHAR(50),  -- 'preventive', 'detective', 'corrective'
    control_category VARCHAR(100),

    -- 自動化
    can_be_automated BOOLEAN DEFAULT FALSE,
    automation_query TEXT,  -- 自動チェック用クエリ

    CONSTRAINT uq_framework_control UNIQUE (framework_id, control_id)
);

CREATE INDEX idx_compliance_controls_framework ON compliance_controls(framework_id);

COMMENT ON TABLE compliance_controls IS 'コンプライアンスコントロール定義';

-- コンプライアンスエビデンス
CREATE TABLE compliance_evidence (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    control_id UUID NOT NULL REFERENCES compliance_controls(id),

    -- エビデンス情報
    evidence_type VARCHAR(100) NOT NULL,  -- 'screenshot', 'log', 'report', 'configuration', 'attestation'
    evidence_title VARCHAR(500) NOT NULL,
    description TEXT,

    -- ストレージ
    storage_path VARCHAR(1000),
    file_hash VARCHAR(128),

    -- 有効期間
    collection_date DATE NOT NULL,
    valid_from DATE,
    valid_until DATE,

    -- ステータス
    status VARCHAR(50) DEFAULT 'draft',  -- 'draft', 'submitted', 'approved', 'rejected'
    reviewed_by UUID,
    reviewed_at TIMESTAMP WITH TIME ZONE,
    review_notes TEXT,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID
);

CREATE INDEX idx_compliance_evidence_tenant ON compliance_evidence(tenant_id);
CREATE INDEX idx_compliance_evidence_control ON compliance_evidence(control_id);

COMMENT ON TABLE compliance_evidence IS 'コンプライアンスエビデンス';

-- コンプライアンス評価
CREATE TABLE compliance_assessments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    framework_id UUID NOT NULL REFERENCES compliance_frameworks(id),

    -- 評価情報
    assessment_name VARCHAR(255) NOT NULL,
    assessment_type VARCHAR(50),  -- 'self', 'internal_audit', 'external_audit'

    -- 期間
    assessment_period_start DATE NOT NULL,
    assessment_period_end DATE NOT NULL,

    -- 結果
    overall_score DECIMAL(5,2),
    compliance_percentage DECIMAL(5,2),

    -- 詳細
    findings_summary TEXT,
    total_controls INTEGER,
    compliant_controls INTEGER,
    non_compliant_controls INTEGER,
    not_applicable_controls INTEGER,

    -- ステータス
    status VARCHAR(50) DEFAULT 'in_progress',  -- 'planning', 'in_progress', 'completed', 'archived'
    completed_at TIMESTAMP WITH TIME ZONE,

    -- レポート
    report_path VARCHAR(1000),

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID
);

CREATE INDEX idx_compliance_assessment_tenant ON compliance_assessments(tenant_id);

COMMENT ON TABLE compliance_assessments IS 'コンプライアンス評価';

-- ============================================================================
-- SECTION 12: サードパーティリスク管理
-- ============================================================================

-- ベンダーレジストリ
CREATE TABLE vendor_registry (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- ベンダー情報
    vendor_name VARCHAR(255) NOT NULL,
    vendor_type VARCHAR(100),  -- 'saas', 'infrastructure', 'consulting', 'data_processor'

    -- 連絡先
    primary_contact_name VARCHAR(255),
    primary_contact_email VARCHAR(255),
    website VARCHAR(500),

    -- 契約
    contract_start_date DATE,
    contract_end_date DATE,
    contract_value DECIMAL(15,2),
    contract_currency VARCHAR(3),

    -- リスク分類
    criticality_level VARCHAR(20),  -- 'critical', 'high', 'medium', 'low'
    data_access_level VARCHAR(50),  -- 'none', 'metadata_only', 'customer_data', 'sensitive_data'

    -- コンプライアンス
    certifications JSONB DEFAULT '[]',  -- ["ISO27001", "SOC2", "GDPR"]
    last_security_assessment DATE,
    security_score DECIMAL(5,2),

    -- ステータス
    status VARCHAR(50) DEFAULT 'active',  -- 'prospective', 'active', 'under_review', 'terminated'

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_vendor_tenant ON vendor_registry(tenant_id);
CREATE INDEX idx_vendor_criticality ON vendor_registry(criticality_level);

COMMENT ON TABLE vendor_registry IS 'ベンダーレジストリ（サードパーティリスク管理）';

-- ベンダーセキュリティ評価
CREATE TABLE vendor_security_assessments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_id UUID NOT NULL REFERENCES vendor_registry(id),

    -- 評価情報
    assessment_type VARCHAR(100),  -- 'questionnaire', 'penetration_test', 'audit', 'site_visit'
    assessment_date DATE NOT NULL,

    -- 結果
    overall_score DECIMAL(5,2),
    risk_rating VARCHAR(20),  -- 'critical', 'high', 'medium', 'low', 'minimal'

    -- 詳細スコア
    category_scores JSONB DEFAULT '{}',
    -- {"access_control": 85, "encryption": 90, "incident_response": 75}

    -- 発見事項
    findings JSONB DEFAULT '[]',
    -- [{"severity": "high", "finding": "...", "recommendation": "..."}]

    -- 是正措置
    remediation_required BOOLEAN DEFAULT FALSE,
    remediation_due_date DATE,
    remediation_completed_date DATE,

    -- レポート
    report_path VARCHAR(1000),

    -- 有効期限
    valid_until DATE,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID
);

CREATE INDEX idx_vendor_assessment_vendor ON vendor_security_assessments(vendor_id);

COMMENT ON TABLE vendor_security_assessments IS 'ベンダーセキュリティ評価';

-- ============================================================================
-- SECTION 13: ナレッジマネジメント
-- ============================================================================

-- ランブック
CREATE TABLE runbooks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- ランブック情報
    title VARCHAR(500) NOT NULL,
    description TEXT,

    -- カテゴリ
    category VARCHAR(100),  -- 'incident_response', 'maintenance', 'deployment', 'troubleshooting'
    tags JSONB DEFAULT '[]',

    -- 関連サービス
    related_services JSONB DEFAULT '[]',

    -- コンテンツ
    content_markdown TEXT NOT NULL,

    -- バージョン
    version INTEGER DEFAULT 1,

    -- ステータス
    status VARCHAR(50) DEFAULT 'draft',  -- 'draft', 'review', 'published', 'archived'
    published_at TIMESTAMP WITH TIME ZONE,

    -- 使用統計
    use_count INTEGER DEFAULT 0,
    last_used_at TIMESTAMP WITH TIME ZONE,

    -- メンテナンス
    review_due_date DATE,
    last_reviewed_at TIMESTAMP WITH TIME ZONE,
    reviewed_by UUID,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID
);

CREATE INDEX idx_runbooks_tenant ON runbooks(tenant_id);
CREATE INDEX idx_runbooks_category ON runbooks(category);
CREATE INDEX idx_runbooks_tags ON runbooks USING GIN (tags);

COMMENT ON TABLE runbooks IS 'ランブック（運用手順書）';

-- インシデントプレイブック
CREATE TABLE incident_playbooks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- プレイブック情報
    playbook_name VARCHAR(255) NOT NULL,
    description TEXT,

    -- トリガー条件
    trigger_conditions JSONB NOT NULL,
    -- {"incident_type": "security_breach", "severity": ["critical", "high"]}

    -- ステップ
    steps JSONB NOT NULL,
    -- [{"order": 1, "action": "...", "responsible_role": "...", "automation_id": null}]

    -- エスカレーション
    escalation_rules JSONB DEFAULT '[]',
    -- [{"condition": "no_response_15min", "escalate_to": "manager"}]

    -- 自動化
    automation_enabled BOOLEAN DEFAULT FALSE,
    automation_percentage INTEGER DEFAULT 0,  -- 自動化されたステップの割合

    -- 統計
    times_executed INTEGER DEFAULT 0,
    avg_resolution_time_minutes INTEGER,
    success_rate DECIMAL(5,2),

    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_playbooks_tenant ON incident_playbooks(tenant_id);

COMMENT ON TABLE incident_playbooks IS 'インシデントプレイブック';

-- ============================================================================
-- SECTION 14: PostgreSQL Row-Level Security実装
-- ============================================================================

-- RLSを有効化
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE parts ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- テナント分離ポリシー（tasks）
CREATE POLICY tenant_isolation_tasks ON tasks
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);

-- テナント分離ポリシー（equipments）
CREATE POLICY tenant_isolation_equipments ON equipments
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);

-- テナント分離ポリシー（parts）
CREATE POLICY tenant_isolation_parts ON parts
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);

-- テナント分離ポリシー（users）
CREATE POLICY tenant_isolation_users ON users
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);

COMMENT ON POLICY tenant_isolation_tasks ON tasks IS 'RLS: テナント分離';
COMMENT ON POLICY tenant_isolation_equipments ON equipments IS 'RLS: テナント分離';
COMMENT ON POLICY tenant_isolation_parts ON parts IS 'RLS: テナント分離';
COMMENT ON POLICY tenant_isolation_users ON users IS 'RLS: テナント分離';

-- ============================================================================
-- SECTION 15: 全文検索・地理空間サポート
-- ============================================================================

-- 全文検索用拡張
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- タスク全文検索インデックス
CREATE INDEX idx_tasks_fulltext ON tasks
    USING GIN (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, '')));

-- 設備全文検索インデックス
CREATE INDEX idx_equipments_fulltext ON equipments
    USING GIN (to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, '')));

-- 部品全文検索インデックス
CREATE INDEX idx_parts_fulltext ON parts
    USING GIN (to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, '')));

-- トライグラムインデックス（あいまい検索用）
CREATE INDEX idx_tasks_title_trgm ON tasks USING GIN (title gin_trgm_ops);
CREATE INDEX idx_equipments_name_trgm ON equipments USING GIN (name gin_trgm_ops);
CREATE INDEX idx_parts_name_trgm ON parts USING GIN (name gin_trgm_ops);

-- ============================================================================
-- SECTION 16: ヘルパー関数
-- ============================================================================

-- Zero Trust: デバイス信頼スコア計算
CREATE OR REPLACE FUNCTION calculate_device_trust_score(device_id UUID)
RETURNS INTEGER AS $$
DECLARE
    score INTEGER := 0;
    device RECORD;
BEGIN
    SELECT * INTO device FROM device_inventory WHERE id = device_id;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    -- 基本スコア
    IF device.is_mdm_enrolled THEN score := score + 30; END IF;
    IF device.is_encrypted THEN score := score + 20; END IF;
    IF device.has_screen_lock THEN score := score + 10; END IF;
    IF device.certificate_thumbprint IS NOT NULL THEN score := score + 20; END IF;
    IF device.last_patch_date >= CURRENT_DATE - INTERVAL '30 days' THEN score := score + 20; END IF;

    RETURN LEAST(score, 100);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION calculate_device_trust_score IS 'Zero Trust: デバイス信頼スコア計算';

-- セッションリスクスコア計算
CREATE OR REPLACE FUNCTION calculate_session_risk_score(session_id UUID)
RETURNS INTEGER AS $$
DECLARE
    risk_score INTEGER := 0;
    session RECORD;
    device RECORD;
BEGIN
    SELECT * INTO session FROM continuous_auth_sessions WHERE id = session_id;

    IF NOT FOUND THEN
        RETURN 100;  -- セッション不明は最高リスク
    END IF;

    -- ネットワークリスク
    CASE session.network_trust
        WHEN 'untrusted' THEN risk_score := risk_score + 30;
        WHEN 'semi_trusted' THEN risk_score := risk_score + 15;
        WHEN 'trusted' THEN risk_score := risk_score + 5;
        ELSE risk_score := risk_score + 0;
    END CASE;

    -- MFA未検証
    IF NOT session.mfa_verified THEN
        risk_score := risk_score + 25;
    END IF;

    -- デバイス信頼
    IF session.device_id IS NOT NULL THEN
        SELECT * INTO device FROM device_inventory WHERE id = session.device_id;
        IF device.trust_level = 'untrusted' THEN
            risk_score := risk_score + 30;
        ELSIF device.trust_level = 'basic' THEN
            risk_score := risk_score + 20;
        END IF;
    ELSE
        risk_score := risk_score + 35;  -- デバイス不明
    END IF;

    -- 長時間非アクティブ
    IF session.last_activity_at < NOW() - INTERVAL '30 minutes' THEN
        risk_score := risk_score + 15;
    END IF;

    RETURN LEAST(risk_score, 100);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION calculate_session_risk_score IS 'Zero Trust: セッションリスクスコア計算';

-- 全文検索関数
CREATE OR REPLACE FUNCTION search_tasks(
    p_tenant_id UUID,
    p_query TEXT,
    p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
    task_id UUID,
    title VARCHAR,
    description TEXT,
    relevance REAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.id,
        t.title,
        t.description,
        ts_rank(
            to_tsvector('english', coalesce(t.title, '') || ' ' || coalesce(t.description, '')),
            plainto_tsquery('english', p_query)
        ) as relevance
    FROM tasks t
    WHERE t.tenant_id = p_tenant_id
    AND to_tsvector('english', coalesce(t.title, '') || ' ' || coalesce(t.description, ''))
        @@ plainto_tsquery('english', p_query)
    ORDER BY relevance DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION search_tasks IS '全文検索: タスク検索';

-- Feature Flag評価関数
CREATE OR REPLACE FUNCTION evaluate_feature_flag(
    p_flag_key VARCHAR,
    p_tenant_id UUID DEFAULT NULL,
    p_user_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    flag RECORD;
    rule JSONB;
    variation_result JSONB;
BEGIN
    SELECT * INTO flag FROM feature_flags
    WHERE flag_key = p_flag_key AND is_archived = FALSE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('enabled', false, 'reason', 'flag_not_found');
    END IF;

    -- デフォルトが無効の場合
    IF NOT flag.is_enabled THEN
        RETURN jsonb_build_object('enabled', false, 'reason', 'flag_disabled');
    END IF;

    -- ターゲティングルールを評価
    FOR rule IN SELECT * FROM jsonb_array_elements(flag.targeting_rules)
    LOOP
        -- テナントマッチ
        IF rule->'condition'->>'tenant_id' IS NOT NULL
           AND rule->'condition'->>'tenant_id' = p_tenant_id::TEXT THEN
            RETURN jsonb_build_object(
                'enabled', true,
                'variation', rule->'variation',
                'reason', 'targeting_match'
            );
        END IF;
    END LOOP;

    -- ロールアウト率を評価
    IF flag.rollout_percentage > 0 THEN
        IF random() * 100 < flag.rollout_percentage THEN
            RETURN jsonb_build_object('enabled', true, 'reason', 'rollout');
        END IF;
    END IF;

    RETURN jsonb_build_object('enabled', flag.is_enabled, 'reason', 'default');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION evaluate_feature_flag IS 'Feature Flag評価';

-- ============================================================================
-- SECTION 17: 統合ダッシュボードビュー
-- ============================================================================

-- セキュリティ統合ダッシュボード
CREATE OR REPLACE VIEW v_security_posture_dashboard AS
SELECT
    t.id as tenant_id,
    t.name as tenant_name,

    -- Zero Trust メトリクス
    (SELECT COUNT(*) FROM device_inventory di WHERE di.tenant_id = t.id AND di.trust_level IN ('managed', 'privileged')) as trusted_devices,
    (SELECT COUNT(*) FROM device_inventory di WHERE di.tenant_id = t.id AND di.trust_level = 'untrusted') as untrusted_devices,
    (SELECT AVG(cas.risk_score) FROM continuous_auth_sessions cas WHERE cas.tenant_id = t.id AND cas.is_active = TRUE) as avg_session_risk,

    -- PAM メトリクス
    (SELECT COUNT(*) FROM jit_access_requests jar WHERE jar.tenant_id = t.id AND jar.status = 'pending') as pending_access_requests,

    -- API セキュリティ
    (SELECT COUNT(*) FROM api_keys ak WHERE ak.tenant_id = t.id AND ak.is_active = TRUE) as active_api_keys,

    -- コンプライアンス
    (SELECT AVG(ca.compliance_percentage) FROM compliance_assessments ca WHERE ca.tenant_id = t.id) as avg_compliance_score,

    -- ベンダーリスク
    (SELECT COUNT(*) FROM vendor_registry vr WHERE vr.tenant_id = t.id AND vr.criticality_level IN ('critical', 'high')) as high_risk_vendors

FROM tenants t;

COMMENT ON VIEW v_security_posture_dashboard IS 'セキュリティ態勢統合ダッシュボード';

-- オペレーション統合ダッシュボード
CREATE OR REPLACE VIEW v_operations_dashboard AS
SELECT
    t.id as tenant_id,
    t.name as tenant_name,

    -- リソース使用
    (SELECT SUM(rum.api_calls) FROM resource_usage_metrics rum
     WHERE rum.tenant_id = t.id
     AND rum.period_start >= CURRENT_DATE - INTERVAL '30 days') as api_calls_30d,

    -- コスト
    (SELECT SUM(ca.total_cost) FROM cost_allocation ca
     WHERE ca.tenant_id = t.id
     AND ca.billing_period_start >= DATE_TRUNC('month', CURRENT_DATE)) as mtd_cost,

    -- Feature Flags
    (SELECT COUNT(*) FROM feature_flags ff WHERE ff.is_enabled = TRUE AND ff.is_archived = FALSE) as active_feature_flags,

    -- リリース
    (SELECT COUNT(*) FROM releases r WHERE r.status = 'scheduled') as scheduled_releases,

    -- カオス実験
    (SELECT COUNT(*) FROM chaos_experiments ce WHERE ce.tenant_id = t.id AND ce.status = 'completed') as completed_experiments,

    -- ランブック
    (SELECT COUNT(*) FROM runbooks rb WHERE rb.tenant_id = t.id AND rb.status = 'published') as published_runbooks

FROM tenants t;

COMMENT ON VIEW v_operations_dashboard IS 'オペレーション統合ダッシュボード';

-- ============================================================================
-- 完了
-- ============================================================================

-- バージョン情報
INSERT INTO data_classification_rules (table_name, column_name, classification, encryption_required, min_role_required, created_by)
VALUES
    ('api_keys', 'key_hash', 'restricted', true, 'admin', NULL),
    ('session_recordings', 'recording_storage_path', 'confidential', true, 'admin', NULL),
    ('jit_access_requests', 'justification', 'internal', false, 'manager', NULL),
    ('ai_inference_log', 'input_features', 'confidential', true, 'viewer', NULL)
ON CONFLICT (table_name, column_name) DO NOTHING;

COMMENT ON SCHEMA public IS 'M2X Enterprise Ultimate Schema v2.0 - Global Standard Compliance';
