-- ============================================================================
-- M2X課題: サンプルクエリ集
-- ============================================================================
-- 実際の運用で想定される集計・検索クエリの例

-- テナントID（Tanaka Manufacturing）を変数として設定
-- psql で実行する場合: \set tenant_id '''11111111-1111-1111-1111-111111111111'''
\set tenant_id '''11111111-1111-1111-1111-111111111111'''

-- ============================================================================
-- 1. 設備ごとのタスク数集計
-- ============================================================================
\echo '=== 設備ごとのタスク数 ==='

SELECT
    e.name AS equipment_name,
    COUNT(t.id) AS total_tasks,
    COUNT(CASE WHEN t.status = 'todo' THEN 1 END) AS todo_count,
    COUNT(CASE WHEN t.status = 'in_progress' THEN 1 END) AS in_progress_count,
    COUNT(CASE WHEN t.status = 'done' THEN 1 END) AS done_count
FROM equipments e
LEFT JOIN tasks t ON e.id = t.equipment_id
WHERE e.tenant_id = :tenant_id
GROUP BY e.id, e.name
ORDER BY total_tasks DESC;

-- ============================================================================
-- 2. 部品ごとの使用回数集計（どの部品が頻繁に使われているか）
-- ============================================================================
\echo '=== 部品ごとの使用回数 ==='

SELECT
    p.name AS part_name,
    p.part_number,
    p.stock_quantity,
    p.reorder_point,
    COALESCE(SUM(tp.quantity), 0) AS total_used,
    CASE
        WHEN p.stock_quantity <= p.reorder_point THEN '要発注'
        ELSE 'OK'
    END AS stock_status
FROM parts p
LEFT JOIN task_parts tp ON p.id = tp.part_id
WHERE p.tenant_id = :tenant_id
GROUP BY p.id, p.name, p.part_number, p.stock_quantity, p.reorder_point
ORDER BY total_used DESC;

-- ============================================================================
-- 3. タスク詳細（カスタムフィールド値を含む）の取得
-- ============================================================================
-- NOTE: LEFT JOINで設備なしタスクも表示
\echo '=== タスク詳細（カスタムフィールド含む） ==='

SELECT
    t.title,
    t.status,
    COALESCE(e.name, '(設備なし)') AS equipment_name,
    cfd.field_name,
    cfv.value
FROM tasks t
LEFT JOIN equipments e ON t.equipment_id = e.id
LEFT JOIN custom_field_values cfv ON t.id = cfv.task_id
LEFT JOIN custom_field_definitions cfd ON cfv.field_definition_id = cfd.id
WHERE t.tenant_id = :tenant_id
ORDER BY t.created_at DESC, cfd.display_order;

-- ============================================================================
-- 4. タスクとカスタムフィールドをピボット形式で取得
-- ============================================================================
-- NOTE: LEFT JOINで設備なしタスクも表示
\echo '=== タスク一覧（カスタムフィールドをピボット表示） ==='

SELECT
    t.title,
    t.status,
    COALESCE(e.name, '(設備なし)') AS equipment_name,
    MAX(CASE WHEN cfd.field_name = 'Cause of stoppage' THEN cfv.value END) AS cause_of_stoppage,
    MAX(CASE WHEN cfd.field_name = 'Repair details' THEN cfv.value END) AS repair_details,
    MAX(CASE WHEN cfd.field_name = 'Downtime (minutes)' THEN cfv.value END) AS downtime_minutes,
    MAX(CASE WHEN cfd.field_name = 'Requires follow-up' THEN cfv.value END) AS requires_followup
FROM tasks t
LEFT JOIN equipments e ON t.equipment_id = e.id
LEFT JOIN custom_field_values cfv ON t.id = cfv.task_id
LEFT JOIN custom_field_definitions cfd ON cfv.field_definition_id = cfd.id
WHERE t.tenant_id = :tenant_id
GROUP BY t.id, t.title, t.status, e.name, t.created_at
ORDER BY t.created_at DESC;

-- ============================================================================
-- 5. 設備階層構造の表示（親子関係）
-- ============================================================================
\echo '=== 設備階層構造 ==='

WITH RECURSIVE equipment_tree AS (
    -- 基底ケース: トップレベル設備
    SELECT
        id,
        name,
        parent_equipment_id,
        0 AS depth,
        name::TEXT AS path
    FROM equipments
    WHERE tenant_id = :tenant_id
      AND parent_equipment_id IS NULL

    UNION ALL

    -- 再帰ケース: 子設備
    SELECT
        e.id,
        e.name,
        e.parent_equipment_id,
        et.depth + 1,
        et.path || ' > ' || e.name
    FROM equipments e
    JOIN equipment_tree et ON e.parent_equipment_id = et.id
)
SELECT
    REPEAT('  ', depth) || name AS equipment_hierarchy,
    path AS full_path
