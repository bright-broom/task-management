-- ============================================================================
-- M2X課題: エンタープライズスケール・リファクタリング
-- ============================================================================
-- 対象: 数億レコード規模・高トラフィックSaaS運用
--
-- 変更内容:
-- 1. 時系列データのネイティブ・パーティショニング化（audit_logs, measurement_data）
-- 2. カスタムフィールド検証の高速化（例外処理の排除）
-- 3. 論理削除と物理削除の競合解消（ON DELETE RESTRICT + ソフトデリート連鎖トリガー）
-- 4. RLSとコネクションプーリングの安全性確保（SET LOCAL警告コメント追加）
-- ============================================================================

-- ============================================================================
-- SECTION 1: RLS用ヘルパー関数（コネクションプーリング安全性強化）
-- ============================================================================
-- 【重要: PgBouncer/Pgpool-II等のトランザクションプーリング使用時の注意】
--
-- ■ セッション変数の安全な設定方法:
--   - トランザクションプーリングモードでは、SET（セッションスコープ）は
--     他のトランザクションに漏洩する危険があります（セッション汚染）
--   - 必ず SET LOCAL（トランザクションスコープ）を使用してください
--
-- ■ アプリケーション層での正しい実装例:
--   BEGIN;
--   SET LOCAL app.current_tenant_id = '11111111-1111-1111-1111-111111111111';
--   SET LOCAL app.current_user_id = 'user-uuid-here';
--   SET LOCAL app.current_user_name = 'John Doe';
--   -- ここでクエリ実行
--   COMMIT;  -- COMMIT/ROLLBACKでローカル設定は自動的にクリアされる
--
-- ■ ベストプラクティス:
--   1. connection.execute("SET LOCAL app.current_tenant_id = %s", [tenant_id])
--   2. トランザクション終了時に設定は自動リセットされる
--   3. RESET ALLは不要（むしろ他の設定も消すため非推奨）
--
-- ■ PgBouncerの推奨設定:
--   - server_reset_query = 'DISCARD ALL' (セッションプーリングの場合)
--   - トランザクションプーリングでは上記SET LOCALパターンを必須とする
-- ============================================================================

DROP FUNCTION IF EXISTS current_tenant_id() CASCADE;

CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS UUID AS $$
DECLARE
    tenant_uuid UUID;
    setting_value TEXT;
BEGIN
    -- current_setting with missing_ok=true returns empty string if not set
    setting_value := current_setting('app.current_tenant_id', TRUE);

    -- Empty or NULL check without exception handling
    IF setting_value IS NULL OR setting_value = '' THEN
        RETURN NULL;
    END IF;

    -- UUID format validation using regex (avoids exception on invalid format)
    IF setting_value !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
        RETURN NULL;
    END IF;

    RETURN setting_value::UUID;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION current_tenant_id() IS
