-- ============================================================================
-- M2X課題: シードデータ（サンプルデータ）
-- ============================================================================
-- 画面イメージに基づいたサンプルデータを投入
-- マルチテナント環境での動作確認用

-- ============================================================================
-- テナント
-- ============================================================================
INSERT INTO tenants (id, name) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Tanaka Manufacturing Co., Ltd.'),
    ('22222222-2222-2222-2222-222222222222', 'Yamamoto Electronics Factory');

-- ============================================================================
-- 設備（階層構造の例）
-- ============================================================================
-- Tanaka Manufacturing の設備
INSERT INTO equipments (id, tenant_id, parent_equipment_id, name, manufacturer, description) VALUES
    -- トップレベル設備（ライン）
    ('aaaa0001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', NULL, 'Assembly Line A', 'ABC Company', 'Main assembly line for Product X'),
    ('aaaa0001-0001-0001-0001-000000000002', '11111111-1111-1111-1111-111111111111', NULL, 'Assembly Line B', 'ABC Company', 'Secondary assembly line'),
    ('aaaa0001-0001-0001-0001-000000000003', '11111111-1111-1111-1111-111111111111', NULL, 'Packaging Line', 'XYZ Industries', 'Final packaging and shipping preparation'),
    -- 子設備（Line A の機械）
    ('aaaa0001-0001-0001-0001-000000000011', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000001', 'Conveyor Belt A-1', 'Conveyor Tech Inc.', 'Main conveyor for Line A'),
    ('aaaa0001-0001-0001-0001-000000000012', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000001', 'Robot Arm A-1', 'RoboArm Corp.', 'Automated assembly robot'),
    ('aaaa0001-0001-0001-0001-000000000013', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000001', 'Quality Scanner A-1', 'Vision Systems Ltd.', 'Visual inspection system');

-- Yamamoto Electronics の設備
INSERT INTO equipments (id, tenant_id, parent_equipment_id, name, manufacturer, description) VALUES
    ('bbbb0001-0001-0001-0001-000000000001', '22222222-2222-2222-2222-222222222222', NULL, 'SMT Line 1', 'SMT Solutions', 'Surface Mount Technology line'),
    ('bbbb0001-0001-0001-0001-000000000002', '22222222-2222-2222-2222-222222222222', NULL, 'Testing Station', 'TestEquip Co.', 'Quality assurance testing');

-- ============================================================================
-- 部品
-- ============================================================================
-- Tanaka Manufacturing の部品
INSERT INTO parts (id, tenant_id, name, part_number, location, description, stock_quantity, reorder_point) VALUES
    ('cccc0001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', 'Conveyor Belt (3m)', 'CB-3M-001', 'Warehouse A', 'Heavy-duty rubber conveyor belt', 15, 5),
    ('cccc0001-0001-0001-0001-000000000002', '11111111-1111-1111-1111-111111111111', 'Drive Motor 500W', 'DM-500W-002', 'Warehouse A', 'Industrial grade motor', 8, 3),
    ('cccc0001-0001-0001-0001-000000000003', '11111111-1111-1111-1111-111111111111', 'Proximity Sensor', 'PS-IR-003', 'Building 2', 'Infrared proximity sensor', 25, 10),
    ('cccc0001-0001-0001-0001-000000000004', '11111111-1111-1111-1111-111111111111', 'Robot Gripper Unit', 'RG-A1-004', 'Building 2', 'Pneumatic gripper assembly', 4, 2),
    ('cccc0001-0001-0001-0001-000000000005', '11111111-1111-1111-1111-111111111111', 'Control Board v2', 'CB-V2-005', 'Electronics Room', 'PLC control board', 6, 3);

-- Yamamoto Electronics の部品
INSERT INTO parts (id, tenant_id, name, part_number, location, description, stock_quantity, reorder_point) VALUES
    ('dddd0001-0001-0001-0001-000000000001', '22222222-2222-2222-2222-222222222222', 'Solder Paste (500g)', 'SP-500-001', 'Cold Storage', 'Lead-free solder paste', 20, 8),
    ('dddd0001-0001-0001-0001-000000000002', '22222222-2222-2222-2222-222222222222', 'PCB Holder Jig', 'PH-STD-002', 'Tool Room', 'Standard PCB holding fixture', 12, 4);

-- ============================================================================
-- 設備・部品関連
-- ============================================================================
INSERT INTO equipment_parts (id, tenant_id, equipment_id, part_id) VALUES
    -- Conveyor Belt A-1 に必要な部品
    ('eeee0001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000011', 'cccc0001-0001-0001-0001-000000000001'),
    ('eeee0001-0001-0001-0001-000000000002', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000011', 'cccc0001-0001-0001-0001-000000000002'),
    ('eeee0001-0001-0001-0001-000000000003', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000011', 'cccc0001-0001-0001-0001-000000000003'),
    -- Robot Arm A-1 に必要な部品
    ('eeee0001-0001-0001-0001-000000000004', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000012', 'cccc0001-0001-0001-0001-000000000004'),
    ('eeee0001-0001-0001-0001-000000000005', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000012', 'cccc0001-0001-0001-0001-000000000005');

-- ============================================================================
-- カスタムフィールド定義（テナント独自入力項目）
-- ============================================================================
-- 【EAVパターンの実例】
-- Tanaka Manufacturing では「停止原因」「修理詳細」を独自項目として定義

INSERT INTO custom_field_definitions (id, tenant_id, field_name, field_type, is_required, display_order, options) VALUES
    -- Tanaka Manufacturing のカスタムフィールド
    ('ffff0001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', 'Cause of stoppage', 'select', TRUE, 1, '["Mechanical failure", "Electrical issue", "Material shortage", "Operator error", "Scheduled maintenance", "Other"]'),
    ('ffff0001-0001-0001-0001-000000000002', '11111111-1111-1111-1111-111111111111', 'Repair details', 'text', FALSE, 2, NULL),
    ('ffff0001-0001-0001-0001-000000000003', '11111111-1111-1111-1111-111111111111', 'Downtime (minutes)', 'number', FALSE, 3, NULL),
    ('ffff0001-0001-0001-0001-000000000004', '11111111-1111-1111-1111-111111111111', 'Requires follow-up', 'boolean', FALSE, 4, NULL),

    -- Yamamoto Electronics のカスタムフィールド（異なるテナントは異なる項目を持てる）
    ('ffff0002-0001-0001-0001-000000000001', '22222222-2222-2222-2222-222222222222', 'Defect type', 'select', TRUE, 1, '["Solder bridge", "Missing component", "Wrong polarity", "Cold joint", "Other"]'),
    ('ffff0002-0001-0001-0001-000000000002', '22222222-2222-2222-2222-222222222222', 'Lot number', 'text', TRUE, 2, NULL);

-- ============================================================================
-- タスク
-- ============================================================================
INSERT INTO tasks (id, tenant_id, equipment_id, title, description, status, due_date, assigned_to) VALUES
    -- Tanaka Manufacturing のタスク
    ('10000001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000011', 'Replace worn conveyor belt', 'Belt showing signs of wear on section 3. Replace before failure.', 'todo', '2024-02-15', 'Suzuki T.'),
    ('10000001-0001-0001-0001-000000000002', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000012', 'Calibrate robot arm sensors', 'Monthly calibration check required.', 'in_progress', '2024-02-10', 'Yamada H.'),
    ('10000001-0001-0001-0001-000000000003', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000013', 'Update scanner firmware', 'New firmware v2.3 available with improved detection.', 'done', '2024-02-01', 'Sato K.'),
    ('10000001-0001-0001-0001-000000000004', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000001', 'Emergency: Line A motor failure', 'Drive motor stopped unexpectedly. Production halted.', 'in_progress', '2024-02-08', 'Tanaka K.'),

    -- Yamamoto Electronics のタスク
    ('10000002-0001-0001-0001-000000000001', '22222222-2222-2222-2222-222222222222', 'bbbb0001-0001-0001-0001-000000000001', 'Clean solder paste stencil', 'Weekly cleaning schedule.', 'todo', '2024-02-12', 'John Smith');

-- ============================================================================
-- タスク・部品関連（使用部品）
-- ============================================================================
INSERT INTO task_parts (id, tenant_id, task_id, part_id, quantity) VALUES
    -- 「Replace worn conveyor belt」で使用する部品
    ('20000001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000001', 'cccc0001-0001-0001-0001-000000000001', 1),
    -- 「Emergency: Line A motor failure」で使用する部品
    ('20000001-0001-0001-0001-000000000002', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'cccc0001-0001-0001-0001-000000000002', 1),
    ('20000001-0001-0001-0001-000000000003', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'cccc0001-0001-0001-0001-000000000003', 2);

-- ============================================================================
-- カスタムフィールド値（EAVパターンの値部分）
-- ============================================================================
INSERT INTO custom_field_values (id, tenant_id, task_id, field_definition_id, value) VALUES
    -- 「Emergency: Line A motor failure」のカスタムフィールド値
    ('30000001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'ffff0001-0001-0001-0001-000000000001', 'Mechanical failure'),
    ('30000001-0001-0001-0001-000000000002', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'ffff0001-0001-0001-0001-000000000002', 'Motor bearing seized. Replaced entire motor unit and realigned coupling.'),
    ('30000001-0001-0001-0001-000000000003', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'ffff0001-0001-0001-0001-000000000003', '180'),
    ('30000001-0001-0001-0001-000000000004', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'ffff0001-0001-0001-0001-000000000004', 'true'),

    -- 「Replace worn conveyor belt」のカスタムフィールド値
    ('30000001-0001-0001-0001-000000000005', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000001', 'ffff0001-0001-0001-0001-000000000001', 'Scheduled maintenance');

-- ============================================================================
-- タスクコメント【課題2】
-- ============================================================================
INSERT INTO task_comments (id, tenant_id, task_id, commented_by, comment, created_at) VALUES
    -- 「Emergency: Line A motor failure」のコメント（時系列で作業履歴を記録）
    ('40000001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'Suzuki T.', 'Discovered motor failure at 08:15. Line stopped immediately. Notified maintenance team.', '2024-02-08 08:20:00+09'),
    ('40000001-0001-0001-0001-000000000002', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'Tanaka K.', 'Inspected motor. Bearing completely seized. Need replacement motor from warehouse.', '2024-02-08 09:00:00+09'),
    ('40000001-0001-0001-0001-000000000003', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'Tanaka K.', 'Replacement motor installed. Performing alignment check now.', '2024-02-08 10:30:00+09'),
    ('40000001-0001-0001-0001-000000000004', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000004', 'Yamada H.', 'Night shift note: Line running stable after repair. Recommend monitoring vibration levels for next 24hrs.', '2024-02-08 22:00:00+09'),

    -- 「Replace worn conveyor belt」のコメント
    ('40000001-0001-0001-0001-000000000005', '11111111-1111-1111-1111-111111111111', '10000001-0001-0001-0001-000000000001', 'Suzuki T.', 'Ordered replacement belt. ETA: Feb 14th.', '2024-02-07 14:00:00+09');
-- ============================================================================
-- M2X: グローバル基準リファクタリング用追加シードデータ
-- ============================================================================
-- 新しいスキーマ要素のサンプルデータを追加
--
-- 【追加データ】
-- - ユーザー（users）
-- - 既存データの拡張フィールド更新
-- ============================================================================

-- ============================================================================
-- テナント拡張データ
-- ============================================================================
UPDATE tenants SET
    slug = 'tanaka-manufacturing',
    timezone = 'Asia/Tokyo',
    locale = 'ja_JP',
    settings = '{"theme": "light", "notifications_enabled": true}'
WHERE id = '11111111-1111-1111-1111-111111111111';

UPDATE tenants SET
    slug = 'yamamoto-electronics',
    timezone = 'Asia/Tokyo',
    locale = 'ja_JP',
    settings = '{"theme": "dark", "notifications_enabled": true}'
WHERE id = '22222222-2222-2222-2222-222222222222';

-- ============================================================================
-- ユーザー
-- ============================================================================
-- Tanaka Manufacturing のユーザー
INSERT INTO users (id, tenant_id, email, password_hash, display_name, employee_id, department, role, status) VALUES
    ('a0000001-0001-0001-0001-000000000001', '11111111-1111-1111-1111-111111111111', 'admin@tanaka-mfg.example.com', '$2b$12$EXAMPLE_HASH_ADMIN', 'System Admin', 'EMP-001', 'IT', 'admin', 'active'),
    ('a0000001-0001-0001-0001-000000000002', '11111111-1111-1111-1111-111111111111', 'tanaka.k@tanaka-mfg.example.com', '$2b$12$EXAMPLE_HASH_001', 'Tanaka Kenji', 'EMP-101', 'Maintenance', 'operator', 'active'),
    ('a0000001-0001-0001-0001-000000000003', '11111111-1111-1111-1111-111111111111', 'suzuki.t@tanaka-mfg.example.com', '$2b$12$EXAMPLE_HASH_002', 'Suzuki Taro', 'EMP-102', 'Production', 'operator', 'active'),
    ('a0000001-0001-0001-0001-000000000004', '11111111-1111-1111-1111-111111111111', 'yamada.h@tanaka-mfg.example.com', '$2b$12$EXAMPLE_HASH_003', 'Yamada Hanako', 'EMP-103', 'Production', 'operator', 'active'),
    ('a0000001-0001-0001-0001-000000000005', '11111111-1111-1111-1111-111111111111', 'sato.k@tanaka-mfg.example.com', '$2b$12$EXAMPLE_HASH_004', 'Sato Koji', 'EMP-104', 'Quality', 'operator', 'active'),
    ('a0000001-0001-0001-0001-000000000006', '11111111-1111-1111-1111-111111111111', 'manager@tanaka-mfg.example.com', '$2b$12$EXAMPLE_HASH_MGR', 'Factory Manager', 'EMP-200', 'Management', 'manager', 'active');

-- Yamamoto Electronics のユーザー
INSERT INTO users (id, tenant_id, email, password_hash, display_name, employee_id, department, role, status) VALUES
    ('a0000002-0001-0001-0001-000000000001', '22222222-2222-2222-2222-222222222222', 'admin@yamamoto-elec.example.com', '$2b$12$EXAMPLE_HASH_ADM2', 'Admin', 'YE-001', 'IT', 'admin', 'active'),
    ('a0000002-0001-0001-0001-000000000002', '22222222-2222-2222-2222-222222222222', 'john.smith@yamamoto-elec.example.com', '$2b$12$EXAMPLE_HASH_JS', 'John Smith', 'YE-101', 'SMT Line', 'operator', 'active');

-- ============================================================================
-- 設備拡張データ
-- ============================================================================
UPDATE equipments SET
    serial_number = 'AL-A-2024-001',
    model = 'ASL-5000',
    installation_date = '2020-03-15',
    last_maintenance_date = '2024-01-15',
    next_maintenance_date = '2024-04-15',
    status = 'operational',
    metadata = '{"location": "Building 1, Floor 1", "warranty_expires": "2025-03-15"}'
WHERE id = 'aaaa0001-0001-0001-0001-000000000001';

UPDATE equipments SET
    serial_number = 'CB-A1-2020-001',
    model = 'CT-3000',
    installation_date = '2020-03-15',
    last_maintenance_date = '2024-02-01',
    next_maintenance_date = '2024-05-01',
    status = 'operational'
WHERE id = 'aaaa0001-0001-0001-0001-000000000011';

UPDATE equipments SET
    serial_number = 'RA-A1-2021-001',
    model = 'ROBO-ARM-X7',
    installation_date = '2021-06-20',
    last_maintenance_date = '2024-02-08',
    next_maintenance_date = '2024-03-08',
    status = 'operational'
WHERE id = 'aaaa0001-0001-0001-0001-000000000012';

-- ============================================================================
-- 部品拡張データ
-- ============================================================================
UPDATE parts SET
    unit_price = 45000.00,
    currency = 'JPY',
    supplier = 'Conveyor Systems Japan',
    lead_time_days = 5,
    minimum_order_quantity = 1,
    barcode = '4901234567890'
WHERE id = 'cccc0001-0001-0001-0001-000000000001';

UPDATE parts SET
    unit_price = 128000.00,
    currency = 'JPY',
    supplier = 'Industrial Motors Co.',
    lead_time_days = 7,
    minimum_order_quantity = 1,
    barcode = '4901234567891'
WHERE id = 'cccc0001-0001-0001-0001-000000000002';

UPDATE parts SET
    unit_price = 3500.00,
    currency = 'JPY',
    supplier = 'Sensor Technologies',
    lead_time_days = 3,
    minimum_order_quantity = 5,
    barcode = '4901234567892'
WHERE id = 'cccc0001-0001-0001-0001-000000000003';

-- ============================================================================
-- タスク拡張データ
-- ============================================================================
UPDATE tasks SET
    priority = 'medium',
    category = 'maintenance',
    estimated_hours = 2.0,
    created_by = 'a0000001-0001-0001-0001-000000000002',
    assigned_to_user_id = 'a0000001-0001-0001-0001-000000000002'
WHERE id = '10000001-0001-0001-0001-000000000001';

UPDATE tasks SET
    priority = 'high',
    category = 'calibration',
    estimated_hours = 1.5,
    started_at = '2024-02-09 09:00:00+09',
    created_by = 'a0000001-0001-0001-0001-000000000006',
    assigned_to_user_id = 'a0000001-0001-0001-0001-000000000004'
WHERE id = '10000001-0001-0001-0001-000000000002';

UPDATE tasks SET
    priority = 'low',
    category = 'improvement',
    estimated_hours = 0.5,
    actual_hours = 0.75,
    started_at = '2024-01-31 14:00:00+09',
    completed_at = '2024-02-01 10:00:00+09',
    created_by = 'a0000001-0001-0001-0001-000000000005',
    assigned_to_user_id = 'a0000001-0001-0001-0001-000000000005'
WHERE id = '10000001-0001-0001-0001-000000000003';

UPDATE tasks SET
    priority = 'critical',
    category = 'emergency',
    estimated_hours = 4.0,
    actual_hours = 3.0,
    started_at = '2024-02-08 08:30:00+09',
    created_by = 'a0000001-0001-0001-0001-000000000003',
    assigned_to_user_id = 'a0000001-0001-0001-0001-000000000002'
WHERE id = '10000001-0001-0001-0001-000000000004';

-- ============================================================================
-- タスクコメントのユーザーID紐付け
-- ============================================================================
UPDATE task_comments SET user_id = 'a0000001-0001-0001-0001-000000000003'
WHERE id = '40000001-0001-0001-0001-000000000001';

UPDATE task_comments SET user_id = 'a0000001-0001-0001-0001-000000000002'
WHERE id IN ('40000001-0001-0001-0001-000000000002', '40000001-0001-0001-0001-000000000003');

UPDATE task_comments SET user_id = 'a0000001-0001-0001-0001-000000000004'
WHERE id = '40000001-0001-0001-0001-000000000004';

UPDATE task_comments SET user_id = 'a0000001-0001-0001-0001-000000000003'
WHERE id = '40000001-0001-0001-0001-000000000005';

-- ============================================================================
-- カスタムフィールド定義の拡張
-- ============================================================================
UPDATE custom_field_definitions SET
    description = 'Select the root cause category for the equipment stoppage',
    placeholder = 'Select a cause...',
    validation_rules = '{"required": true}'
WHERE id = 'ffff0001-0001-0001-0001-000000000001';

UPDATE custom_field_definitions SET
    description = 'Detailed description of the repair work performed',
    placeholder = 'Describe the repair work...',
    validation_rules = '{"maxLength": 2000}'
WHERE id = 'ffff0001-0001-0001-0001-000000000002';

UPDATE custom_field_definitions SET
    description = 'Total downtime in minutes',
    placeholder = 'Enter minutes...',
    validation_rules = '{"minimum": 0, "maximum": 10080}'
WHERE id = 'ffff0001-0001-0001-0001-000000000003';

-- ============================================================================
-- 追加のサンプルタスク（優先度・カテゴリーのバリエーション）
-- ============================================================================
INSERT INTO tasks (id, tenant_id, equipment_id, title, description, status, priority, category, due_date, assigned_to, estimated_hours, created_by, assigned_to_user_id) VALUES
    -- 様々な優先度のタスク
    ('10000001-0001-0001-0001-000000000005', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000003', 'Monthly inspection - Packaging Line', 'Routine monthly inspection of packaging equipment', 'todo', 'medium', 'inspection', '2024-02-20', 'Yamada H.', 2.0, 'a0000001-0001-0001-0001-000000000006', 'a0000001-0001-0001-0001-000000000004'),
    ('10000001-0001-0001-0001-000000000006', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000001', 'Annual calibration - Line A sensors', 'Calibrate all sensors on Assembly Line A', 'todo', 'high', 'calibration', '2024-02-28', 'Sato K.', 4.0, 'a0000001-0001-0001-0001-000000000006', 'a0000001-0001-0001-0001-000000000005'),
    ('10000001-0001-0001-0001-000000000007', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000011', 'Deep cleaning - Conveyor Belt A-1', 'Quarterly deep cleaning of conveyor belt', 'todo', 'low', 'cleaning', '2024-03-01', 'Suzuki T.', 3.0, 'a0000001-0001-0001-0001-000000000006', 'a0000001-0001-0001-0001-000000000003'),
    ('10000001-0001-0001-0001-000000000008', '11111111-1111-1111-1111-111111111111', 'aaaa0001-0001-0001-0001-000000000012', 'Gripper replacement - Robot Arm A-1', 'Replace worn gripper unit', 'in_progress', 'high', 'replacement', '2024-02-12', 'Tanaka K.', 1.5, 'a0000001-0001-0001-0001-000000000002', 'a0000001-0001-0001-0001-000000000002');

-- ============================================================================
-- 完了メッセージ
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE '追加シードデータの投入が完了しました';
    RAISE NOTICE '- ユーザー: 8件追加';
    RAISE NOTICE '- 既存データ拡張フィールド: 更新完了';
    RAISE NOTICE '- 追加タスク: 4件追加';
END;
$$;