FROM equipment_tree
ORDER BY path;

-- ============================================================================
-- 6. 部品の関連設備一覧
-- ============================================================================
\echo '=== 部品と関連設備 ==='

SELECT
    p.name AS part_name,
    p.part_number,
    STRING_AGG(e.name, ', ') AS related_equipments
FROM parts p
LEFT JOIN equipment_parts ep ON p.id = ep.part_id
LEFT JOIN equipments e ON ep.equipment_id = e.id
WHERE p.tenant_id = :tenant_id
GROUP BY p.id, p.name, p.part_number
ORDER BY p.name;

-- ============================================================================
-- 7. 期限切れ・期限間近のタスク
-- ============================================================================
-- NOTE: LEFT JOINで設備なしタスクも表示
\echo '=== 期限切れ・期限間近のタスク ==='

SELECT
    t.title,
    t.status,
    t.due_date,
    COALESCE(e.name, '(設備なし)') AS equipment_name,
    CASE
        WHEN t.due_date < CURRENT_DATE THEN '期限切れ'
        WHEN t.due_date <= CURRENT_DATE + INTERVAL '3 days' THEN '期限間近'
        ELSE '余裕あり'
    END AS urgency
FROM tasks t
LEFT JOIN equipments e ON t.equipment_id = e.id
WHERE t.tenant_id = :tenant_id
  AND t.status != 'done'
ORDER BY t.due_date ASC;

-- ============================================================================
-- 8. タスクコメント履歴（課題2）
-- ============================================================================
\echo '=== タスクコメント履歴 ==='

SELECT
    t.title AS task_title,
    tc.commented_by,
    tc.comment,
    TO_CHAR(tc.created_at, 'YYYY-MM-DD HH24:MI') AS commented_at
FROM task_comments tc
JOIN tasks t ON tc.task_id = t.id
WHERE tc.tenant_id = :tenant_id
  AND tc.deleted_at IS NULL
ORDER BY t.id, tc.created_at;

-- ============================================================================
-- 9. 停止原因別の集計（カスタムフィールドを使った分析例）
-- ============================================================================
\echo '=== 停止原因別タスク数 ==='

SELECT
    cfv.value AS cause_of_stoppage,
    COUNT(*) AS task_count
FROM custom_field_values cfv
JOIN custom_field_definitions cfd ON cfv.field_definition_id = cfd.id
WHERE cfv.tenant_id = :tenant_id
  AND cfd.field_name = 'Cause of stoppage'
GROUP BY cfv.value
ORDER BY task_count DESC;

-- ============================================================================
-- 10. ダウンタイム合計（数値型カスタムフィールドの集計）
-- ============================================================================
-- NOTE: LEFT JOINで設備なしタスクも集計（equipment_name = '(設備なし)'）
\echo '=== 設備別ダウンタイム合計 ==='

SELECT
    COALESCE(e.name, '(設備なし)') AS equipment_name,
    COALESCE(SUM(cfv.value::INTEGER), 0) AS total_downtime_minutes
FROM tasks t
LEFT JOIN equipments e ON t.equipment_id = e.id
LEFT JOIN custom_field_definitions cfd ON cfd.tenant_id = t.tenant_id
    AND cfd.field_name = 'Downtime (minutes)'
LEFT JOIN custom_field_values cfv ON t.id = cfv.task_id
    AND cfv.field_definition_id = cfd.id
WHERE t.tenant_id = :tenant_id
GROUP BY e.id, e.name
ORDER BY total_downtime_minutes DESC;

-- ============================================================================
-- ============================================================================
-- SECTION 2: エンタープライズクエリ（高度機能）
-- ============================================================================
-- ============================================================================

-- ============================================================================
-- 11. ユーザー一覧（RBAC情報付き）
-- ============================================================================
\echo '=== ユーザー一覧（ロール別） ==='

SELECT
    u.display_name,
    u.email,
    u.employee_id,
    u.department,
    u.role,
    u.status,
    CASE WHEN u.mfa_enabled THEN 'Yes' ELSE 'No' END AS mfa_enabled,
    TO_CHAR(u.last_login_at, 'YYYY-MM-DD HH24:MI') AS last_login
FROM users u
WHERE u.tenant_id = :tenant_id
  AND u.deleted_at IS NULL
