-- ============================================================================
-- M2X: 業種横断拡張スキーマ
-- ============================================================================
--
-- あらゆる業種の工場・施設で利用可能な汎用設計
--
-- 【対応業種】
-- - 製造工場（自動車、電子機器、機械、鉄鋼）
-- - 水道施設（浄水場、配水場、ポンプ場）
-- - 電力施設（発電所、変電所）
-- - 食品工場（HACCP対応）
-- - 化学プラント（危険物取扱）
-- - 製薬工場（GMP対応）
-- - 半導体工場（クリーンルーム）
--
-- 【設計思想】
-- 1. 業種非依存のコアモデル + 業種固有のカスタマイズ
-- 2. 計測データの時系列管理（IoTセンサー対応）
-- 3. 規制・コンプライアンス対応（HACCP, GMP, ISO等）
-- 4. 安全管理・作業許可証（PTW）ワークフロー
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: 設備カテゴリ・タイプ管理
-- ============================================================================
-- 業種別の設備分類を柔軟に定義

CREATE TABLE equipment_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- カテゴリ情報
    code VARCHAR(50) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,

    -- 階層構造
    parent_category_id UUID REFERENCES equipment_categories(id),
    level INTEGER DEFAULT 0,

    -- 業種タグ（複数業種で共通利用可能）
    industry_tags TEXT[] DEFAULT '{}',
    -- 例: ['manufacturing', 'water', 'power', 'food', 'chemical', 'pharma']

    -- メタデータ
    icon VARCHAR(100),
    color VARCHAR(7),
    sort_order INTEGER DEFAULT 0,

    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_equipment_category UNIQUE (tenant_id, code)
);

CREATE INDEX idx_equipment_categories_tenant ON equipment_categories(tenant_id);
CREATE INDEX idx_equipment_categories_parent ON equipment_categories(parent_category_id);
CREATE INDEX idx_equipment_categories_industry ON equipment_categories USING GIN (industry_tags);

COMMENT ON TABLE equipment_categories IS '設備カテゴリマスタ（業種横断）';

-- 設備タイプ（カテゴリの下位分類）
CREATE TABLE equipment_types (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    category_id UUID NOT NULL REFERENCES equipment_categories(id) ON DELETE CASCADE,

    -- タイプ情報
    code VARCHAR(50) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,

    -- 標準属性定義（このタイプの設備が持つべき属性）
    standard_attributes JSONB DEFAULT '[]',
    -- 例: [{"key": "capacity", "label": "容量", "type": "number", "unit": "kW"}]

    -- 標準点検項目
    standard_inspection_items JSONB DEFAULT '[]',
    -- 例: [{"item": "油量確認", "frequency": "daily"}, {"item": "絶縁抵抗測定", "frequency": "monthly"}]

    -- 法定点検要件
    regulatory_requirements JSONB DEFAULT '[]',
    -- 例: [{"regulation": "電気事業法", "inspection": "定期点検", "frequency_months": 12}]

    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_equipment_type UNIQUE (tenant_id, category_id, code)
);

CREATE INDEX idx_equipment_types_tenant ON equipment_types(tenant_id);
CREATE INDEX idx_equipment_types_category ON equipment_types(category_id);

COMMENT ON TABLE equipment_types IS '設備タイプマスタ（カテゴリ詳細分類）';

-- 設備にカテゴリ・タイプを紐付け
ALTER TABLE equipments ADD COLUMN IF NOT EXISTS category_id UUID REFERENCES equipment_categories(id);
ALTER TABLE equipments ADD COLUMN IF NOT EXISTS type_id UUID REFERENCES equipment_types(id);
ALTER TABLE equipments ADD COLUMN IF NOT EXISTS attributes JSONB DEFAULT '{}';
ALTER TABLE equipments ADD COLUMN IF NOT EXISTS location VARCHAR(255);
ALTER TABLE equipments ADD COLUMN IF NOT EXISTS installation_date DATE;
ALTER TABLE equipments ADD COLUMN IF NOT EXISTS warranty_expiry DATE;
ALTER TABLE equipments ADD COLUMN IF NOT EXISTS criticality VARCHAR(20) DEFAULT 'medium';

