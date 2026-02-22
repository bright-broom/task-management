-- ============================================================================
-- M2X課題: 工場向けタスク管理システム テーブル定義
-- ============================================================================
--
-- 【設計方針】
--
-- 1. マルチテナント対応
--    - 全テーブルに tenant_id を持たせ、論理的なデータ分離を実現
--    - 外部キー制約で親テーブルの tenant_id との整合性を保証
--    - インデックスは tenant_id を先頭に配置し、テナント単位のクエリを高速化
--
-- 2. UUID 主キー
--    - マルチテナント環境でのID衝突を回避
--    - 将来的なテナント間データ移行やシャーディングに対応しやすい
--    - gen_random_uuid() で自動生成（PostgreSQL 13+）
--
-- 3. EAV（Entity-Attribute-Value）パターン
--    - テナントごとに異なるカスタム入力項目を柔軟に定義可能
--    - custom_field_definitions: 項目のメタデータ（名前、型、必須フラグ等）
--    - custom_field_values: 各タスクに対する実際の値
--    - 詳細は該当テーブルのコメントを参照
--
-- ============================================================================

-- UUID生成用の拡張機能を有効化
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- タスクステータス用 ENUM 型
-- ============================================================================
-- 画面仕様に基づき、固定の3ステータスをENUM型で定義
-- 将来的にテナント別カスタムステータスが必要な場合は、マスタテーブルに移行可能

CREATE TYPE task_status AS ENUM ('todo', 'in_progress', 'done');

-- ============================================================================
-- カスタムフィールドのデータ型用 ENUM
-- ============================================================================
-- EAVパターンで使用する値の型を定義
-- アプリケーション側で型に応じたバリデーションを実施

CREATE TYPE field_type AS ENUM ('text', 'number', 'date', 'boolean', 'select');

-- ============================================================================
-- tenants: テナント（工場環境）マスタ
-- ============================================================================
-- マルチテナントの基盤となるテーブル
-- 各工場や組織がそれぞれ独立した環境としてデータを管理

CREATE TABLE tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE tenants IS 'テナント（工場環境）マスタ。マルチテナントの基盤となるテーブル';
COMMENT ON COLUMN tenants.name IS 'テナント名（工場名・組織名）';

-- ============================================================================
-- equipments: 設備マスタ（階層構造対応）
-- ============================================================================
-- 設備は親子関係を持つことができる（例: ライン > 機械 > ユニット）
-- parent_equipment_id による自己参照で階層を表現

CREATE TABLE equipments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    parent_equipment_id UUID REFERENCES equipments(id) ON DELETE SET NULL,
    name VARCHAR(255) NOT NULL,
    manufacturer VARCHAR(255),
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
    -- NOTE: 親設備が同一テナント内であることはアプリケーション層で検証
);

CREATE INDEX idx_equipments_tenant ON equipments(tenant_id);
CREATE INDEX idx_equipments_parent ON equipments(tenant_id, parent_equipment_id);
CREATE INDEX idx_equipments_name ON equipments(tenant_id, name);

COMMENT ON TABLE equipments IS '設備マスタ。親子階層構造に対応（自己参照）';
COMMENT ON COLUMN equipments.parent_equipment_id IS '親設備ID。NULLの場合はトップレベル設備';
COMMENT ON COLUMN equipments.manufacturer IS '製造元';

-- ============================================================================
-- parts: 部品マスタ（在庫・発注点管理）
-- ============================================================================
-- 部品の在庫数と発注点を管理し、在庫切れを防止

CREATE TABLE parts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    part_number VARCHAR(100),
    location VARCHAR(255),
    description TEXT,
    stock_quantity INTEGER NOT NULL DEFAULT 0,
    reorder_point INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_stock_quantity CHECK (stock_quantity >= 0),
    CONSTRAINT chk_reorder_point CHECK (reorder_point >= 0)
);

CREATE INDEX idx_parts_tenant ON parts(tenant_id);
CREATE UNIQUE INDEX idx_parts_number ON parts(tenant_id, part_number) WHERE part_number IS NOT NULL;

COMMENT ON TABLE parts IS '部品マスタ。在庫数と発注点を管理';
COMMENT ON COLUMN parts.location IS '保管場所';
COMMENT ON COLUMN parts.description IS '説明';
COMMENT ON COLUMN parts.stock_quantity IS '現在の在庫数';
COMMENT ON COLUMN parts.reorder_point IS '発注点（この数量を下回ったら発注が必要）';

-- ============================================================================
-- equipment_parts: 設備・部品 多対多関連
-- ============================================================================
-- 部品詳細画面の「Related Equipment」に対応
-- 1つの部品は複数の設備で使用され、1つの設備は複数の部品を必要とする

CREATE TABLE equipment_parts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    equipment_id UUID NOT NULL REFERENCES equipments(id) ON DELETE CASCADE,
    part_id UUID NOT NULL REFERENCES parts(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_equipment_part UNIQUE (equipment_id, part_id)
);

CREATE INDEX idx_equipment_parts_tenant ON equipment_parts(tenant_id);
CREATE INDEX idx_equipment_parts_equipment ON equipment_parts(equipment_id);
CREATE INDEX idx_equipment_parts_part ON equipment_parts(part_id);

COMMENT ON TABLE equipment_parts IS '設備と部品の多対多関連テーブル';

-- ============================================================================
-- tasks: タスク管理
-- ============================================================================
-- 工場での作業タスクを管理。設備に紐づけて登録し、後から集計可能
-- NOTE: equipment_id は任意項目（課題要件では設備は必須項目ではない）

CREATE TABLE tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    equipment_id UUID REFERENCES equipments(id) ON DELETE SET NULL,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    status task_status NOT NULL DEFAULT 'todo',
    due_date DATE,
    assigned_to VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_tasks_tenant ON tasks(tenant_id);
CREATE INDEX idx_tasks_equipment ON tasks(tenant_id, equipment_id) WHERE equipment_id IS NOT NULL;
CREATE INDEX idx_tasks_status ON tasks(tenant_id, status);
CREATE INDEX idx_tasks_due_date ON tasks(tenant_id, due_date);

COMMENT ON TABLE tasks IS 'タスク管理テーブル。設備への紐づけは任意';
COMMENT ON COLUMN tasks.equipment_id IS '設備ID（任意）。NULLの場合は設備に紐づかないタスク';
COMMENT ON COLUMN tasks.status IS 'タスクステータス: todo（未着手）, in_progress（進行中）, done（完了）';
COMMENT ON COLUMN tasks.assigned_to IS '担当者名';