ORDER BY
    CASE u.role
        WHEN 'admin' THEN 1
        WHEN 'manager' THEN 2
        WHEN 'operator' THEN 3
        WHEN 'viewer' THEN 4
    END,
    u.display_name;

-- ============================================================================
-- 12. 担当者別タスク負荷分析
-- ============================================================================
\echo '=== 担当者別タスク負荷 ==='

SELECT
    u.display_name AS assignee,
    u.department,
    COUNT(t.id) AS total_tasks,
    COUNT(CASE WHEN t.status = 'todo' THEN 1 END) AS pending,
    COUNT(CASE WHEN t.status = 'in_progress' THEN 1 END) AS in_progress,
    COUNT(CASE WHEN t.status = 'done' THEN 1 END) AS completed,
    COALESCE(SUM(t.estimated_hours), 0) AS total_estimated_hours,
    COALESCE(SUM(t.actual_hours), 0) AS total_actual_hours,
    ROUND(
        CASE WHEN SUM(t.estimated_hours) > 0
             THEN (SUM(t.actual_hours) / SUM(t.estimated_hours) * 100)
             ELSE 0
        END, 1
    ) AS efficiency_pct
FROM users u
LEFT JOIN tasks t ON u.id = t.assigned_to_user_id
    AND t.deleted_at IS NULL
WHERE u.tenant_id = :tenant_id
  AND u.deleted_at IS NULL
  AND u.role IN ('operator', 'manager')
GROUP BY u.id, u.display_name, u.department
ORDER BY total_tasks DESC;

-- ============================================================================
-- 13. 監査ログ検索（最近の変更履歴）
-- ============================================================================
\echo '=== 監査ログ（直近50件） ==='

SELECT
    al.performed_at,
    al.table_name,
    al.operation,
    al.performed_by_name,
    LEFT(array_to_string(al.changed_fields, ', '), 50) AS changed_fields,
    al.ip_address
FROM audit_logs al
WHERE al.tenant_id = :tenant_id
ORDER BY al.performed_at DESC
LIMIT 50;

-- ============================================================================
-- 14. 監査ログ集計（テーブル・操作別）
-- ============================================================================
\echo '=== 監査ログ集計（テーブル×操作別） ==='

SELECT
    al.table_name,
    al.operation,
    COUNT(*) AS operation_count,
    COUNT(DISTINCT al.performed_by) AS unique_users,
    MIN(al.performed_at) AS first_operation,
    MAX(al.performed_at) AS last_operation
FROM audit_logs al
WHERE al.tenant_id = :tenant_id
  AND al.performed_at >= NOW() - INTERVAL '30 days'
GROUP BY al.table_name, al.operation
ORDER BY operation_count DESC;

-- ============================================================================
-- 15. セキュリティイベント監視
-- ============================================================================
\echo '=== セキュリティイベント（直近7日間） ==='

SELECT
    se.event_time,
    se.event_type,
    se.severity,
    u.display_name AS user_name,
    se.ip_address,
    se.details->>'reason' AS reason
FROM security_events se
LEFT JOIN users u ON se.user_id = u.id
WHERE se.tenant_id = :tenant_id
  AND se.event_time >= NOW() - INTERVAL '7 days'
ORDER BY se.event_time DESC
LIMIT 100;

-- ============================================================================
-- 16. セキュリティイベント統計（脅威分析）
-- ============================================================================
\echo '=== セキュリティ統計（イベント種別） ==='

SELECT
    se.event_type,
    se.severity,
    COUNT(*) AS event_count,
    COUNT(DISTINCT se.ip_address) AS unique_ips,
    COUNT(DISTINCT se.user_id) AS affected_users
FROM security_events se
WHERE se.tenant_id = :tenant_id
  AND se.event_time >= NOW() - INTERVAL '30 days'
GROUP BY se.event_type, se.severity
ORDER BY
    CASE se.severity
        WHEN 'critical' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
    END,
    event_count DESC;

-- ============================================================================
-- 17. APIキー使用状況
-- ============================================================================
\echo '=== APIキー使用状況 ==='

SELECT
    ak.name AS key_name,
    ak.key_prefix,
    u.display_name AS owner,
    ak.is_active,
    ak.usage_count,
    ak.scopes,
    TO_CHAR(ak.last_used_at, 'YYYY-MM-DD HH24:MI') AS last_used,
    TO_CHAR(ak.expires_at, 'YYYY-MM-DD') AS expires
FROM api_keys ak
JOIN users u ON ak.user_id = u.id
WHERE ak.tenant_id = :tenant_id
ORDER BY ak.usage_count DESC;