CREATE INDEX idx_equipments_category ON equipments(category_id);
CREATE INDEX idx_equipments_type ON equipments(type_id);
CREATE INDEX idx_equipments_criticality ON equipments(tenant_id, criticality);

-- ============================================================================
-- SECTION 2: 計測ポイント・センサー管理
-- ============================================================================
-- IoTセンサー、計器からのデータ収集基盤

CREATE TYPE measurement_data_type AS ENUM (
    'numeric',      -- 数値（温度、圧力、流量等）
    'boolean',      -- ON/OFF、開/閉
    'text',         -- 文字列
    'enum'          -- 選択肢
);

CREATE TYPE measurement_unit_category AS ENUM (
    'temperature',  -- 温度（℃, °F, K）
    'pressure',     -- 圧力（Pa, bar, psi, mmHg）
    'flow',         -- 流量（m³/h, L/min, GPM）
    'level',        -- 液位（m, mm, %）
    'electrical',   -- 電気（V, A, W, Hz, Ω）
    'concentration',-- 濃度（ppm, %, mg/L）
    'speed',        -- 速度（rpm, m/s）
    'weight',       -- 重量（kg, t）
    'time',         -- 時間（s, min, h）
    'dimensionless' -- 無次元（pH, 比重）
);

-- 計測ポイント定義
CREATE TABLE measurement_points (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    equipment_id UUID NOT NULL REFERENCES equipments(id) ON DELETE CASCADE,

    -- ポイント識別
    point_code VARCHAR(100) NOT NULL,
    point_name VARCHAR(255) NOT NULL,
    description TEXT,

    -- データ型
    data_type measurement_data_type NOT NULL DEFAULT 'numeric',
    unit_category measurement_unit_category,
    unit VARCHAR(20),
    enum_values TEXT[],  -- data_type='enum'の場合の選択肢

    -- 正常範囲（アラート判定用）
    normal_min DECIMAL(15,4),
    normal_max DECIMAL(15,4),
    warning_min DECIMAL(15,4),
    warning_max DECIMAL(15,4),
    critical_min DECIMAL(15,4),
    critical_max DECIMAL(15,4),

    -- サンプリング設定
    sampling_interval_seconds INTEGER,
    is_manual_entry BOOLEAN DEFAULT FALSE,

    -- タグ（業種別分類）
    tags TEXT[] DEFAULT '{}',
    -- 例: ['water_quality', 'haccp_ccp', 'environmental']

    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_measurement_point UNIQUE (tenant_id, equipment_id, point_code)
);

CREATE INDEX idx_measurement_points_tenant ON measurement_points(tenant_id);
CREATE INDEX idx_measurement_points_equipment ON measurement_points(equipment_id);
CREATE INDEX idx_measurement_points_tags ON measurement_points USING GIN (tags);

COMMENT ON TABLE measurement_points IS '計測ポイント定義（センサー・計器）';

-- 計測データ（時系列）
CREATE TABLE measurement_data (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    point_id UUID NOT NULL REFERENCES measurement_points(id) ON DELETE CASCADE,

    -- 計測値
    measured_at TIMESTAMP WITH TIME ZONE NOT NULL,
    numeric_value DECIMAL(15,4),
    text_value TEXT,
    boolean_value BOOLEAN,

    -- 品質フラグ
    quality VARCHAR(20) DEFAULT 'good',  -- 'good', 'uncertain', 'bad', 'manual'

    -- 異常検知
    is_anomaly BOOLEAN DEFAULT FALSE,
    anomaly_type VARCHAR(50),  -- 'out_of_range', 'spike', 'flatline'

    -- 入力者（手動入力の場合）
    recorded_by UUID REFERENCES users(id),

    -- パーティショニング用
    year_month VARCHAR(7)
);

