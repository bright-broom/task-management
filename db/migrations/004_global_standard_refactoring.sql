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