-- ============================================================================
-- 18. アクティブセッション一覧
-- ============================================================================
\echo '=== アクティブセッション ==='

SELECT
    u.display_name,
    u.email,
    us.ip_address,
    us.device_fingerprint,
    TO_CHAR(us.created_at, 'YYYY-MM-DD HH24:MI') AS session_start,
    TO_CHAR(us.last_activity_at, 'YYYY-MM-DD HH24:MI') AS last_activity,
    TO_CHAR(us.expires_at, 'YYYY-MM-DD HH24:MI') AS expires
FROM user_sessions us
JOIN users u ON us.user_id = u.id
WHERE us.tenant_id = :tenant_id
  AND us.is_active = TRUE
  AND us.expires_at > NOW()
ORDER BY us.last_activity_at DESC;

-- ============================================================================
-- 19. ログイン失敗分析（セキュリティ監視）
-- ============================================================================
\echo '=== ログイン失敗分析 ==='

SELECT
    fla.email,
    fla.ip_address,
    fla.failure_reason,
    COUNT(*) AS attempt_count,
    MIN(fla.attempted_at) AS first_attempt,
    MAX(fla.attempted_at) AS last_attempt
FROM failed_login_attempts fla
WHERE fla.tenant_id = :tenant_id
  AND fla.attempted_at >= NOW() - INTERVAL '24 hours'
GROUP BY fla.email, fla.ip_address, fla.failure_reason
HAVING COUNT(*) >= 3
ORDER BY attempt_count DESC;

-- ============================================================================
-- 20. 設備メンテナンス予定
-- ============================================================================
\echo '=== メンテナンス予定（今後30日） ==='

SELECT
    e.name AS equipment_name,
    e.serial_number,
    e.model,
    e.status,
    TO_CHAR(e.last_maintenance_date, 'YYYY-MM-DD') AS last_maintenance,
    TO_CHAR(e.next_maintenance_date, 'YYYY-MM-DD') AS next_maintenance,
    e.next_maintenance_date - CURRENT_DATE AS days_until_maintenance,
    CASE
        WHEN e.next_maintenance_date < CURRENT_DATE THEN 'Overdue'
        WHEN e.next_maintenance_date <= CURRENT_DATE + 7 THEN 'This Week'
        WHEN e.next_maintenance_date <= CURRENT_DATE + 30 THEN 'This Month'
        ELSE 'Scheduled'
    END AS maintenance_urgency
FROM equipments e
WHERE e.tenant_id = :tenant_id
  AND e.deleted_at IS NULL
  AND e.next_maintenance_date IS NOT NULL
  AND e.next_maintenance_date <= CURRENT_DATE + 30
ORDER BY e.next_maintenance_date ASC;

-- ============================================================================
-- 21. タスク完了率・効率分析
-- ============================================================================
\echo '=== タスク完了率分析（カテゴリ別） ==='

SELECT
    t.category,
    COUNT(*) AS total_tasks,
    COUNT(CASE WHEN t.status = 'done' THEN 1 END) AS completed,
    ROUND(
        COUNT(CASE WHEN t.status = 'done' THEN 1 END)::NUMERIC / COUNT(*) * 100, 1
    ) AS completion_rate_pct,
    ROUND(AVG(t.estimated_hours), 2) AS avg_estimated_hours,
    ROUND(AVG(t.actual_hours), 2) AS avg_actual_hours,
    ROUND(
        AVG(CASE WHEN t.actual_hours > 0 AND t.estimated_hours > 0
                 THEN t.actual_hours / t.estimated_hours * 100
                 ELSE NULL END), 1
    ) AS avg_efficiency_pct
FROM tasks t
WHERE t.tenant_id = :tenant_id
  AND t.deleted_at IS NULL
GROUP BY t.category
ORDER BY total_tasks DESC;

-- ============================================================================
-- 22. 部品在庫アラート（発注点以下）
-- ============================================================================
\echo '=== 部品在庫アラート ==='

SELECT
    p.name AS part_name,
    p.part_number,
    p.stock_quantity,
    p.reorder_point,
    p.reorder_point - p.stock_quantity AS shortage,
    p.unit_price,
    p.currency,
    p.supplier,
    p.lead_time_days,
    CASE
        WHEN p.stock_quantity = 0 THEN 'Out of Stock'
        WHEN p.stock_quantity <= p.reorder_point / 2 THEN 'Critical'
        WHEN p.stock_quantity <= p.reorder_point THEN 'Low'
        ELSE 'OK'
    END AS stock_status