-- 時系列クエリ最適化
CREATE INDEX idx_measurement_data_point_time ON measurement_data(point_id, measured_at DESC);
CREATE INDEX idx_measurement_data_time ON measurement_data USING BRIN (measured_at);
CREATE INDEX idx_measurement_data_anomaly ON measurement_data(point_id, measured_at DESC) WHERE is_anomaly = TRUE;
CREATE INDEX idx_measurement_data_year_month ON measurement_data(year_month, point_id);

-- パーティショニング用トリガー
CREATE OR REPLACE FUNCTION set_measurement_year_month()
RETURNS TRIGGER AS $$
BEGIN
    NEW.year_month := TO_CHAR(NEW.measured_at, 'YYYY-MM');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_measurement_year_month
    BEFORE INSERT ON measurement_data
    FOR EACH ROW EXECUTE FUNCTION set_measurement_year_month();

COMMENT ON TABLE measurement_data IS '計測データ（時系列）';

-- ============================================================================
-- SECTION 3: 点検チェックリスト管理
-- ============================================================================
-- 定期点検のテンプレート化と記録

CREATE TYPE inspection_frequency AS ENUM (
    'hourly',       -- 毎時
    'shift',        -- シフト毎
    'daily',        -- 日次
    'weekly',       -- 週次
    'biweekly',     -- 隔週
    'monthly',      -- 月次
    'quarterly',    -- 四半期
    'semiannual',   -- 半年
    'annual',       -- 年次
    'as_needed'     -- 随時
);

CREATE TYPE inspection_item_type AS ENUM (
    'visual',       -- 目視確認
    'measurement',  -- 計測
    'functional',   -- 機能確認
    'cleaning',     -- 清掃
    'lubrication',  -- 給油
    'replacement',  -- 交換
    'calibration',  -- 校正
    'safety'        -- 安全確認
);

-- 点検テンプレート
CREATE TABLE inspection_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- テンプレート情報
    template_code VARCHAR(50) NOT NULL,
    template_name VARCHAR(255) NOT NULL,
    description TEXT,

    -- 対象設備
    equipment_type_id UUID REFERENCES equipment_types(id),
    equipment_category_id UUID REFERENCES equipment_categories(id),

    -- 頻度
    frequency inspection_frequency NOT NULL DEFAULT 'daily',
    estimated_duration_minutes INTEGER,

    -- 規制関連
    is_regulatory BOOLEAN DEFAULT FALSE,
    regulation_reference TEXT,

    -- 業種タグ
    industry_tags TEXT[] DEFAULT '{}',

    is_active BOOLEAN DEFAULT TRUE,
    version INTEGER DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_inspection_template UNIQUE (tenant_id, template_code)
);

CREATE INDEX idx_inspection_templates_tenant ON inspection_templates(tenant_id);
CREATE INDEX idx_inspection_templates_type ON inspection_templates(equipment_type_id);

COMMENT ON TABLE inspection_templates IS '点検テンプレート定義';

-- 点検項目
CREATE TABLE inspection_template_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id UUID NOT NULL REFERENCES inspection_templates(id) ON DELETE CASCADE,

    -- 項目情報
    item_order INTEGER NOT NULL,
    item_code VARCHAR(50),
    item_name VARCHAR(500) NOT NULL,
    description TEXT,

    -- 項目タイプ
    item_type inspection_item_type NOT NULL DEFAULT 'visual',

    -- 入力形式
    input_type VARCHAR(20) NOT NULL DEFAULT 'checkbox',
    -- 'checkbox', 'number', 'text', 'select', 'photo', 'signature'

    -- 数値入力の場合
    unit VARCHAR(20),
    min_value DECIMAL(15,4),
    max_value DECIMAL(15,4),

    -- 選択肢（select型）
    options JSONB,
    -- 例: [{"value": "OK", "label": "良好"}, {"value": "NG", "label": "不良"}]

    -- 必須・安全項目
    is_required BOOLEAN DEFAULT TRUE,
    is_safety_critical BOOLEAN DEFAULT FALSE,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_inspection_items_template ON inspection_template_items(template_id, item_order);

