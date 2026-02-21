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
\echo '=== タスク詳細（カスタムフィールド含む） ==='

SELECT
    t.title,
    t.status,
    e.name AS equipment_name,
    cfd.field_name,
    cfv.value
FROM tasks t
JOIN equipments e ON t.equipment_id = e.id
LEFT JOIN custom_field_values cfv ON t.id = cfv.task_id
LEFT JOIN custom_field_definitions cfd ON cfv.field_definition_id = cfd.id
WHERE t.tenant_id = :tenant_id
ORDER BY t.created_at DESC, cfd.display_order;

-- ============================================================================
-- 4. タスクとカスタムフィールドをピボット形式で取得
-- ============================================================================
\echo '=== タスク一覧（カスタムフィールドをピボット表示） ==='

SELECT
    t.title,
    t.status,
    e.name AS equipment_name,
    MAX(CASE WHEN cfd.field_name = 'Cause of stoppage' THEN cfv.value END) AS cause_of_stoppage,
    MAX(CASE WHEN cfd.field_name = 'Repair details' THEN cfv.value END) AS repair_details,
    MAX(CASE WHEN cfd.field_name = 'Downtime (minutes)' THEN cfv.value END) AS downtime_minutes,
    MAX(CASE WHEN cfd.field_name = 'Requires follow-up' THEN cfv.value END) AS requires_followup
FROM tasks t
JOIN equipments e ON t.equipment_id = e.id
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
\echo '=== 期限切れ・期限間近のタスク ==='

SELECT
    t.title,
    t.status,
    t.due_date,
    e.name AS equipment_name,
    CASE
        WHEN t.due_date < CURRENT_DATE THEN '期限切れ'
        WHEN t.due_date <= CURRENT_DATE + INTERVAL '3 days' THEN '期限間近'
        ELSE '余裕あり'
    END AS urgency
FROM tasks t
JOIN equipments e ON t.equipment_id = e.id
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
\echo '=== 設備別ダウンタイム合計 ==='

SELECT
    e.name AS equipment_name,
    COALESCE(SUM(cfv.value::INTEGER), 0) AS total_downtime_minutes
FROM tasks t
JOIN equipments e ON t.equipment_id = e.id
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
\echo '=== テナント別統計（システム管理者用） ==='

SELECT
    t.name AS tenant_name,
    t.slug,
    (SELECT COUNT(*) FROM users u WHERE u.tenant_id = t.id AND u.deleted_at IS NULL) AS user_count,
    (SELECT COUNT(*) FROM equipments e WHERE e.tenant_id = t.id AND e.deleted_at IS NULL) AS equipment_count,
    (SELECT COUNT(*) FROM tasks tk WHERE tk.tenant_id = t.id AND tk.deleted_at IS NULL) AS task_count,
    (SELECT COUNT(*) FROM parts p WHERE p.tenant_id = t.id AND p.deleted_at IS NULL) AS parts_count,
    t.timezone,
    TO_CHAR(t.created_at, 'YYYY-MM-DD') AS created_date
FROM tenants t
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