-- ============================================================================
-- task_parts: タスク・部品関連（使用数量付き）
-- ============================================================================
-- タスク詳細画面の「Parts Used」に対応
-- タスクで使用する部品と数量を記録

CREATE TABLE task_parts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    part_id UUID NOT NULL REFERENCES parts(id) ON DELETE RESTRICT,
    quantity INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_task_part UNIQUE (task_id, part_id),
    CONSTRAINT chk_quantity CHECK (quantity > 0)
);

CREATE INDEX idx_task_parts_tenant ON task_parts(tenant_id);
CREATE INDEX idx_task_parts_task ON task_parts(task_id);
CREATE INDEX idx_task_parts_part ON task_parts(part_id);

COMMENT ON TABLE task_parts IS 'タスクと部品の関連テーブル。使用数量を記録';
COMMENT ON COLUMN task_parts.quantity IS '使用数量';

-- ============================================================================
-- custom_field_definitions: テナント独自カスタムフィールド定義
-- ============================================================================
-- 【EAVパターン - 属性定義部分】
--
-- このテーブルはEAV（Entity-Attribute-Value）パターンの「Attribute」部分を担う。
-- テナントごとに独自の入力項目（カスタムフィールド）を定義できる。
--
-- 【採用理由】
-- - テナントごとに異なる入力項目を柔軟に追加・変更できる
-- - スキーマ変更なしで新しい項目を追加可能
-- - 画面仕様の「Cause of stoppage」「Repair details」等のテナント固有項目に対応
--
-- 【トレードオフ】
-- - 型安全性はアプリケーション層で担保する必要がある
-- - 複雑な集計クエリはJSON型やピボットクエリが必要になる場合がある

CREATE TABLE custom_field_definitions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    field_name VARCHAR(255) NOT NULL,
    field_type field_type NOT NULL DEFAULT 'text',
    is_required BOOLEAN NOT NULL DEFAULT FALSE,
    display_order INTEGER NOT NULL DEFAULT 0,
    options JSONB,  -- field_type='select' の場合の選択肢リスト
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_field_name_per_tenant UNIQUE (tenant_id, field_name)
);

CREATE INDEX idx_custom_field_definitions_tenant ON custom_field_definitions(tenant_id);

COMMENT ON TABLE custom_field_definitions IS 'テナント独自カスタムフィールド定義（EAVパターンのAttribute部分）';
COMMENT ON COLUMN custom_field_definitions.field_name IS 'フィールド名（例: Cause of stoppage, Repair details）';
COMMENT ON COLUMN custom_field_definitions.field_type IS 'データ型: text, number, date, boolean, select';
COMMENT ON COLUMN custom_field_definitions.is_required IS '必須フラグ';
COMMENT ON COLUMN custom_field_definitions.display_order IS '画面表示順';
COMMENT ON COLUMN custom_field_definitions.options IS 'select型の場合の選択肢（JSON配列）';

-- ============================================================================
-- custom_field_values: カスタムフィールドの値
-- ============================================================================
-- 【EAVパターン - 値格納部分】
--
-- このテーブルはEAV（Entity-Attribute-Value）パターンの「Value」部分を担う。
-- 各タスクに対して、定義されたカスタムフィールドの値を格納する。
--
-- 【設計ポイント】
-- - value カラムは TEXT 型で統一し、アプリケーション層で型変換
-- - field_type に応じたバリデーションはアプリケーション層で実施
-- - Entity（タスク）× Attribute（フィールド定義）で一意制約

CREATE TABLE custom_field_values (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    field_definition_id UUID NOT NULL REFERENCES custom_field_definitions(id) ON DELETE CASCADE,
    value TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_task_field UNIQUE (task_id, field_definition_id)
);

CREATE INDEX idx_custom_field_values_tenant ON custom_field_values(tenant_id);
CREATE INDEX idx_custom_field_values_task ON custom_field_values(task_id);
CREATE INDEX idx_custom_field_values_definition ON custom_field_values(field_definition_id);

COMMENT ON TABLE custom_field_values IS 'カスタムフィールドの値（EAVパターンのValue部分）';
COMMENT ON COLUMN custom_field_values.value IS 'フィールドの値（TEXT型で統一、型変換はアプリケーション層）';

-- ============================================================================
-- task_comments: タスクコメント【課題2: 追加機能】
-- ============================================================================
-- 【機能概要】
-- タスクに対してコメント（メモ・連絡事項）を複数登録できる機能。
--
-- 【工場タスク管理における価値】
-- - 作業履歴の時系列記録: 誰がいつどのような対応をしたかを追跡
-- - 担当者間の情報共有: シフト交代時の引き継ぎをスムーズに
-- - 問題分析の支援: 過去のコメントを参照して再発防止策を検討
--
-- 【設計ポイント】
-- - commented_by は文字列で記録（将来的にユーザーテーブルができれば外部キーに変更可能）
-- - 削除はソフトデリート（deleted_at）で履歴を保持

CREATE TABLE task_comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    commented_by VARCHAR(255) NOT NULL,
    comment TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX idx_task_comments_tenant ON task_comments(tenant_id);
CREATE INDEX idx_task_comments_task ON task_comments(task_id);
CREATE INDEX idx_task_comments_created ON task_comments(task_id, created_at);

COMMENT ON TABLE task_comments IS 'タスクコメント【課題2】。作業履歴や引き継ぎ事項を記録';
COMMENT ON COLUMN task_comments.commented_by IS 'コメント投稿者名（将来的にユーザーテーブルの外部キーに変更可能）';
COMMENT ON COLUMN task_comments.deleted_at IS 'ソフトデリート用タイムスタンプ。NULLでない場合は削除済み';

-- ============================================================================
-- updated_at 自動更新トリガー
-- ============================================================================
-- 各テーブルの updated_at を UPDATE 時に自動更新

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_tenants_updated_at
    BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_equipments_updated_at
    BEFORE UPDATE ON equipments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_parts_updated_at
    BEFORE UPDATE ON parts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_tasks_updated_at
    BEFORE UPDATE ON tasks
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_custom_field_definitions_updated_at
    BEFORE UPDATE ON custom_field_definitions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_custom_field_values_updated_at
    BEFORE UPDATE ON custom_field_values
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_task_comments_updated_at
    BEFORE UPDATE ON task_comments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