COMMENT ON TABLE inspection_template_items IS '点検テンプレート項目';

-- 点検記録
CREATE TABLE inspection_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    template_id UUID NOT NULL REFERENCES inspection_templates(id),
    equipment_id UUID NOT NULL REFERENCES equipments(id),

    -- 記録番号
    record_number VARCHAR(50) NOT NULL,

    -- 実施情報
    scheduled_date DATE,
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,

    -- 実施者・承認者
    inspector_id UUID REFERENCES users(id),
    inspector_name VARCHAR(255),
    approver_id UUID REFERENCES users(id),
    approved_at TIMESTAMP WITH TIME ZONE,

    -- 結果
    status VARCHAR(20) DEFAULT 'draft',
    -- 'draft', 'in_progress', 'completed', 'approved', 'rejected'
    overall_result VARCHAR(20),
    -- 'pass', 'fail', 'conditional'

    -- 異常・フォローアップ
    has_issues BOOLEAN DEFAULT FALSE,
    issue_count INTEGER DEFAULT 0,
    followup_task_id UUID REFERENCES tasks(id),

    -- コメント
    notes TEXT,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_inspection_record UNIQUE (tenant_id, record_number)
);

CREATE INDEX idx_inspection_records_tenant ON inspection_records(tenant_id);
CREATE INDEX idx_inspection_records_equipment ON inspection_records(equipment_id, scheduled_date DESC);
CREATE INDEX idx_inspection_records_status ON inspection_records(tenant_id, status);

COMMENT ON TABLE inspection_records IS '点検記録';

-- 点検記録詳細（各項目の結果）
CREATE TABLE inspection_record_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    record_id UUID NOT NULL REFERENCES inspection_records(id) ON DELETE CASCADE,
    template_item_id UUID NOT NULL REFERENCES inspection_template_items(id),

    -- 結果
    result VARCHAR(20),  -- 'ok', 'ng', 'na', 'pending'
    numeric_value DECIMAL(15,4),
    text_value TEXT,
    photo_urls JSONB DEFAULT '[]',

    -- 異常詳細
    is_issue BOOLEAN DEFAULT FALSE,
    issue_description TEXT,
    corrective_action TEXT,

    checked_at TIMESTAMP WITH TIME ZONE,
    checked_by UUID REFERENCES users(id)
);

CREATE INDEX idx_inspection_record_items ON inspection_record_items(record_id);

COMMENT ON TABLE inspection_record_items IS '点検記録項目詳細';

-- ============================================================================
-- SECTION 4: 作業許可証（Permit to Work）
-- ============================================================================
-- 危険作業の承認ワークフロー

CREATE TYPE ptw_type AS ENUM (
    'hot_work',         -- 火気使用作業
    'confined_space',   -- 閉所作業
    'electrical',       -- 電気作業
    'height_work',      -- 高所作業
    'excavation',       -- 掘削作業
    'chemical',         -- 化学物質取扱
    'radiation',        -- 放射線作業
    'lockout_tagout',   -- LOTO（エネルギー遮断）
    'general'           -- 一般作業許可
);

CREATE TYPE ptw_status AS ENUM (
    'draft',            -- 下書き
    'submitted',        -- 申請中
    'risk_assessment',  -- リスクアセスメント中
    'pending_approval', -- 承認待ち
    'approved',         -- 承認済み
    'active',           -- 作業中
    'suspended',        -- 一時停止
    'completed',        -- 完了
    'cancelled',        -- キャンセル
    'expired'           -- 期限切れ
);