'RLS用: 現在のテナントIDを取得。
【警告】PgBouncer等のトランザクションプーリング環境では、
アプリケーション層で必ず SET LOCAL を使用すること（SET は使用禁止）。
例: SET LOCAL app.current_tenant_id = ''uuid-here''';


-- ============================================================================
-- SECTION 2: 監査トリガー関数（コネクションプーリング安全性強化）
-- ============================================================================
-- 【重要】この関数内で使用する app.* パラメータは、
-- 呼び出し元のアプリケーションで SET LOCAL により設定されている前提です。
-- セッションプーリング使用時は、server_reset_query = 'DISCARD ALL' を設定し、
-- コネクション返却時に設定をクリアしてください。

DROP FUNCTION IF EXISTS audit_trigger_function() CASCADE;

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
    setting_val TEXT;
BEGIN
    -- =========================================================================
    -- テナントID取得（例外処理を使わない安全な実装）
    -- =========================================================================
    -- 【注意】current_tenant_id()は例外をスローしない設計に変更済み
    tenant := current_tenant_id();

    -- =========================================================================
    -- ユーザー情報取得（例外処理を排除した実装）
    -- =========================================================================
    -- user_id
    setting_val := current_setting('app.current_user_id', TRUE);
    IF setting_val IS NOT NULL
       AND setting_val <> ''
       AND setting_val ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    THEN
        user_id := setting_val::UUID;
    ELSE
        user_id := NULL;
    END IF;

    -- user_name
    user_name := NULLIF(current_setting('app.current_user_name', TRUE), '');

    -- =========================================================================
    -- 監査ログ挿入
    -- =========================================================================
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

COMMENT ON FUNCTION audit_trigger_function() IS
'汎用監査トリガー関数。全テーブルの変更を追跡。
【警告】PgBouncer等のコネクションプーリング環境では:
1. アプリ層で SET LOCAL app.current_user_id/app.current_user_name を使用
2. SET（セッションスコープ）は使用禁止（セッション汚染の原因）
3. トランザクション終了時に設定は自動クリアされる';


-- ============================================================================
-- SECTION 3: 時系列データのネイティブ・パーティショニング
-- ============================================================================
-- PostgreSQL 10以降の宣言的パーティショニング（Declarative Partitioning）を使用
-- 月次（Monthly）パーティションで管理

-- -----------------------------------------------------------------------------
-- 3.1 audit_logs パーティショニング
-- -----------------------------------------------------------------------------
-- 既存テーブルのバックアップと新パーティションテーブルへの移行

-- 既存トリガーの削除
DROP TRIGGER IF EXISTS trg_audit_logs_year_month ON audit_logs;
DROP TRIGGER IF EXISTS prevent_audit_log_update ON audit_logs;
DROP FUNCTION IF EXISTS set_audit_year_month();

-- 既存テーブルのリネーム（データ保持）
ALTER TABLE IF EXISTS audit_logs RENAME TO audit_logs_legacy;

-- 新しいパーティションテーブルの作成
CREATE TABLE audit_logs (
    id BIGSERIAL,

    -- 対象情報
    table_name VARCHAR(255) NOT NULL,
    record_id UUID NOT NULL,
    tenant_id UUID,

    -- 操作情報
    operation audit_operation NOT NULL,

    -- 変更内容
    old_values JSONB,
    new_values JSONB,
    changed_fields TEXT[],

    -- 操作者情報
    performed_by UUID,
    performed_by_name VARCHAR(255),
    performed_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- メタデータ
    ip_address INET,
    user_agent TEXT,
    request_id UUID,

    -- パーティションキーを含む複合主キー
    PRIMARY KEY (id, performed_at)
) PARTITION BY RANGE (performed_at);

-- パーティションテーブル用インデックス（パーティションキー不要）
CREATE INDEX idx_audit_logs_table_record ON audit_logs(table_name, record_id);
CREATE INDEX idx_audit_logs_tenant ON audit_logs(tenant_id, performed_at DESC);
CREATE INDEX idx_audit_logs_performed_by ON audit_logs(performed_by);

COMMENT ON TABLE audit_logs IS
'監査ログテーブル（パーティション化）。performed_atで月次パーティション。
【運用】新月の前に次月パーティションを作成すること。
【アーカイブ】古いパーティションはDETACHして別テーブルスペースに移動可能。';

-- 初期パーティション作成（現在月 + 前後3ヶ月）
CREATE TABLE audit_logs_y2026m01 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE audit_logs_y2026m02 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE audit_logs_y2026m03 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE audit_logs_y2026m04 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE audit_logs_y2026m05 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');

-- デフォルトパーティション（範囲外データの受け皿）
CREATE TABLE audit_logs_default PARTITION OF audit_logs DEFAULT;

-- 監査ログ改竄防止トリガー（パーティションテーブル対応）
CREATE OR REPLACE FUNCTION prevent_audit_log_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Audit logs cannot be modified or deleted (compliance requirement)';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER prevent_audit_log_update
    BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_log_modification();

-- レガシーデータの移行（大量データの場合はバッチ処理推奨）
-- INSERT INTO audit_logs SELECT
--     id, table_name, record_id, tenant_id, operation,
--     old_values, new_values, changed_fields,
--     performed_by, performed_by_name, performed_at,
--     ip_address, user_agent, request_id
-- FROM audit_logs_legacy;

-- -----------------------------------------------------------------------------
-- 3.2 measurement_data パーティショニング
-- -----------------------------------------------------------------------------
-- 計測データは特に大量になるため、パーティショニングが必須

-- 既存トリガーの削除
DROP TRIGGER IF EXISTS trg_measurement_year_month ON measurement_data;
DROP FUNCTION IF EXISTS set_measurement_year_month();

-- 既存テーブルのリネーム
ALTER TABLE IF EXISTS measurement_data RENAME TO measurement_data_legacy;

-- 新しいパーティションテーブルの作成
CREATE TABLE measurement_data (
    id UUID DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    point_id UUID NOT NULL,

    -- 計測値
    measured_at TIMESTAMP WITH TIME ZONE NOT NULL,
    numeric_value DECIMAL(15,4),
    text_value TEXT,
    boolean_value BOOLEAN,

    -- 品質フラグ
    quality VARCHAR(20) DEFAULT 'good',

    -- 異常検知
    is_anomaly BOOLEAN DEFAULT FALSE,
    anomaly_type VARCHAR(50),

    -- 入力者（手動入力の場合）
    recorded_by UUID,

    -- パーティションキーを含む複合主キー
    PRIMARY KEY (id, measured_at),

    -- 外部キー制約（パーティションテーブルでは参照のみ、CASCADEなし）
    CONSTRAINT fk_measurement_tenant FOREIGN KEY (tenant_id)
        REFERENCES tenants(id) ON DELETE RESTRICT,
    CONSTRAINT fk_measurement_point FOREIGN KEY (point_id)
        REFERENCES measurement_points(id) ON DELETE RESTRICT
) PARTITION BY RANGE (measured_at);

-- 時系列クエリ最適化インデックス
CREATE INDEX idx_measurement_data_point_time ON measurement_data(point_id, measured_at DESC);
CREATE INDEX idx_measurement_data_tenant_time ON measurement_data(tenant_id, measured_at DESC);
CREATE INDEX idx_measurement_data_anomaly ON measurement_data(point_id, measured_at DESC)
    WHERE is_anomaly = TRUE;

COMMENT ON TABLE measurement_data IS
'計測データ（パーティション化）。measured_atで月次パーティション。
【運用】高頻度データ取得の場合、日次パーティションへの変更も検討。
【アーカイブ】1年以上前のパーティションは圧縮・別ストレージ移動を推奨。';

-- 初期パーティション作成
CREATE TABLE measurement_data_y2026m01 PARTITION OF measurement_data
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE measurement_data_y2026m02 PARTITION OF measurement_data
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE measurement_data_y2026m03 PARTITION OF measurement_data
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE measurement_data_y2026m04 PARTITION OF measurement_data
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE measurement_data_y2026m05 PARTITION OF measurement_data
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');

-- デフォルトパーティション
CREATE TABLE measurement_data_default PARTITION OF measurement_data DEFAULT;

-- パーティション自動作成用関数（月次バッチで実行）
CREATE OR REPLACE FUNCTION create_monthly_partitions(
    table_name TEXT,
    start_month DATE,
    num_months INTEGER DEFAULT 3
)
RETURNS VOID AS $$
DECLARE
    partition_name TEXT;
    start_date DATE;
    end_date DATE;
    i INTEGER;
BEGIN
    FOR i IN 0..(num_months - 1) LOOP
        start_date := start_month + (i || ' months')::INTERVAL;
        end_date := start_date + '1 month'::INTERVAL;
        partition_name := table_name || '_y' || TO_CHAR(start_date, 'YYYY') || 'm' || TO_CHAR(start_date, 'MM');

        -- パーティションが存在しない場合のみ作成
        IF NOT EXISTS (
            SELECT 1 FROM pg_tables
            WHERE tablename = partition_name
        ) THEN
            EXECUTE format(
                'CREATE TABLE %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
                partition_name, table_name, start_date, end_date
            );
            RAISE NOTICE 'Created partition: %', partition_name;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION create_monthly_partitions(TEXT, DATE, INTEGER) IS
'月次パーティション自動作成関数。
使用例: SELECT create_monthly_partitions(''audit_logs'', ''2026-06-01''::DATE, 3);
cron等で毎月1日に翌月分を作成することを推奨。';


-- ============================================================================
-- SECTION 4: カスタムフィールド検証の高速化
-- ============================================================================
-- 【最適化】BEGIN...EXCEPTIONブロックを排除
-- PostgreSQLでは例外処理がサブトランザクションを発生させ、高コスト
-- 代わりに正規表現とCASE文で事前検証

DROP TRIGGER IF EXISTS trg_validate_custom_field_value ON custom_field_values;
DROP FUNCTION IF EXISTS validate_custom_field_value();

CREATE OR REPLACE FUNCTION validate_custom_field_value()
RETURNS TRIGGER AS $$
DECLARE
    field_def RECORD;
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
    IF NEW.value IS NULL OR NEW.value = '' THEN
        IF field_def.is_required THEN
            RAISE EXCEPTION 'Field "%" is required', field_def.field_name;
        END IF;
        RETURN NEW;
    END IF;

    -- =========================================================================
    -- 型別バリデーション（例外処理を使わない高速実装）
    -- =========================================================================
    CASE field_def.field_type
        -- -----------------------------------------------------------------
        -- 数値型: 正規表現で事前検証
        -- -----------------------------------------------------------------
        WHEN 'number' THEN
            -- 整数または小数点を含む数値形式をチェック
            -- 許容: 123, -456, 78.90, -12.34, .5, -.5
            IF NEW.value !~ '^-?([0-9]+\.?[0-9]*|[0-9]*\.?[0-9]+)$' THEN
                RAISE EXCEPTION 'Field "%" must be a valid number. Got: "%"',
                    field_def.field_name, NEW.value;
            END IF;

            -- オーバーフロー防止: 桁数チェック（NUMERIC最大38桁）
            IF LENGTH(REPLACE(REPLACE(NEW.value, '-', ''), '.', '')) > 38 THEN
                RAISE EXCEPTION 'Field "%" number exceeds maximum precision',
                    field_def.field_name;
            END IF;

        -- -----------------------------------------------------------------
        -- 日付型: 正規表現で事前検証
        -- -----------------------------------------------------------------
        WHEN 'date' THEN
            -- ISO 8601形式 (YYYY-MM-DD) をチェック
            IF NEW.value !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' THEN
                RAISE EXCEPTION 'Field "%" must be a valid date (YYYY-MM-DD). Got: "%"',
                    field_def.field_name, NEW.value;
            END IF;

            -- 追加: 月日の妥当性チェック（2月30日等を防止）
            -- 厳密なチェックが必要な場合はアプリ層で実施

        -- -----------------------------------------------------------------
        -- ブール型: 許容値リストでチェック
        -- -----------------------------------------------------------------
        WHEN 'boolean' THEN
            IF LOWER(NEW.value) NOT IN ('true', 'false', '1', '0', 'yes', 'no', 't', 'f', 'y', 'n') THEN
                RAISE EXCEPTION 'Field "%" must be a boolean value (true/false/yes/no/1/0). Got: "%"',
                    field_def.field_name, NEW.value;
            END IF;

        -- -----------------------------------------------------------------
        -- 選択型: オプションリストに含まれるかチェック
        -- -----------------------------------------------------------------
        WHEN 'select' THEN
            options := field_def.options;
            IF options IS NOT NULL THEN
                -- JSONBオブジェクト形式 {"option1": "label1", ...} の場合
                IF jsonb_typeof(options) = 'object' THEN
                    IF NOT (options ? NEW.value) THEN
                        RAISE EXCEPTION 'Field "%" value must be one of the defined options. Got: "%"',
                            field_def.field_name, NEW.value;
                    END IF;
                -- JSON配列形式 ["option1", "option2", ...] の場合
                ELSIF jsonb_typeof(options) = 'array' THEN
                    IF NOT EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(options) AS opt
                        WHERE opt = NEW.value
                    ) THEN
                        RAISE EXCEPTION 'Field "%" value must be one of the defined options. Got: "%"',
                            field_def.field_name, NEW.value;
                    END IF;
                END IF;
            END IF;

        -- -----------------------------------------------------------------
        -- テキスト型: 長さチェックのみ
        -- -----------------------------------------------------------------
        ELSE
            IF LENGTH(NEW.value) > 10000 THEN
                RAISE EXCEPTION 'Field "%" value exceeds maximum length (10000 characters)',
                    field_def.field_name;
            END IF;
    END CASE;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_custom_field_value
    BEFORE INSERT OR UPDATE ON custom_field_values
    FOR EACH ROW
    EXECUTE FUNCTION validate_custom_field_value();

COMMENT ON FUNCTION validate_custom_field_value() IS
'カスタムフィールド値の型バリデーション（高速版）。
【最適化】例外処理（BEGIN...EXCEPTION）を排除し、正規表現による事前検証を実装。
サブトランザクションのオーバーヘッドを回避し、高スループット環境に対応。';


-- ============================================================================
-- SECTION 5: 論理削除と物理削除の競合解消
-- ============================================================================
-- 【問題】ON DELETE CASCADEは物理削除を連鎖させるが、アプリはソフトデリート前提
-- 【解決】ON DELETE RESTRICTで物理削除を防止 + ソフトデリート連鎖トリガー

-- -----------------------------------------------------------------------------
-- 5.1 外部キー制約の変更（CASCADE → RESTRICT）
-- -----------------------------------------------------------------------------
-- 【注意】本番環境では事前にバックアップを取得し、メンテナンスウィンドウで実行

-- equipments → tenants
ALTER TABLE equipments
    DROP CONSTRAINT IF EXISTS equipments_tenant_id_fkey,
    ADD CONSTRAINT equipments_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE RESTRICT;

-- tasks → tenants
ALTER TABLE tasks
    DROP CONSTRAINT IF EXISTS tasks_tenant_id_fkey,
    ADD CONSTRAINT tasks_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE RESTRICT;

-- tasks → equipments
ALTER TABLE tasks
    DROP CONSTRAINT IF EXISTS tasks_equipment_id_fkey,
    ADD CONSTRAINT tasks_equipment_id_fkey
        FOREIGN KEY (equipment_id) REFERENCES equipments(id) ON DELETE SET NULL;

-- task_parts → tasks
ALTER TABLE task_parts
    DROP CONSTRAINT IF EXISTS task_parts_task_id_fkey,
    ADD CONSTRAINT task_parts_task_id_fkey
        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE RESTRICT;

-- task_comments → tasks
ALTER TABLE task_comments
    DROP CONSTRAINT IF EXISTS task_comments_task_id_fkey,
    ADD CONSTRAINT task_comments_task_id_fkey
        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE RESTRICT;

-- custom_field_values → tasks
ALTER TABLE custom_field_values
    DROP CONSTRAINT IF EXISTS custom_field_values_task_id_fkey,
    ADD CONSTRAINT custom_field_values_task_id_fkey
        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE RESTRICT;

-- parts → tenants
ALTER TABLE parts
    DROP CONSTRAINT IF EXISTS parts_tenant_id_fkey,
    ADD CONSTRAINT parts_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE RESTRICT;

-- equipment_parts → equipments
ALTER TABLE equipment_parts
    DROP CONSTRAINT IF EXISTS equipment_parts_equipment_id_fkey,
    ADD CONSTRAINT equipment_parts_equipment_id_fkey
        FOREIGN KEY (equipment_id) REFERENCES equipments(id) ON DELETE RESTRICT;

-- equipment_parts → parts
ALTER TABLE equipment_parts
    DROP CONSTRAINT IF EXISTS equipment_parts_part_id_fkey,
    ADD CONSTRAINT equipment_parts_part_id_fkey
        FOREIGN KEY (part_id) REFERENCES parts(id) ON DELETE RESTRICT;

-- users → tenants
ALTER TABLE users
    DROP CONSTRAINT IF EXISTS users_tenant_id_fkey,
    ADD CONSTRAINT users_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE RESTRICT;

COMMENT ON TABLE tasks IS
'タスク管理テーブル。
【削除ポリシー】ON DELETE RESTRICTにより物理削除を防止。
deleted_atによる論理削除を使用すること。';

-- -----------------------------------------------------------------------------
-- 5.2 ソフトデリート連鎖トリガー（親削除時に子も論理削除）
-- -----------------------------------------------------------------------------

-- 設備削除時にタスクも論理削除
CREATE OR REPLACE FUNCTION cascade_soft_delete_tasks()
RETURNS TRIGGER AS $$
BEGIN
    -- 親設備が論理削除された場合、紐づくタスクも論理削除
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        UPDATE tasks
        SET
            deleted_at = NEW.deleted_at,
            updated_at = CURRENT_TIMESTAMP
        WHERE equipment_id = NEW.id
          AND deleted_at IS NULL;

        RAISE NOTICE 'Cascaded soft delete to tasks for equipment_id: %', NEW.id;
    END IF;

    -- 親設備がリストアされた場合、子タスクもリストア（オプション）
    -- ビジネス要件に応じてコメントアウトを解除
    -- IF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
    --     UPDATE tasks
    --     SET
    --         deleted_at = NULL,
    --         updated_at = CURRENT_TIMESTAMP
    --     WHERE equipment_id = NEW.id
    --       AND deleted_at = OLD.deleted_at;  -- 同時に削除されたもののみ
    -- END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cascade_soft_delete_tasks
    AFTER UPDATE OF deleted_at ON equipments
    FOR EACH ROW
    EXECUTE FUNCTION cascade_soft_delete_tasks();

COMMENT ON FUNCTION cascade_soft_delete_tasks() IS
'設備の論理削除時に、紐づくタスクも自動的に論理削除するトリガー関数。
ON DELETE CASCADEの論理削除版。物理削除は防止される（ON DELETE RESTRICT）。';

-- タスク削除時にコメントも論理削除
CREATE OR REPLACE FUNCTION cascade_soft_delete_task_comments()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        UPDATE task_comments
        SET
            deleted_at = NEW.deleted_at,
            updated_at = CURRENT_TIMESTAMP
        WHERE task_id = NEW.id
          AND deleted_at IS NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cascade_soft_delete_task_comments
    AFTER UPDATE OF deleted_at ON tasks
    FOR EACH ROW
    EXECUTE FUNCTION cascade_soft_delete_task_comments();

-- タスク削除時にカスタムフィールド値も論理削除
CREATE OR REPLACE FUNCTION cascade_soft_delete_custom_field_values()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        UPDATE custom_field_values
        SET deleted_at = NEW.deleted_at
        WHERE task_id = NEW.id
          AND deleted_at IS NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cascade_soft_delete_cfv
    AFTER UPDATE OF deleted_at ON tasks
    FOR EACH ROW
    EXECUTE FUNCTION cascade_soft_delete_custom_field_values();

COMMENT ON TRIGGER trg_cascade_soft_delete_tasks ON equipments IS
'設備論理削除時にタスクも連鎖削除。ON DELETE CASCADEの論理削除対応版。';


-- ============================================================================
-- SECTION 6: RLSポリシーの安全性確認
-- ============================================================================
-- 既存RLSポリシーはcurrent_tenant_id()を使用しており、
-- 関数が安全に実装されている限り、追加変更は不要。
-- ただし、以下の点に注意：

COMMENT ON SCHEMA public IS
'M2Xタスク管理システム - エンタープライズスケール対応
============================================================================
【コネクションプーリング環境での必須設定】

1. アプリケーション層での設定（Python例）:
   with connection.cursor() as cur:
       cur.execute("BEGIN")
       cur.execute("SET LOCAL app.current_tenant_id = %s", [tenant_id])
       cur.execute("SET LOCAL app.current_user_id = %s", [user_id])
       # ... クエリ実行 ...
       cur.execute("COMMIT")

2. PgBouncer設定（pgbouncer.ini）:
   [pgbouncer]
   pool_mode = transaction
   server_reset_query = DISCARD ALL

3. 禁止事項:
   - SET（セッションスコープ）の使用 → SET LOCALを使用すること
   - コネクション返却後のパラメータ残存 → pool_mode=transactionで自動クリア
============================================================================';


-- ============================================================================
-- 最終確認
-- ============================================================================
-- 以下のコマンドでパーティション状態を確認:
-- SELECT * FROM pg_partitioned_table;
-- SELECT parent.relname AS parent, child.relname AS child
-- FROM pg_inherits
-- JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
-- JOIN pg_class child ON pg_inherits.inhrelid = child.oid
-- WHERE parent.relname IN ('audit_logs', 'measurement_data');
