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
