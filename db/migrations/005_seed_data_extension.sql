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