CREATE TABLE work_permits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- 許可証番号
    permit_number VARCHAR(50) NOT NULL,
    permit_type ptw_type NOT NULL,

    -- 作業内容
    work_title VARCHAR(500) NOT NULL,
    work_description TEXT,
    work_location VARCHAR(500),

    -- 対象設備
    equipment_id UUID REFERENCES equipments(id),

    -- 作業予定
    planned_start TIMESTAMP WITH TIME ZONE NOT NULL,
    planned_end TIMESTAMP WITH TIME ZONE NOT NULL,
    actual_start TIMESTAMP WITH TIME ZONE,
    actual_end TIMESTAMP WITH TIME ZONE,

    -- 申請者・作業責任者
    requester_id UUID NOT NULL REFERENCES users(id),
    work_supervisor_id UUID REFERENCES users(id),
    work_supervisor_name VARCHAR(255),

    -- 作業員リスト
    workers JSONB DEFAULT '[]',
    -- [{"name": "山田太郎", "company": "協力会社A", "qualification": "電気工事士"}]

    -- ステータス
    status ptw_status DEFAULT 'draft',

    -- リスクアセスメント
    hazards_identified JSONB DEFAULT '[]',
    -- [{"hazard": "感電", "risk_level": "high", "control_measures": ["電源遮断", "検電"]}]
    safety_measures JSONB DEFAULT '[]',
    -- [{"measure": "消火器設置", "responsible": "山田"}]
    ppe_required TEXT[],
    -- ['helmet', 'safety_glasses', 'gloves', 'safety_shoes']

    -- 承認
    approved_by UUID REFERENCES users(id),
    approved_at TIMESTAMP WITH TIME ZONE,
    approval_notes TEXT,

    -- 完了確認
    closed_by UUID REFERENCES users(id),
    closed_at TIMESTAMP WITH TIME ZONE,
    close_notes TEXT,

    -- 関連タスク
    related_task_id UUID REFERENCES tasks(id),

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_work_permit UNIQUE (tenant_id, permit_number)
);

CREATE INDEX idx_work_permits_tenant ON work_permits(tenant_id);
CREATE INDEX idx_work_permits_status ON work_permits(tenant_id, status);
CREATE INDEX idx_work_permits_equipment ON work_permits(equipment_id);
CREATE INDEX idx_work_permits_dates ON work_permits(planned_start, planned_end);

COMMENT ON TABLE work_permits IS '作業許可証（PTW: Permit to Work）';

-- ============================================================================
-- SECTION 5: インシデント・安全管理
-- ============================================================================
-- 事故、ヒヤリハット、安全観察の記録

CREATE TYPE incident_type AS ENUM (
    'accident',         -- 事故（人身被害あり）
    'near_miss',        -- ヒヤリハット
    'property_damage',  -- 物損
    'environmental',    -- 環境事故
    'quality',          -- 品質問題
    'safety_observation'-- 安全観察
);

CREATE TYPE incident_severity AS ENUM (
    'minor',            -- 軽微
    'moderate',         -- 中程度
    'serious',          -- 重大
    'critical',         -- 致命的
    'catastrophic'      -- 壊滅的
);