FROM parts p
WHERE p.tenant_id = :tenant_id
  AND p.deleted_at IS NULL
  AND p.stock_quantity <= p.reorder_point
ORDER BY
    CASE
        WHEN p.stock_quantity = 0 THEN 1
        WHEN p.stock_quantity <= p.reorder_point / 2 THEN 2
        ELSE 3
    END,
    shortage DESC;

-- ============================================================================
-- 23. クロステナント統計（システム管理者用）
-- ============================================================================
-- 【最適化】相関サブクエリをLEFT JOINに変更（N+1問題の回避）
\echo '=== テナント別統計（システム管理者用） ==='

SELECT
    t.name AS tenant_name,
    t.slug,
    COALESCE(uc.user_count, 0) AS user_count,
    COALESCE(ec.equipment_count, 0) AS equipment_count,
    COALESCE(tc.task_count, 0) AS task_count,
    COALESCE(pc.parts_count, 0) AS parts_count,
    t.timezone,
    TO_CHAR(t.created_at, 'YYYY-MM-DD') AS created_date
FROM tenants t
LEFT JOIN (
    SELECT tenant_id, COUNT(*) AS user_count
    FROM users WHERE deleted_at IS NULL GROUP BY tenant_id
) uc ON t.id = uc.tenant_id
LEFT JOIN (
    SELECT tenant_id, COUNT(*) AS equipment_count
    FROM equipments WHERE deleted_at IS NULL GROUP BY tenant_id
) ec ON t.id = ec.tenant_id
LEFT JOIN (
    SELECT tenant_id, COUNT(*) AS task_count
    FROM tasks WHERE deleted_at IS NULL GROUP BY tenant_id
) tc ON t.id = tc.tenant_id
LEFT JOIN (
    SELECT tenant_id, COUNT(*) AS parts_count
    FROM parts WHERE deleted_at IS NULL GROUP BY tenant_id
) pc ON t.id = pc.tenant_id
WHERE t.deleted_at IS NULL
ORDER BY task_count DESC;

-- ============================================================================
-- 24. 設備階層と関連タスク（深度付き）
-- ============================================================================
\echo '=== 設備階層とタスクサマリー ==='

WITH RECURSIVE equipment_hierarchy AS (
    SELECT
        id,
        name,
        parent_equipment_id,
        0 AS depth,
        ARRAY[name]::TEXT[] AS path_array
    FROM equipments
    WHERE tenant_id = :tenant_id
      AND parent_equipment_id IS NULL
      AND deleted_at IS NULL

    UNION ALL

    SELECT
        e.id,
        e.name,
        e.parent_equipment_id,
        eh.depth + 1,
        eh.path_array || e.name
    FROM equipments e
    JOIN equipment_hierarchy eh ON e.parent_equipment_id = eh.id
    WHERE e.deleted_at IS NULL
)
SELECT
    REPEAT('  ', eh.depth) || eh.name AS equipment,
    eh.depth AS level,
    COUNT(t.id) FILTER (WHERE t.status = 'todo') AS todo,
    COUNT(t.id) FILTER (WHERE t.status = 'in_progress') AS in_progress,
    COUNT(t.id) FILTER (WHERE t.status = 'done') AS done
FROM equipment_hierarchy eh
LEFT JOIN tasks t ON eh.id = t.equipment_id AND t.deleted_at IS NULL
GROUP BY eh.id, eh.name, eh.depth, eh.path_array
ORDER BY eh.path_array;

-- ============================================================================
-- 25. パスワードポリシー設定確認
-- ============================================================================
\echo '=== パスワードポリシー設定 ==='

SELECT
    t.name AS tenant_name,
    pp.min_length,
    pp.max_length,
    CASE WHEN pp.require_uppercase THEN 'Yes' ELSE 'No' END AS require_uppercase,
    CASE WHEN pp.require_numbers THEN 'Yes' ELSE 'No' END AS require_numbers,
    CASE WHEN pp.require_special_chars THEN 'Yes' ELSE 'No' END AS require_special,
    pp.password_history_count,
    pp.max_age_days,
    pp.max_failed_attempts,
    CASE WHEN pp.require_mfa THEN 'Yes' ELSE 'No' END AS require_mfa
FROM password_policies pp
JOIN tenants t ON pp.tenant_id = t.id
WHERE t.deleted_at IS NULL
ORDER BY t.name;

-- ============================================================================
-- ============================================================================
-- SECTION 3: 業種横断クエリ（水道・製造・食品・化学プラント対応）
-- ============================================================================
-- ============================================================================

