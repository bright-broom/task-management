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