CREATE TABLE incidents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- インシデント番号
    incident_number VARCHAR(50) NOT NULL,
    incident_type incident_type NOT NULL,
    severity incident_severity NOT NULL DEFAULT 'minor',

    -- 発生情報
    title VARCHAR(500) NOT NULL,
    description TEXT NOT NULL,
    occurred_at TIMESTAMP WITH TIME ZONE NOT NULL,
    discovered_at TIMESTAMP WITH TIME ZONE,
    location VARCHAR(500),

    -- 関連設備
    equipment_id UUID REFERENCES equipments(id),

    -- 関係者
    reported_by UUID REFERENCES users(id),
    reported_by_name VARCHAR(255),
    involved_persons JSONB DEFAULT '[]',
    -- [{"name": "山田太郎", "role": "operator", "injury": "none"}]

    -- 被害状況
    injury_details TEXT,
    property_damage_details TEXT,
    environmental_impact TEXT,
    production_impact TEXT,

    -- 原因分析
    immediate_cause TEXT,
    root_causes JSONB DEFAULT '[]',
    -- [{"category": "human", "cause": "手順不遵守"}, {"category": "equipment", "cause": "安全装置不備"}]
    contributing_factors TEXT,

    -- 是正措置
    immediate_actions TEXT,
    corrective_actions JSONB DEFAULT '[]',
    -- [{"action": "安全教育実施", "responsible": "安全課", "due_date": "2024-02-01", "status": "completed"}]
    preventive_actions JSONB DEFAULT '[]',

    -- ステータス
    status VARCHAR(20) DEFAULT 'reported',
    -- 'reported', 'investigating', 'analyzed', 'actions_planned', 'actions_completed', 'closed'

    -- 調査
    investigation_lead_id UUID REFERENCES users(id),
    investigation_team JSONB DEFAULT '[]',
    investigation_started_at TIMESTAMP WITH TIME ZONE,
    investigation_completed_at TIMESTAMP WITH TIME ZONE,

    -- クローズ
    closed_by UUID REFERENCES users(id),
    closed_at TIMESTAMP WITH TIME ZONE,
    lessons_learned TEXT,

    -- 外部報告
    requires_external_report BOOLEAN DEFAULT FALSE,
    external_report_details JSONB,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_incident UNIQUE (tenant_id, incident_number)
);

CREATE INDEX idx_incidents_tenant ON incidents(tenant_id);
CREATE INDEX idx_incidents_type_severity ON incidents(tenant_id, incident_type, severity);
CREATE INDEX idx_incidents_equipment ON incidents(equipment_id);
CREATE INDEX idx_incidents_time ON incidents(tenant_id, occurred_at DESC);
CREATE INDEX idx_incidents_status ON incidents(tenant_id, status);

COMMENT ON TABLE incidents IS 'インシデント管理（事故・ヒヤリハット）';

-- ============================================================================
-- SECTION 6: シフト・作業員管理
-- ============================================================================

CREATE TABLE shifts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- シフト情報
    shift_code VARCHAR(20) NOT NULL,
    shift_name VARCHAR(100) NOT NULL,

    -- 時間帯
    start_time TIME NOT NULL,
    end_time TIME NOT NULL,
    crosses_midnight BOOLEAN DEFAULT FALSE,

    -- 休憩
    break_duration_minutes INTEGER DEFAULT 60,

    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_shift UNIQUE (tenant_id, shift_code)
);

COMMENT ON TABLE shifts IS 'シフトマスタ';

-- シフト割当
CREATE TABLE shift_assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    shift_id UUID NOT NULL REFERENCES shifts(id),

    -- 日付
    assignment_date DATE NOT NULL,

    -- エリア・設備担当
    assigned_area VARCHAR(255),
    assigned_equipment_id UUID REFERENCES equipments(id),

    -- 役割
    role VARCHAR(100),  -- 'leader', 'operator', 'support'

    -- 実績
    actual_start TIMESTAMP WITH TIME ZONE,
    actual_end TIMESTAMP WITH TIME ZONE,

    notes TEXT,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_shift_assignment UNIQUE (tenant_id, user_id, assignment_date, shift_id)
);

CREATE INDEX idx_shift_assignments_tenant ON shift_assignments(tenant_id);
CREATE INDEX idx_shift_assignments_user ON shift_assignments(user_id, assignment_date);
CREATE INDEX idx_shift_assignments_date ON shift_assignments(tenant_id, assignment_date);

COMMENT ON TABLE shift_assignments IS 'シフト割当';

-- ============================================================================
-- SECTION 7: 業種別ビュー
-- ============================================================================

-- 水道施設向け: 水質データサマリー
CREATE OR REPLACE VIEW v_water_quality_summary AS
SELECT
    mp.tenant_id,
    e.name AS equipment_name,
    mp.point_name,
    mp.unit,
    AVG(md.numeric_value) AS avg_value,
    MIN(md.numeric_value) AS min_value,
    MAX(md.numeric_value) AS max_value,
    COUNT(*) AS sample_count,
    COUNT(*) FILTER (WHERE md.is_anomaly) AS anomaly_count,
    DATE_TRUNC('day', md.measured_at) AS measurement_date