-- ============================================================================
-- 26. 設備カテゴリ・タイプ階層表示
-- ============================================================================
\echo '=== 設備カテゴリ・タイプ一覧 ==='

SELECT
    ec.code AS category_code,
    ec.name AS category_name,
    et.code AS type_code,
    et.name AS type_name,
    array_to_string(ec.industry_tags, ', ') AS industries
FROM equipment_categories ec
LEFT JOIN equipment_types et ON ec.id = et.category_id
WHERE ec.tenant_id = :tenant_id
ORDER BY ec.sort_order, ec.name, et.name;

-- ============================================================================
-- 27. 計測ポイント一覧（センサー監視用）
-- ============================================================================
\echo '=== 計測ポイント一覧 ==='

SELECT
    e.name AS equipment_name,
    mp.point_code,
    mp.point_name,
    mp.data_type,
    mp.unit,
    mp.normal_min || ' - ' || mp.normal_max AS normal_range,
    mp.warning_min || ' - ' || mp.warning_max AS warning_range,
    array_to_string(mp.tags, ', ') AS tags
FROM measurement_points mp
JOIN equipments e ON mp.equipment_id = e.id
WHERE mp.tenant_id = :tenant_id
  AND mp.is_active = TRUE
ORDER BY e.name, mp.point_code;

-- ============================================================================
-- 28. 計測データサマリー（日次統計）
-- ============================================================================
\echo '=== 計測データ日次統計 ==='

SELECT
    mp.point_name,
    mp.unit,
    DATE(md.measured_at) AS date,
    ROUND(AVG(md.numeric_value)::NUMERIC, 2) AS avg_value,
    ROUND(MIN(md.numeric_value)::NUMERIC, 2) AS min_value,
    ROUND(MAX(md.numeric_value)::NUMERIC, 2) AS max_value,
    COUNT(*) AS sample_count,
    COUNT(*) FILTER (WHERE md.is_anomaly) AS anomaly_count
FROM measurement_data md
JOIN measurement_points mp ON md.point_id = mp.id
WHERE md.tenant_id = :tenant_id
  AND md.measured_at >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY mp.id, mp.point_name, mp.unit, DATE(md.measured_at)
ORDER BY mp.point_name, date DESC;

-- ============================================================================
-- 29. 点検予定・実績管理
-- ============================================================================
\echo '=== 点検予定・実績 ==='

SELECT
    it.template_name,
    it.frequency,
    e.name AS equipment_name,
    ir.record_number,
    ir.status,
    ir.overall_result,
    TO_CHAR(ir.scheduled_date, 'YYYY-MM-DD') AS scheduled_date,
    TO_CHAR(ir.completed_at, 'YYYY-MM-DD HH24:MI') AS completed_at,
    ir.inspector_name,
    CASE WHEN ir.has_issues THEN 'Yes (' || ir.issue_count || ')' ELSE 'No' END AS has_issues
FROM inspection_records ir
JOIN inspection_templates it ON ir.template_id = it.id
JOIN equipments e ON ir.equipment_id = e.id
WHERE ir.tenant_id = :tenant_id
ORDER BY ir.scheduled_date DESC, ir.created_at DESC
LIMIT 50;

-- ============================================================================
-- 30. 点検期限切れアラート
-- ============================================================================
\echo '=== 点検期限切れ・期限間近 ==='

SELECT
    e.name AS equipment_name,
    it.template_name,
    it.frequency,
    MAX(ir.completed_at) AS last_inspection,
    calculate_next_inspection_date(e.id, it.id) AS next_due,
    CASE
        WHEN calculate_next_inspection_date(e.id, it.id) < CURRENT_DATE THEN 'OVERDUE'
        WHEN calculate_next_inspection_date(e.id, it.id) <= CURRENT_DATE + 7 THEN 'DUE SOON'
        ELSE 'OK'
    END AS status
FROM equipments e
CROSS JOIN inspection_templates it
LEFT JOIN inspection_records ir ON e.id = ir.equipment_id AND it.id = ir.template_id
WHERE e.tenant_id = :tenant_id
  AND e.deleted_at IS NULL
  AND it.is_active = TRUE
  AND (it.equipment_type_id IS NULL OR it.equipment_type_id = e.type_id)
GROUP BY e.id, e.name, it.id, it.template_name, it.frequency
HAVING calculate_next_inspection_date(e.id, it.id) <= CURRENT_DATE + 14
ORDER BY calculate_next_inspection_date(e.id, it.id);