-- ============================================================================
-- M2X: グローバル基準高度水準 DB設計リファクタリング
-- ============================================================================
--
-- 【概要】
-- エンタープライズレベルのグローバル基準に準拠したDB設計への改善
--
-- 【実装項目】
-- 1. ユーザー管理テーブル（RBAC対応）
-- 2. 監査ログシステム（完全な変更追跡）
-- 3. クロステナント制約強化（トリガーによる整合性保証）
-- 4. 全テーブルソフトデリート対応
-- 5. 楽観的ロック（version列によるコンフリクト検出）
-- 6. タスク優先度・カテゴリーENUM
-- 7. 追加インデックス（パフォーマンス最適化）
-- 8. JSONスキーマバリデーション
--
-- 【グローバル基準準拠】
-- - ISO 27001: 監査ログによるトレーサビリティ
-- - SOC 2: アクセス制御とデータ整合性
-- - GDPR: 削除履歴の保持とデータ最小化
--
-- ============================================================================

-- ============================================================================
-- SECTION 0: RLS用ヘルパー関数
-- ============================================================================
-- Row Level Security (RLS) で使用するテナントID取得関数
-- アプリケーション層で SET app.current_tenant_id = 'UUID' を実行して設定

CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS UUID AS $$
BEGIN
    RETURN NULLIF(current_setting('app.current_tenant_id', TRUE), '')::UUID;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION current_tenant_id() IS 'RLS用: 現在のテナントIDを取得（app.current_tenant_idから）';

-- ============================================================================
-- SECTION 1: 追加ENUM型定義
-- ============================================================================

-- タスク優先度
CREATE TYPE task_priority AS ENUM ('critical', 'high', 'medium', 'low');
COMMENT ON TYPE task_priority IS 'タスク優先度: critical(緊急), high(高), medium(中), low(低)';

-- タスクカテゴリー
CREATE TYPE task_category AS ENUM (
    'maintenance',      -- 定期メンテナンス
    'repair',           -- 修理
    'inspection',       -- 点検
    'replacement',      -- 部品交換
    'calibration',      -- 校正
    'cleaning',         -- 清掃
    'improvement',      -- 改善
    'emergency',        -- 緊急対応
    'other'             -- その他
);
COMMENT ON TYPE task_category IS 'タスクカテゴリー: 工場作業の種類分類';

-- ユーザーロール
CREATE TYPE user_role AS ENUM (
    'admin',            -- 管理者（全権限）
    'manager',          -- マネージャー（承認権限）
    'operator',         -- オペレーター（作業実行）
    'viewer'            -- 閲覧者（読み取り専用）
);
COMMENT ON TYPE user_role IS 'ユーザーロール: RBAC権限レベル';

-- ユーザーステータス
CREATE TYPE user_status AS ENUM (
    'active',           -- アクティブ
    'inactive',         -- 非アクティブ
    'locked',           -- ロック（認証失敗等）
    'pending'           -- 招待中
);
COMMENT ON TYPE user_status IS 'ユーザーステータス';

-- 監査操作タイプ
CREATE TYPE audit_operation AS ENUM (
    'INSERT',
    'UPDATE',
    'DELETE',
    'SOFT_DELETE',
    'RESTORE'
);
COMMENT ON TYPE audit_operation IS '監査ログの操作タイプ';

-- ============================================================================
-- SECTION 2: ユーザー管理テーブル
-- ============================================================================
-- 【設計方針】
-- - テナントごとのユーザー管理
-- - パスワードハッシュ保存（アプリケーション層でbcrypt等使用）
-- - 認証関連メタデータ（ロック、最終ログイン等）
-- - RLSによるテナント分離

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- 認証情報
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255),  -- NULL許容（SSO対応）

    -- プロファイル
    display_name VARCHAR(255) NOT NULL,
    employee_id VARCHAR(100),  -- 社員番号
    department VARCHAR(255),

    -- 権限
    role user_role NOT NULL DEFAULT 'operator',
    status user_status NOT NULL DEFAULT 'pending',

    -- 認証メタデータ
    last_login_at TIMESTAMP WITH TIME ZONE,
    failed_login_count INTEGER NOT NULL DEFAULT 0,
    locked_until TIMESTAMP WITH TIME ZONE,
    password_changed_at TIMESTAMP WITH TIME ZONE,

    -- 監査フィールド
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,

    -- バージョニング（楽観的ロック）
    version INTEGER NOT NULL DEFAULT 1,

    -- 制約
    CONSTRAINT uq_user_email_per_tenant UNIQUE (tenant_id, email),
    CONSTRAINT uq_employee_id_per_tenant UNIQUE (tenant_id, employee_id),
    CONSTRAINT chk_email_format CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    CONSTRAINT chk_failed_login_count CHECK (failed_login_count >= 0)
);