FROM measurement_points mp
JOIN equipments e ON mp.equipment_id = e.id
JOIN measurement_data md ON mp.id = md.point_id
WHERE 'water_quality' = ANY(mp.tags)
GROUP BY mp.tenant_id, e.name, mp.point_name, mp.unit, DATE_TRUNC('day', md.measured_at);

COMMENT ON VIEW v_water_quality_summary IS '水質データ日次サマリー（水道施設向け）';

-- 食品工場向け: HACCP温度管理
CREATE OR REPLACE VIEW v_haccp_temperature_monitoring AS
SELECT
    mp.tenant_id,
    e.name AS equipment_name,
    mp.point_name,
    md.measured_at,
    md.numeric_value AS temperature,
    mp.normal_min,
    mp.normal_max,
    CASE
        WHEN md.numeric_value < mp.critical_min OR md.numeric_value > mp.critical_max THEN 'CRITICAL'
        WHEN md.numeric_value < mp.warning_min OR md.numeric_value > mp.warning_max THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM measurement_points mp
JOIN equipments e ON mp.equipment_id = e.id
JOIN measurement_data md ON mp.id = md.point_id
WHERE 'haccp_ccp' = ANY(mp.tags)
  AND mp.unit_category = 'temperature';

COMMENT ON VIEW v_haccp_temperature_monitoring IS 'HACCP温度モニタリング（食品工場向け）';

-- 設備稼働状況ダッシュボード
CREATE OR REPLACE VIEW v_equipment_status_dashboard AS
SELECT
    e.tenant_id,
    ec.name AS category_name,
    e.name AS equipment_name,
    e.criticality,
    -- 最新の点検
    (SELECT ir.completed_at
     FROM inspection_records ir
     WHERE ir.equipment_id = e.id AND ir.status = 'approved'
     ORDER BY ir.completed_at DESC LIMIT 1) AS last_inspection_at,
    -- オープンタスク数
    (SELECT COUNT(*)
     FROM tasks t
     WHERE t.equipment_id = e.id AND t.status != 'done' AND t.deleted_at IS NULL) AS open_tasks,
    -- 直近30日のインシデント数
    (SELECT COUNT(*)
     FROM incidents i
     WHERE i.equipment_id = e.id AND i.occurred_at > CURRENT_TIMESTAMP - INTERVAL '30 days') AS incidents_30d,
    -- アクティブな作業許可証
    (SELECT COUNT(*)
     FROM work_permits wp
     WHERE wp.equipment_id = e.id AND wp.status IN ('approved', 'active')) AS active_permits
FROM equipments e
LEFT JOIN equipment_categories ec ON e.category_id = ec.id
WHERE e.deleted_at IS NULL;

COMMENT ON VIEW v_equipment_status_dashboard IS '設備状況ダッシュボード';

-- ============================================================================
-- SECTION 8: ヘルパー関数
-- ============================================================================

-- 次回点検日計算
CREATE OR REPLACE FUNCTION calculate_next_inspection_date(
    p_equipment_id UUID,
    p_template_id UUID
)
RETURNS DATE AS $$
DECLARE
    last_inspection_date DATE;
    freq inspection_frequency;
    next_date DATE;