-- ============================================================================
-- 31. 作業許可証（PTW）管理
-- ============================================================================
\echo '=== 作業許可証一覧 ==='

SELECT
    wp.permit_number,
    wp.permit_type,
    wp.work_title,
    wp.work_location,
    wp.status,
    TO_CHAR(wp.planned_start, 'YYYY-MM-DD HH24:MI') AS planned_start,
    TO_CHAR(wp.planned_end, 'YYYY-MM-DD HH24:MI') AS planned_end,
    u.display_name AS requester,
    wp.work_supervisor_name AS supervisor,
    array_to_string(wp.ppe_required, ', ') AS ppe_required
FROM work_permits wp
JOIN users u ON wp.requester_id = u.id
WHERE wp.tenant_id = :tenant_id
ORDER BY
    CASE wp.status
        WHEN 'active' THEN 1
        WHEN 'approved' THEN 2
        WHEN 'pending_approval' THEN 3
        ELSE 4
    END,
    wp.planned_start;

-- ============================================================================
-- 32. インシデント分析
-- ============================================================================
\echo '=== インシデント分析（過去90日） ==='

SELECT
    i.incident_type,
    i.severity,
    COUNT(*) AS incident_count,
    COUNT(*) FILTER (WHERE i.status = 'closed') AS closed_count,
    COUNT(*) FILTER (WHERE i.status IN ('reported', 'investigating')) AS open_count,
    ROUND(
        AVG(EXTRACT(EPOCH FROM (i.closed_at - i.occurred_at)) / 86400)::NUMERIC, 1
    ) AS avg_resolution_days
FROM incidents i
WHERE i.tenant_id = :tenant_id
  AND i.occurred_at >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY i.incident_type, i.severity
ORDER BY
    CASE i.severity
        WHEN 'catastrophic' THEN 1
        WHEN 'critical' THEN 2
        WHEN 'serious' THEN 3
        WHEN 'moderate' THEN 4
        WHEN 'minor' THEN 5
    END,
    incident_count DESC;

-- ============================================================================
-- 33. シフト別作業員配置
-- ============================================================================
\echo '=== 本日のシフト配置 ==='

SELECT
    s.shift_name,
    s.start_time || ' - ' || s.end_time AS time_range,
    u.display_name AS worker,
    sa.role,
    sa.assigned_area,
    e.name AS assigned_equipment
FROM shift_assignments sa
JOIN shifts s ON sa.shift_id = s.id
JOIN users u ON sa.user_id = u.id
LEFT JOIN equipments e ON sa.assigned_equipment_id = e.id
WHERE sa.tenant_id = :tenant_id
  AND sa.assignment_date = CURRENT_DATE
ORDER BY s.start_time, u.display_name;

-- ============================================================================
-- 34. 設備総合ダッシュボード
-- ============================================================================
\echo '=== 設備総合ダッシュボード ==='

SELECT
    e.name AS equipment_name,
    ec.name AS category,
    e.criticality,
    -- 最新点検
    (SELECT TO_CHAR(MAX(ir.completed_at), 'YYYY-MM-DD')
     FROM inspection_records ir
     WHERE ir.equipment_id = e.id AND ir.status = 'approved') AS last_inspection,
    -- オープンタスク
    (SELECT COUNT(*)
     FROM tasks t
     WHERE t.equipment_id = e.id AND t.status != 'done' AND t.deleted_at IS NULL) AS open_tasks,
    -- 30日インシデント
    (SELECT COUNT(*)
     FROM incidents i
     WHERE i.equipment_id = e.id AND i.occurred_at > CURRENT_TIMESTAMP - INTERVAL '30 days') AS incidents_30d,
    -- アクティブPTW
    (SELECT COUNT(*)
     FROM work_permits wp
     WHERE wp.equipment_id = e.id AND wp.status IN ('approved', 'active')) AS active_permits,
    -- 異常計測数
    (SELECT COUNT(*)
     FROM measurement_data md
     JOIN measurement_points mp ON md.point_id = mp.id
     WHERE mp.equipment_id = e.id
       AND md.is_anomaly = TRUE
       AND md.measured_at > CURRENT_TIMESTAMP - INTERVAL '24 hours') AS anomalies_24h
FROM equipments e
LEFT JOIN equipment_categories ec ON e.category_id = ec.id
WHERE e.tenant_id = :tenant_id
  AND e.deleted_at IS NULL
ORDER BY
    CASE e.criticality
        WHEN 'critical' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
    END,
    e.name;

-- ============================================================================
-- 35. 水道施設向け: 水質モニタリング
-- ============================================================================
\echo '=== 水質モニタリング（水道施設向け） ==='