-- インデックス
CREATE INDEX idx_users_tenant ON users(tenant_id);
CREATE INDEX idx_users_email ON users(tenant_id, email);
CREATE INDEX idx_users_role ON users(tenant_id, role) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_status ON users(tenant_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_active ON users(tenant_id) WHERE deleted_at IS NULL AND status = 'active';

COMMENT ON TABLE users IS 'ユーザー管理テーブル。RBAC権限管理とテナント分離に対応';
COMMENT ON COLUMN users.email IS 'メールアドレス（テナント内で一意）';
COMMENT ON COLUMN users.password_hash IS 'パスワードハッシュ（bcrypt推奨）。SSO時はNULL';
COMMENT ON COLUMN users.role IS 'ユーザーロール（RBAC）';
COMMENT ON COLUMN users.failed_login_count IS 'ログイン失敗回数（アカウントロック判定用）';
COMMENT ON COLUMN users.version IS '楽観的ロック用バージョン番号';

-- RLSポリシー
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY users_tenant_isolation ON users
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- updated_atトリガー
CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- SECTION 3: 監査ログシステム
-- ============================================================================
-- 【設計方針】
-- - 全テーブルの変更を追跡
-- - 変更前後の値をJSONBで保存
-- - 操作者情報を記録
-- - 不変テーブル（削除不可）
-- - パーティショニング対応（将来拡張）

CREATE TABLE audit_logs (
    id BIGSERIAL PRIMARY KEY,

    -- 対象情報
    table_name VARCHAR(255) NOT NULL,
    record_id UUID NOT NULL,
    tenant_id UUID,  -- テナント分離用

    -- 操作情報
    operation audit_operation NOT NULL,

    -- 変更内容
    old_values JSONB,
    new_values JSONB,
    changed_fields TEXT[],  -- 変更されたフィールド名の配列

    -- 操作者情報
    performed_by UUID,  -- users.id
    performed_by_name VARCHAR(255),  -- スナップショット
    performed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- メタデータ
    ip_address INET,
    user_agent TEXT,
    request_id UUID,  -- リクエストトレーシング用

    -- インデックス最適化用（トリガーで自動設定）
    year_month VARCHAR(7)
);

-- year_month自動設定トリガー
CREATE OR REPLACE FUNCTION set_audit_year_month()
RETURNS TRIGGER AS $$
BEGIN
    NEW.year_month := TO_CHAR(NEW.performed_at, 'YYYY-MM');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_logs_year_month
    BEFORE INSERT ON audit_logs
    FOR EACH ROW EXECUTE FUNCTION set_audit_year_month();

-- インデックス
CREATE INDEX idx_audit_logs_table_record ON audit_logs(table_name, record_id);
CREATE INDEX idx_audit_logs_tenant ON audit_logs(tenant_id, performed_at DESC);
CREATE INDEX idx_audit_logs_performed_at ON audit_logs(performed_at DESC);
CREATE INDEX idx_audit_logs_performed_by ON audit_logs(performed_by);
CREATE INDEX idx_audit_logs_year_month ON audit_logs(year_month);

-- BRIN索引（時系列データに最適）
CREATE INDEX idx_audit_logs_performed_at_brin ON audit_logs USING BRIN (performed_at);

COMMENT ON TABLE audit_logs IS '監査ログテーブル。全データ変更の追跡（ISO 27001準拠）';
COMMENT ON COLUMN audit_logs.changed_fields IS '変更されたフィールド名の配列';
COMMENT ON COLUMN audit_logs.request_id IS '分散トレーシング用リクエストID';
COMMENT ON COLUMN audit_logs.year_month IS 'パーティショニング・アーカイブ用（トリガーで自動設定）';

-- 監査ログは削除不可（トリガーで防止）
CREATE OR REPLACE FUNCTION prevent_audit_log_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Audit logs cannot be modified or deleted (compliance requirement)';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER prevent_audit_log_update
    BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_log_modification();

-- ============================================================================
-- SECTION 4: 汎用監査トリガー関数
-- ============================================================================
-- 全テーブルに適用可能な監査トリガー

CREATE OR REPLACE FUNCTION audit_trigger_function()
RETURNS TRIGGER AS $$
DECLARE
    old_data JSONB;
    new_data JSONB;
    changed_cols TEXT[];
    col_name TEXT;
    tenant UUID;
    user_id UUID;
    user_name TEXT;
BEGIN
    -- テナントID取得
    BEGIN
        tenant := current_tenant_id();
    EXCEPTION WHEN OTHERS THEN
        tenant := NULL;
    END;

    -- ユーザー情報取得
    BEGIN
        user_id := NULLIF(current_setting('app.current_user_id', true), '')::UUID;
        user_name := NULLIF(current_setting('app.current_user_name', true), '');
    EXCEPTION WHEN OTHERS THEN
        user_id := NULL;
        user_name := NULL;
    END;

    IF TG_OP = 'INSERT' THEN
        new_data := to_jsonb(NEW);
        INSERT INTO audit_logs (
            table_name, record_id, tenant_id, operation,
            new_values, performed_by, performed_by_name
        ) VALUES (
            TG_TABLE_NAME, NEW.id, tenant, 'INSERT',
            new_data, user_id, user_name
        );
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        old_data := to_jsonb(OLD);
        new_data := to_jsonb(NEW);

        -- 変更されたカラムを検出
        changed_cols := ARRAY[]::TEXT[];
        FOR col_name IN SELECT key FROM jsonb_each(old_data)
        LOOP
            IF old_data->col_name IS DISTINCT FROM new_data->col_name THEN
                changed_cols := array_append(changed_cols, col_name);
            END IF;
        END LOOP;

        -- ソフトデリート検出
        IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            INSERT INTO audit_logs (
                table_name, record_id, tenant_id, operation,
                old_values, new_values, changed_fields,
                performed_by, performed_by_name
            ) VALUES (
                TG_TABLE_NAME, NEW.id, tenant, 'SOFT_DELETE',
                old_data, new_data, changed_cols,
                user_id, user_name
            );
        -- リストア検出
        ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
            INSERT INTO audit_logs (
                table_name, record_id, tenant_id, operation,
                old_values, new_values, changed_fields,
                performed_by, performed_by_name
            ) VALUES (
                TG_TABLE_NAME, NEW.id, tenant, 'RESTORE',
                old_data, new_data, changed_cols,
                user_id, user_name
            );
        -- 通常のUPDATE
        ELSIF array_length(changed_cols, 1) > 0 THEN
            INSERT INTO audit_logs (
                table_name, record_id, tenant_id, operation,
                old_values, new_values, changed_fields,
                performed_by, performed_by_name
            ) VALUES (
                TG_TABLE_NAME, NEW.id, tenant, 'UPDATE',
                old_data, new_data, changed_cols,
                user_id, user_name
            );
        END IF;
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        old_data := to_jsonb(OLD);
        INSERT INTO audit_logs (
            table_name, record_id, tenant_id, operation,
            old_values, performed_by, performed_by_name
        ) VALUES (
            TG_TABLE_NAME, OLD.id, tenant, 'DELETE',
            old_data, user_id, user_name
        );
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit_trigger_function() IS '汎用監査トリガー関数。全テーブルの変更を追跡';

-- ============================================================================
-- SECTION 5: 既存テーブルへの拡張カラム追加
-- ============================================================================

-- -----------------------------------------------------------------------------
-- 5.1 tenantsテーブル拡張
-- -----------------------------------------------------------------------------
ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS slug VARCHAR(100),
    ADD COLUMN IF NOT EXISTS timezone VARCHAR(50) DEFAULT 'Asia/Tokyo',
    ADD COLUMN IF NOT EXISTS locale VARCHAR(10) DEFAULT 'ja_JP',
    ADD COLUMN IF NOT EXISTS settings JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

-- テナントスラグの一意制約
CREATE UNIQUE INDEX IF NOT EXISTS idx_tenants_slug ON tenants(slug) WHERE slug IS NOT NULL;

COMMENT ON COLUMN tenants.slug IS 'URLフレンドリーな識別子';
COMMENT ON COLUMN tenants.timezone IS 'テナントのタイムゾーン';
COMMENT ON COLUMN tenants.locale IS 'テナントのロケール';
COMMENT ON COLUMN tenants.settings IS 'テナント固有設定（JSON）';

-- -----------------------------------------------------------------------------
-- 5.2 equipmentsテーブル拡張
-- -----------------------------------------------------------------------------
ALTER TABLE equipments
    ADD COLUMN IF NOT EXISTS serial_number VARCHAR(255),
    ADD COLUMN IF NOT EXISTS model VARCHAR(255),
    ADD COLUMN IF NOT EXISTS installation_date DATE,
    ADD COLUMN IF NOT EXISTS last_maintenance_date DATE,
    ADD COLUMN IF NOT EXISTS next_maintenance_date DATE,
    ADD COLUMN IF NOT EXISTS status VARCHAR(50) DEFAULT 'operational',
    ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

-- 追加インデックス
CREATE INDEX IF NOT EXISTS idx_equipments_serial ON equipments(tenant_id, serial_number) WHERE serial_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_equipments_status ON equipments(tenant_id, status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_equipments_maintenance ON equipments(tenant_id, next_maintenance_date) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_equipments_active ON equipments(tenant_id) WHERE deleted_at IS NULL;

COMMENT ON COLUMN equipments.serial_number IS 'シリアル番号';
COMMENT ON COLUMN equipments.model IS '型番';
COMMENT ON COLUMN equipments.installation_date IS '設置日';
COMMENT ON COLUMN equipments.next_maintenance_date IS '次回メンテナンス予定日';
COMMENT ON COLUMN equipments.metadata IS '追加メタデータ（JSON）';

-- -----------------------------------------------------------------------------
-- 5.3 partsテーブル拡張
-- -----------------------------------------------------------------------------
ALTER TABLE parts
    ADD COLUMN IF NOT EXISTS unit_price DECIMAL(15, 2),
    ADD COLUMN IF NOT EXISTS currency VARCHAR(3) DEFAULT 'JPY',
    ADD COLUMN IF NOT EXISTS supplier VARCHAR(255),
    ADD COLUMN IF NOT EXISTS lead_time_days INTEGER,
    ADD COLUMN IF NOT EXISTS minimum_order_quantity INTEGER DEFAULT 1,
    ADD COLUMN IF NOT EXISTS barcode VARCHAR(100),
    ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

-- 追加インデックス
CREATE UNIQUE INDEX IF NOT EXISTS idx_parts_barcode ON parts(tenant_id, barcode) WHERE barcode IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_parts_supplier ON parts(tenant_id, supplier) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_parts_low_stock ON parts(tenant_id)
    WHERE deleted_at IS NULL AND stock_quantity <= reorder_point;
CREATE INDEX IF NOT EXISTS idx_parts_active ON parts(tenant_id) WHERE deleted_at IS NULL;

COMMENT ON COLUMN parts.unit_price IS '単価';
COMMENT ON COLUMN parts.lead_time_days IS 'リードタイム（日）';
COMMENT ON COLUMN parts.barcode IS 'バーコード';

-- -----------------------------------------------------------------------------
-- 5.4 tasksテーブル拡張
-- -----------------------------------------------------------------------------
ALTER TABLE tasks
    ADD COLUMN IF NOT EXISTS priority task_priority DEFAULT 'medium',
    ADD COLUMN IF NOT EXISTS category task_category DEFAULT 'maintenance',
    ADD COLUMN IF NOT EXISTS estimated_hours DECIMAL(5, 2),
    ADD COLUMN IF NOT EXISTS actual_hours DECIMAL(5, 2),
    ADD COLUMN IF NOT EXISTS started_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS completed_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS created_by UUID,
    ADD COLUMN IF NOT EXISTS assigned_to_user_id UUID,
    ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

-- 追加インデックス
CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(tenant_id, priority) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_category ON tasks(tenant_id, category) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_user ON tasks(assigned_to_user_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_created_by ON tasks(created_by) WHERE deleted_at IS NULL;
-- 期限切れタスク用インデックス（CURRENT_DATEは部分インデックスで使用不可のため、完了以外をカバー）
CREATE INDEX IF NOT EXISTS idx_tasks_overdue ON tasks(tenant_id, due_date)
    WHERE deleted_at IS NULL AND status != 'done';
CREATE INDEX IF NOT EXISTS idx_tasks_active ON tasks(tenant_id) WHERE deleted_at IS NULL;

-- 複合インデックス（ダッシュボード最適化）
CREATE INDEX IF NOT EXISTS idx_tasks_dashboard ON tasks(tenant_id, status, priority, due_date)
    WHERE deleted_at IS NULL;

-- 担当者名検索用（VARCHARカラム）
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to ON tasks(tenant_id, assigned_to)
    WHERE deleted_at IS NULL AND assigned_to IS NOT NULL;

COMMENT ON COLUMN tasks.priority IS 'タスク優先度';
COMMENT ON COLUMN tasks.category IS 'タスクカテゴリー';
COMMENT ON COLUMN tasks.estimated_hours IS '見積工数（時間）';
COMMENT ON COLUMN tasks.actual_hours IS '実績工数（時間）';
COMMENT ON COLUMN tasks.started_at IS '作業開始日時';
COMMENT ON COLUMN tasks.completed_at IS '作業完了日時';

-- FK制約（ユーザー参照）
-- 注意: usersテーブルより後に定義されるため、006マイグレーションで追加

-- -----------------------------------------------------------------------------
-- 5.5 equipment_partsテーブル拡張
-- -----------------------------------------------------------------------------
ALTER TABLE equipment_parts
    ADD COLUMN IF NOT EXISTS quantity INTEGER NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS notes TEXT,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS idx_equipment_parts_active ON equipment_parts(tenant_id) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 5.6 task_partsテーブル拡張
-- -----------------------------------------------------------------------------
ALTER TABLE task_parts
    ADD COLUMN IF NOT EXISTS notes TEXT,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS idx_task_parts_active ON task_parts(tenant_id) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 5.7 custom_field_definitionsテーブル拡張
-- -----------------------------------------------------------------------------
ALTER TABLE custom_field_definitions
    ADD COLUMN IF NOT EXISTS description TEXT,
    ADD COLUMN IF NOT EXISTS placeholder VARCHAR(255),
    ADD COLUMN IF NOT EXISTS default_value TEXT,
    ADD COLUMN IF NOT EXISTS validation_rules JSONB,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS idx_custom_field_definitions_active ON custom_field_definitions(tenant_id)
    WHERE deleted_at IS NULL;

-- EAVパターンのフィールド名検索を高速化
CREATE INDEX IF NOT EXISTS idx_custom_field_definitions_lookup ON custom_field_definitions(tenant_id, field_name)
    WHERE deleted_at IS NULL;

COMMENT ON COLUMN custom_field_definitions.validation_rules IS 'バリデーションルール（JSON Schema形式）';
COMMENT ON COLUMN custom_field_definitions.placeholder IS '入力プレースホルダー';

-- -----------------------------------------------------------------------------
-- 5.8 custom_field_valuesテーブル拡張
-- -----------------------------------------------------------------------------
ALTER TABLE custom_field_values
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS idx_custom_field_values_active ON custom_field_values(tenant_id)
    WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 5.9 task_commentsテーブル拡張
-- -----------------------------------------------------------------------------
ALTER TABLE task_comments
    ADD COLUMN IF NOT EXISTS user_id UUID,
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

-- user_id外部キー（後で追加される場合に備えてDEFERRABLE）
-- ALTER TABLE task_comments ADD CONSTRAINT fk_task_comments_user
--     FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL DEFERRABLE;

-- ============================================================================
-- SECTION 6: クロステナント制約トリガー
-- ============================================================================
-- 親設備が同一テナントであることを保証

CREATE OR REPLACE FUNCTION check_equipment_parent_tenant()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.parent_equipment_id IS NOT NULL THEN
        -- 自己参照の防止
        IF NEW.id = NEW.parent_equipment_id THEN
            RAISE EXCEPTION 'Equipment cannot be its own parent';
        END IF;

        -- 親設備の存在とテナント確認
        IF NOT EXISTS (
            SELECT 1 FROM equipments
            WHERE id = NEW.parent_equipment_id
              AND tenant_id = NEW.tenant_id
              AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'Parent equipment must belong to the same tenant and not be deleted';
        END IF;

        -- 循環参照の防止（UPDATE時のみ、INSERTは新規IDなので不要）
        IF TG_OP = 'UPDATE' THEN
            IF EXISTS (
                WITH RECURSIVE ancestors AS (
                    SELECT parent_equipment_id, 1 AS depth
                    FROM equipments
                    WHERE id = NEW.parent_equipment_id AND deleted_at IS NULL
                    UNION ALL
                    SELECT e.parent_equipment_id, a.depth + 1
                    FROM equipments e
                    JOIN ancestors a ON e.id = a.parent_equipment_id
                    WHERE e.deleted_at IS NULL AND a.depth < 100  -- 深さ制限
                )
                SELECT 1 FROM ancestors WHERE parent_equipment_id = NEW.id
            ) THEN
                RAISE EXCEPTION 'Circular reference detected in equipment hierarchy';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_equipment_parent_tenant
    BEFORE INSERT OR UPDATE ON equipments
    FOR EACH ROW
    WHEN (NEW.parent_equipment_id IS NOT NULL)
    EXECUTE FUNCTION check_equipment_parent_tenant();

COMMENT ON FUNCTION check_equipment_parent_tenant() IS '親設備の検証（テナント確認・循環参照防止）';

-- equipment_parts: 設備と部品が同一テナントであることを保証
CREATE OR REPLACE FUNCTION check_equipment_parts_tenant()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM equipments e
        JOIN parts p ON p.tenant_id = e.tenant_id
        WHERE e.id = NEW.equipment_id
          AND p.id = NEW.part_id
          AND e.tenant_id = NEW.tenant_id
          AND e.deleted_at IS NULL
          AND p.deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Equipment and part must belong to the same tenant and not be deleted';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_equipment_parts_tenant
    BEFORE INSERT OR UPDATE ON equipment_parts
    FOR EACH ROW
    EXECUTE FUNCTION check_equipment_parts_tenant();

-- task_parts: タスクと部品が同一テナントであることを保証
CREATE OR REPLACE FUNCTION check_task_parts_tenant()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tasks t
        JOIN parts p ON p.tenant_id = t.tenant_id
        WHERE t.id = NEW.task_id
          AND p.id = NEW.part_id
          AND t.tenant_id = NEW.tenant_id
          AND t.deleted_at IS NULL
          AND p.deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Task and part must belong to the same tenant and not be deleted';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_task_parts_tenant
    BEFORE INSERT OR UPDATE ON task_parts
    FOR EACH ROW
    EXECUTE FUNCTION check_task_parts_tenant();

-- ============================================================================
-- SECTION 7: 楽観的ロック（バージョンチェック）トリガー
-- ============================================================================

CREATE OR REPLACE FUNCTION check_version_conflict()
RETURNS TRIGGER AS $$
BEGIN
    -- バージョンが明示的に変更された場合のみコンフリクトチェック
    -- 自動インクリメントの場合（NEW.version = OLD.version）はスキップ
    IF NEW.version != OLD.version AND NEW.version != OLD.version + 1 THEN
        RAISE EXCEPTION 'Optimistic locking conflict: record was modified by another transaction (expected version %, got %)',
            OLD.version + 1, NEW.version;
    END IF;
    NEW.version := OLD.version + 1;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION check_version_conflict() IS '楽観的ロックによるコンフリクト検出（バージョン自動インクリメント）';

-- 各テーブルにバージョンチェックトリガーを適用
CREATE TRIGGER trg_version_check_tenants
    BEFORE UPDATE ON tenants FOR EACH ROW EXECUTE FUNCTION check_version_conflict();

CREATE TRIGGER trg_version_check_equipments
    BEFORE UPDATE ON equipments FOR EACH ROW EXECUTE FUNCTION check_version_conflict();

CREATE TRIGGER trg_version_check_parts
    BEFORE UPDATE ON parts FOR EACH ROW EXECUTE FUNCTION check_version_conflict();

CREATE TRIGGER trg_version_check_tasks
    BEFORE UPDATE ON tasks FOR EACH ROW EXECUTE FUNCTION check_version_conflict();

CREATE TRIGGER trg_version_check_users
    BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION check_version_conflict();

-- ============================================================================
-- SECTION 8: JSONBバリデーション関数
-- ============================================================================

-- カスタムフィールド値のバリデーション
CREATE OR REPLACE FUNCTION validate_custom_field_value()
RETURNS TRIGGER AS $$
DECLARE
    field_def RECORD;
    num_value NUMERIC;
    date_value DATE;
    bool_value BOOLEAN;
    options JSONB;
BEGIN
    -- フィールド定義を取得
    SELECT * INTO field_def
    FROM custom_field_definitions
    WHERE id = NEW.field_definition_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Custom field definition not found or deleted';
    END IF;

    -- NULL値は必須チェックのみ
    IF NEW.value IS NULL THEN
        IF field_def.is_required THEN
            RAISE EXCEPTION 'Field "%" is required', field_def.field_name;
        END IF;
        RETURN NEW;
    END IF;

    -- 型別バリデーション
    CASE field_def.field_type
        WHEN 'number' THEN
            BEGIN
                num_value := NEW.value::NUMERIC;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'Field "%" must be a valid number', field_def.field_name;
            END;

        WHEN 'date' THEN
            BEGIN
                date_value := NEW.value::DATE;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'Field "%" must be a valid date (YYYY-MM-DD)', field_def.field_name;
            END;

        WHEN 'boolean' THEN
            IF LOWER(NEW.value) NOT IN ('true', 'false', '1', '0', 'yes', 'no') THEN
                RAISE EXCEPTION 'Field "%" must be a boolean value', field_def.field_name;
            END IF;

        WHEN 'select' THEN
            options := field_def.options;
            IF options IS NOT NULL AND NOT (options ? NEW.value) THEN
                IF NOT EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(options) AS opt
                    WHERE opt = NEW.value
                ) THEN
                    RAISE EXCEPTION 'Field "%" value must be one of the defined options', field_def.field_name;
                END IF;
            END IF;

        ELSE
            -- text型は長さチェックのみ
            IF LENGTH(NEW.value) > 10000 THEN
                RAISE EXCEPTION 'Field "%" value exceeds maximum length (10000)', field_def.field_name;
            END IF;
    END CASE;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_custom_field_value
    BEFORE INSERT OR UPDATE ON custom_field_values
    FOR EACH ROW
    EXECUTE FUNCTION validate_custom_field_value();

COMMENT ON FUNCTION validate_custom_field_value() IS 'カスタムフィールド値の型バリデーション';

-- ============================================================================
-- SECTION 9: 監査トリガーの適用
-- ============================================================================

-- 主要テーブルに監査トリガーを適用
CREATE TRIGGER audit_tenants
    AFTER INSERT OR UPDATE OR DELETE ON tenants
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER audit_equipments
    AFTER INSERT OR UPDATE OR DELETE ON equipments
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER audit_parts
    AFTER INSERT OR UPDATE OR DELETE ON parts
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER audit_tasks
    AFTER INSERT OR UPDATE OR DELETE ON tasks
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER audit_users
    AFTER INSERT OR UPDATE OR DELETE ON users
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER audit_task_comments
    AFTER INSERT OR UPDATE OR DELETE ON task_comments
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER audit_custom_field_definitions
    AFTER INSERT OR UPDATE OR DELETE ON custom_field_definitions
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER audit_custom_field_values
    AFTER INSERT OR UPDATE OR DELETE ON custom_field_values
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

-- ============================================================================
-- SECTION 10: ビュー定義
-- ============================================================================

-- アクティブユーザービュー
CREATE OR REPLACE VIEW v_active_users AS
SELECT
    u.id,
    u.tenant_id,
    t.name AS tenant_name,
    u.email,
    u.display_name,
    u.role,
    u.department,
    u.last_login_at
FROM users u
JOIN tenants t ON u.tenant_id = t.id
WHERE u.deleted_at IS NULL
  AND u.status = 'active'
  AND t.deleted_at IS NULL;

COMMENT ON VIEW v_active_users IS 'アクティブユーザー一覧（ソフトデリート除外）';

-- 在庫アラートビュー
CREATE OR REPLACE VIEW v_low_stock_alerts AS
SELECT
    p.id,
    p.tenant_id,
    t.name AS tenant_name,
    p.name AS part_name,
    p.part_number,
    p.stock_quantity,
    p.reorder_point,
    p.reorder_point - p.stock_quantity AS shortage,
    p.supplier,
    p.lead_time_days,
    p.unit_price,
    p.currency
FROM parts p
JOIN tenants t ON p.tenant_id = t.id
WHERE p.deleted_at IS NULL
  AND t.deleted_at IS NULL
  AND p.stock_quantity <= p.reorder_point
ORDER BY p.stock_quantity ASC;

COMMENT ON VIEW v_low_stock_alerts IS '在庫アラート対象部品一覧';

-- タスクサマリービュー
CREATE OR REPLACE VIEW v_task_summary AS
SELECT
    t.tenant_id,
    tn.name AS tenant_name,
    t.status,
    t.priority,
    t.category,
    COUNT(*) AS task_count,
    COUNT(*) FILTER (WHERE t.due_date < CURRENT_DATE AND t.status != 'done') AS overdue_count,
    AVG(t.estimated_hours) AS avg_estimated_hours,
    AVG(t.actual_hours) AS avg_actual_hours
FROM tasks t
JOIN tenants tn ON t.tenant_id = tn.id
WHERE t.deleted_at IS NULL AND tn.deleted_at IS NULL
GROUP BY t.tenant_id, tn.name, t.status, t.priority, t.category;

COMMENT ON VIEW v_task_summary IS 'テナント別タスクサマリー統計';

-- 設備階層ビュー（マテリアライズドビュー候補）
CREATE OR REPLACE VIEW v_equipment_hierarchy AS
WITH RECURSIVE equipment_tree AS (
    SELECT
        id,
        tenant_id,
        name,
        parent_equipment_id,
        0 AS depth,
        ARRAY[name::TEXT] AS path,
        ARRAY[id] AS id_path
    FROM equipments
    WHERE parent_equipment_id IS NULL AND deleted_at IS NULL

    UNION ALL

    SELECT
        e.id,
        e.tenant_id,
        e.name,
        e.parent_equipment_id,
        et.depth + 1,
        et.path || e.name::TEXT,
        et.id_path || e.id
    FROM equipments e
    JOIN equipment_tree et ON e.parent_equipment_id = et.id
    WHERE e.deleted_at IS NULL
)
SELECT
    id,
    tenant_id,
    name,
    parent_equipment_id,
    depth,
    path,
    id_path,
    array_to_string(path, ' > ') AS full_path
FROM equipment_tree;

COMMENT ON VIEW v_equipment_hierarchy IS '設備階層構造ビュー（パス情報付き）';

-- ============================================================================
-- SECTION 11: 便利関数
-- ============================================================================

-- ソフトデリート実行関数
CREATE OR REPLACE FUNCTION soft_delete(
    p_table_name TEXT,
    p_record_id UUID
) RETURNS BOOLEAN AS $$
DECLARE
    rows_affected INTEGER;
BEGIN
    EXECUTE format(
        'UPDATE %I SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL',
        p_table_name
    ) USING p_record_id;

    GET DIAGNOSTICS rows_affected = ROW_COUNT;
    RETURN rows_affected > 0;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION soft_delete(TEXT, UUID) IS 'レコードのソフトデリート実行';

-- リストア関数
CREATE OR REPLACE FUNCTION restore_deleted(
    p_table_name TEXT,
    p_record_id UUID
) RETURNS BOOLEAN AS $$
DECLARE
    rows_affected INTEGER;
BEGIN
    EXECUTE format(
        'UPDATE %I SET deleted_at = NULL WHERE id = $1 AND deleted_at IS NOT NULL',
        p_table_name
    ) USING p_record_id;

    GET DIAGNOSTICS rows_affected = ROW_COUNT;
    RETURN rows_affected > 0;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION restore_deleted(TEXT, UUID) IS 'ソフトデリートされたレコードをリストア';

-- 監査ログ検索関数
CREATE OR REPLACE FUNCTION get_audit_history(
    p_table_name TEXT,
    p_record_id UUID,
    p_limit INTEGER DEFAULT 100
) RETURNS TABLE (
    operation audit_operation,
    old_values JSONB,
    new_values JSONB,
    changed_fields TEXT[],
    performed_by_name VARCHAR(255),
    performed_at TIMESTAMP WITH TIME ZONE
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        al.operation,
        al.old_values,
        al.new_values,
        al.changed_fields,
        al.performed_by_name,
        al.performed_at
    FROM audit_logs al
    WHERE al.table_name = p_table_name
      AND al.record_id = p_record_id
    ORDER BY al.performed_at DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_audit_history(TEXT, UUID, INTEGER) IS 'レコードの変更履歴を取得';

-- ============================================================================
-- SECTION 12: セッション変数ヘルパー関数
-- ============================================================================

-- 現在のユーザーID取得
CREATE OR REPLACE FUNCTION current_user_id()
RETURNS UUID AS $$
BEGIN
    RETURN NULLIF(current_setting('app.current_user_id', true), '')::UUID;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION current_user_id() IS 'セッション変数から現在のユーザーIDを取得';

-- 現在のユーザー名取得
CREATE OR REPLACE FUNCTION current_user_name()
RETURNS VARCHAR AS $$
BEGIN
    RETURN NULLIF(current_setting('app.current_user_name', true), '');
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION current_user_name() IS 'セッション変数から現在のユーザー名を取得';

-- ============================================================================
-- SECTION 13: 遅延FK制約（usersテーブル参照）
-- ============================================================================
-- usersテーブル作成後にFK制約を追加

-- tasks.assigned_to_user_id -> users.id
ALTER TABLE tasks
    ADD CONSTRAINT fk_tasks_assigned_user
    FOREIGN KEY (assigned_to_user_id)
    REFERENCES users(id)
    ON DELETE SET NULL;

-- tasks.created_by -> users.id
ALTER TABLE tasks
    ADD CONSTRAINT fk_tasks_created_by
    FOREIGN KEY (created_by)
    REFERENCES users(id)
    ON DELETE SET NULL;

-- task_comments.user_id -> users.id
ALTER TABLE task_comments
    ADD CONSTRAINT fk_task_comments_user
    FOREIGN KEY (user_id)
    REFERENCES users(id)
    ON DELETE SET NULL;

COMMENT ON CONSTRAINT fk_tasks_assigned_user ON tasks IS 'タスク担当者への参照（削除時NULL）';
COMMENT ON CONSTRAINT fk_tasks_created_by ON tasks IS 'タスク作成者への参照（削除時NULL）';
COMMENT ON CONSTRAINT fk_task_comments_user ON task_comments IS 'コメント投稿者への参照（削除時NULL）';

-- ============================================================================
-- SECTION 14: 追加CHECK制約
-- ============================================================================

-- tasks: 工数は非負
ALTER TABLE tasks
    ADD CONSTRAINT chk_tasks_estimated_hours CHECK (estimated_hours IS NULL OR estimated_hours >= 0),
    ADD CONSTRAINT chk_tasks_actual_hours CHECK (actual_hours IS NULL OR actual_hours >= 0);

-- parts: リードタイム・最小発注数は非負
ALTER TABLE parts
    ADD CONSTRAINT chk_parts_lead_time CHECK (lead_time_days IS NULL OR lead_time_days >= 0),
    ADD CONSTRAINT chk_parts_min_order CHECK (minimum_order_quantity IS NULL OR minimum_order_quantity >= 1);

-- equipments: メンテナンス日付の順序
ALTER TABLE equipments
    ADD CONSTRAINT chk_equipments_maintenance_dates CHECK (
        next_maintenance_date IS NULL
        OR last_maintenance_date IS NULL
        OR next_maintenance_date >= last_maintenance_date
    );

-- parts: 通貨コードはISO 4217形式
ALTER TABLE parts
    ADD CONSTRAINT chk_parts_currency CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$');

COMMENT ON CONSTRAINT chk_tasks_estimated_hours ON tasks IS '見積工数は0以上';
COMMENT ON CONSTRAINT chk_tasks_actual_hours ON tasks IS '実績工数は0以上';
COMMENT ON CONSTRAINT chk_parts_lead_time ON parts IS 'リードタイムは0以上';
COMMENT ON CONSTRAINT chk_parts_min_order ON parts IS '最小発注数は1以上';
COMMENT ON CONSTRAINT chk_equipments_maintenance_dates ON equipments IS '次回メンテナンス日は前回以降';
COMMENT ON CONSTRAINT chk_parts_currency ON parts IS '通貨コードはISO 4217形式（3文字大文字）';

-- ============================================================================
-- 完了メッセージ
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE 'グローバル基準DB設計リファクタリング完了';
    RAISE NOTICE '- ユーザー管理テーブル: 作成済';
    RAISE NOTICE '- 監査ログシステム: 作成済';
    RAISE NOTICE '- クロステナント制約: 適用済';
    RAISE NOTICE '- ソフトデリート: 全テーブル対応済';
    RAISE NOTICE '- 楽観的ロック: 適用済';
    RAISE NOTICE '- 追加インデックス: 作成済';
    RAISE NOTICE '- バリデーショントリガー: 作成済';
END;
$$;
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