BEGIN
    -- 最新の点検日を取得
    SELECT DATE(ir.completed_at), it.frequency
    INTO last_inspection_date, freq
    FROM inspection_records ir
    JOIN inspection_templates it ON ir.template_id = it.id
    WHERE ir.equipment_id = p_equipment_id
      AND ir.template_id = p_template_id
      AND ir.status = 'approved'
    ORDER BY ir.completed_at DESC
    LIMIT 1;

    IF last_inspection_date IS NULL THEN
        RETURN CURRENT_DATE;
    END IF;

    -- 頻度に応じて次回日を計算
    next_date := CASE freq
        WHEN 'daily' THEN last_inspection_date + INTERVAL '1 day'
        WHEN 'weekly' THEN last_inspection_date + INTERVAL '1 week'
        WHEN 'biweekly' THEN last_inspection_date + INTERVAL '2 weeks'
        WHEN 'monthly' THEN last_inspection_date + INTERVAL '1 month'
        WHEN 'quarterly' THEN last_inspection_date + INTERVAL '3 months'
        WHEN 'semiannual' THEN last_inspection_date + INTERVAL '6 months'
        WHEN 'annual' THEN last_inspection_date + INTERVAL '1 year'
        ELSE last_inspection_date + INTERVAL '1 day'
    END;

    RETURN next_date;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION calculate_next_inspection_date IS '次回点検予定日を計算';

-- 計測データの統計取得
CREATE OR REPLACE FUNCTION get_measurement_statistics(
    p_point_id UUID,
    p_start_time TIMESTAMP WITH TIME ZONE,
    p_end_time TIMESTAMP WITH TIME ZONE
)
RETURNS TABLE (
    point_id UUID,
    avg_value DECIMAL,
    min_value DECIMAL,
    max_value DECIMAL,
    std_dev DECIMAL,
    sample_count BIGINT,
    anomaly_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        p_point_id,
        AVG(md.numeric_value)::DECIMAL,
        MIN(md.numeric_value)::DECIMAL,
        MAX(md.numeric_value)::DECIMAL,
        STDDEV(md.numeric_value)::DECIMAL,
        COUNT(*)::BIGINT,
        COUNT(*) FILTER (WHERE md.is_anomaly)::BIGINT
    FROM measurement_data md
    WHERE md.point_id = p_point_id
      AND md.measured_at BETWEEN p_start_time AND p_end_time;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_measurement_statistics IS '計測データの統計情報を取得';

-- ============================================================================
-- RLS ポリシー追加
-- ============================================================================

ALTER TABLE equipment_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE measurement_points ENABLE ROW LEVEL SECURITY;
ALTER TABLE measurement_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE inspection_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE inspection_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_permits ENABLE ROW LEVEL SECURITY;
ALTER TABLE incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE shift_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON equipment_categories
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);
CREATE POLICY tenant_isolation ON equipment_types
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);
CREATE POLICY tenant_isolation ON measurement_points
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);
CREATE POLICY tenant_isolation ON measurement_data
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);
CREATE POLICY tenant_isolation ON inspection_templates
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);
CREATE POLICY tenant_isolation ON inspection_records
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);
CREATE POLICY tenant_isolation ON work_permits
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);
CREATE POLICY tenant_isolation ON incidents
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);
CREATE POLICY tenant_isolation ON shifts
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);
CREATE POLICY tenant_isolation ON shift_assignments
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);

-- ============================================================================
-- 完了
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '============================================================';
    RAISE NOTICE '業種横断拡張スキーママイグレーション完了';
    RAISE NOTICE '============================================================';
    RAISE NOTICE '';
    RAISE NOTICE '【追加機能】';
    RAISE NOTICE '  1. 設備カテゴリ・タイプ管理';
    RAISE NOTICE '  2. 計測ポイント・センサーデータ（IoT対応）';
    RAISE NOTICE '  3. 点検チェックリスト（テンプレート化）';
    RAISE NOTICE '  4. 作業許可証（PTW: Permit to Work）';
    RAISE NOTICE '  5. インシデント・安全管理';
    RAISE NOTICE '  6. シフト・作業員管理';
    RAISE NOTICE '';
    RAISE NOTICE '【対応業種】';
    RAISE NOTICE '  製造工場 / 水道施設 / 電力施設 / 食品工場';
    RAISE NOTICE '  化学プラント / 製薬工場 / 半導体工場';
    RAISE NOTICE '============================================================';
END;
$$;