SELECT
    e.name AS facility_name,
    mp.point_name AS parameter,
    mp.unit,
    md.numeric_value AS current_value,
    mp.normal_min || ' - ' || mp.normal_max AS normal_range,
    CASE
        WHEN md.numeric_value < mp.critical_min OR md.numeric_value > mp.critical_max THEN 'CRITICAL'
        WHEN md.numeric_value < mp.warning_min OR md.numeric_value > mp.warning_max THEN 'WARNING'
        WHEN md.numeric_value < mp.normal_min OR md.numeric_value > mp.normal_max THEN 'ALERT'
        ELSE 'NORMAL'
    END AS status,
    TO_CHAR(md.measured_at, 'HH24:MI') AS time
FROM measurement_points mp
JOIN equipments e ON mp.equipment_id = e.id
JOIN LATERAL (
    SELECT * FROM measurement_data
    WHERE point_id = mp.id
    ORDER BY measured_at DESC
    LIMIT 1
) md ON TRUE
WHERE mp.tenant_id = :tenant_id
  AND 'water_quality' = ANY(mp.tags)
ORDER BY
    CASE
        WHEN md.numeric_value < mp.critical_min OR md.numeric_value > mp.critical_max THEN 1
        WHEN md.numeric_value < mp.warning_min OR md.numeric_value > mp.warning_max THEN 2
        ELSE 3
    END,
    e.name, mp.point_name;

-- ============================================================================
-- 36. 食品工場向け: HACCP温度記録
-- ============================================================================
\echo '=== HACCP温度記録（食品工場向け） ==='

SELECT
    e.name AS equipment_name,
    mp.point_name,
    DATE(md.measured_at) AS date,
    COUNT(*) AS readings,
    ROUND(MIN(md.numeric_value)::NUMERIC, 1) AS min_temp,
    ROUND(MAX(md.numeric_value)::NUMERIC, 1) AS max_temp,
    ROUND(AVG(md.numeric_value)::NUMERIC, 1) AS avg_temp,
    mp.critical_min || '℃ - ' || mp.critical_max || '℃' AS acceptable_range,
    CASE
        WHEN MIN(md.numeric_value) < mp.critical_min OR MAX(md.numeric_value) > mp.critical_max
        THEN 'DEVIATION'
        ELSE 'COMPLIANT'
    END AS haccp_status
FROM measurement_points mp
JOIN equipments e ON mp.equipment_id = e.id
JOIN measurement_data md ON mp.id = md.point_id
WHERE mp.tenant_id = :tenant_id
  AND 'haccp_ccp' = ANY(mp.tags)
  AND md.measured_at >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY e.id, e.name, mp.id, mp.point_name, mp.critical_min, mp.critical_max, DATE(md.measured_at)
ORDER BY date DESC, e.name;

-- ============================================================================
-- 37. 化学プラント向け: 安全弁点検状況
-- ============================================================================
\echo '=== 安全設備点検状況（化学プラント向け） ==='

SELECT
    e.name AS equipment_name,
    et.name AS equipment_type,
    it.template_name AS inspection_type,
    MAX(ir.completed_at) AS last_inspection,
    calculate_next_inspection_date(e.id, it.id) AS next_due,
    CASE
        WHEN calculate_next_inspection_date(e.id, it.id) < CURRENT_DATE THEN 'OVERDUE - CRITICAL'
        WHEN calculate_next_inspection_date(e.id, it.id) <= CURRENT_DATE + 30 THEN 'DUE SOON'
        ELSE 'OK'
    END AS status,
    COALESCE(
        (SELECT COUNT(*) FROM inspection_record_items iri
         JOIN inspection_records ir2 ON iri.record_id = ir2.id
         WHERE ir2.equipment_id = e.id AND iri.is_issue = TRUE
         AND ir2.completed_at > CURRENT_DATE - INTERVAL '365 days'), 0
    ) AS issues_last_year
FROM equipments e
JOIN equipment_types et ON e.type_id = et.id
JOIN equipment_categories ec ON e.category_id = ec.id
CROSS JOIN inspection_templates it
LEFT JOIN inspection_records ir ON e.id = ir.equipment_id AND it.id = ir.template_id
WHERE e.tenant_id = :tenant_id
  AND 'chemical' = ANY(ec.industry_tags)
  AND it.is_regulatory = TRUE
GROUP BY e.id, e.name, et.name, it.id, it.template_name
ORDER BY calculate_next_inspection_date(e.id, it.id);
