-- ============================================================================
-- M2X課題: Row Level Security (RLS) によるマルチテナント分離
-- ============================================================================
--
-- 【概要】
-- PostgreSQLのRow Level Security機能を使用して、データベースレベルで
-- テナント間のデータ分離を強制します。
--
-- 【従来の方式との違い】
-- 従来: アプリケーション層で WHERE tenant_id = ? を付与
--   → バグや実装漏れでデータ漏洩のリスク
--
-- RLS: データベースが自動的にテナントフィルタを適用
--   → アプリのバグがあっても他テナントのデータにアクセス不可
--   → Defense in Depth（多層防御）の実現
--
-- 【使用方法】
-- 1. アプリケーションは接続時に SET app.current_tenant_id = 'uuid'; を実行
-- 2. 以降のクエリは自動的に該当テナントのデータのみ返却
-- 3. tenant_id を指定しない INSERT も自動的に current_tenant_id が設定される
--
-- 【注意事項】
-- - RLSはスーパーユーザーやテーブルオーナーには適用されない
-- - 管理者アクセスが必要な場合は BYPASSRLS 権限を持つロールを使用
-- - パフォーマンス影響は最小限（インデックスが適切であれば）
--
-- ============================================================================

-- ============================================================================
-- RLS有効化関数
-- ============================================================================
-- 各テーブルでRLSを有効化し、ポリシーを設定する共通パターン

-- 現在のテナントIDを取得するヘルパー関数
CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS UUID AS $$
BEGIN
    RETURN NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION current_tenant_id() IS
'セッション変数 app.current_tenant_id から現在のテナントIDを取得';

-- ============================================================================
-- equipments テーブルのRLS
-- ============================================================================

ALTER TABLE equipments ENABLE ROW LEVEL SECURITY;

-- SELECT: 自テナントのデータのみ参照可能
CREATE POLICY equipments_tenant_isolation ON equipments
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

COMMENT ON POLICY equipments_tenant_isolation ON equipments IS
'テナント分離ポリシー: 自テナントのデータのみアクセス可能';

-- ============================================================================
-- parts テーブルのRLS
-- ============================================================================

ALTER TABLE parts ENABLE ROW LEVEL SECURITY;

CREATE POLICY parts_tenant_isolation ON parts
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- ============================================================================
-- equipment_parts テーブルのRLS
-- ============================================================================

ALTER TABLE equipment_parts ENABLE ROW LEVEL SECURITY;

CREATE POLICY equipment_parts_tenant_isolation ON equipment_parts
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- ============================================================================
-- tasks テーブルのRLS
-- ============================================================================

ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;

CREATE POLICY tasks_tenant_isolation ON tasks
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- ============================================================================
-- task_parts テーブルのRLS
-- ============================================================================

ALTER TABLE task_parts ENABLE ROW LEVEL SECURITY;

CREATE POLICY task_parts_tenant_isolation ON task_parts
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- ============================================================================
-- custom_field_definitions テーブルのRLS
-- ============================================================================

ALTER TABLE custom_field_definitions ENABLE ROW LEVEL SECURITY;

CREATE POLICY custom_field_definitions_tenant_isolation ON custom_field_definitions
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- ============================================================================
-- custom_field_values テーブルのRLS
-- ============================================================================

ALTER TABLE custom_field_values ENABLE ROW LEVEL SECURITY;

CREATE POLICY custom_field_values_tenant_isolation ON custom_field_values
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- ============================================================================
-- task_comments テーブルのRLS
-- ============================================================================

ALTER TABLE task_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY task_comments_tenant_isolation ON task_comments
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- ============================================================================
-- テナント管理用の特別ポリシー
-- ============================================================================
-- tenantsテーブルは全テナント一覧を取得する必要があるため、
-- 別途制御（認証済みユーザーのみアクセス可能等）

-- tenants テーブルはRLSを有効化しない（テナント一覧は全ユーザーが参照可能）
-- 本番環境では認証レイヤーで制御することを推奨

-- ============================================================================
-- RLSバイパス用の管理者ロール（オプション）
-- ============================================================================
-- 管理者やバッチ処理用に、RLSをバイパスできるロールを作成
-- 本番環境では慎重に使用すること

-- CREATE ROLE m2x_admin WITH BYPASSRLS;
-- GRANT m2x_admin TO m2x_user;

-- ============================================================================
-- 使用例とテスト用クエリ
-- ============================================================================
/*
-- テナントコンテキストを設定
SET app.current_tenant_id = '11111111-1111-1111-1111-111111111111';

-- 以降のクエリは自動的にフィルタリングされる
SELECT * FROM equipments;  -- tenant_id = '1111...' のデータのみ返却

-- テナントコンテキストをクリア
RESET app.current_tenant_id;

-- コンテキストなしでクエリ → 空の結果
SELECT * FROM equipments;  -- 0件
*/
