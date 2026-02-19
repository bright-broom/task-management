"""
M2X課題 - 工場向けタスク管理システム Web UI
"""
import os
from flask import Flask, render_template, jsonify
import psycopg2
from psycopg2.extras import RealDictCursor

app = Flask(__name__)

DATABASE_URL = os.environ.get(
    'DATABASE_URL',
    'postgresql://m2x_user:m2x_password@db:5432/m2x_task_management'
)

def get_db_connection():
    return psycopg2.connect(DATABASE_URL, cursor_factory=RealDictCursor)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/tenants')
def get_tenants():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute('SELECT * FROM tenants ORDER BY name')
    tenants = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(tenants)

@app.route('/api/tenants/<tenant_id>/equipments')
def get_equipments(tenant_id):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute('''
        WITH RECURSIVE equipment_tree AS (
            SELECT id, name, parent_equipment_id, manufacturer, description, 0 AS depth
            FROM equipments
            WHERE tenant_id = %s AND parent_equipment_id IS NULL
            UNION ALL
            SELECT e.id, e.name, e.parent_equipment_id, e.manufacturer, e.description, et.depth + 1
            FROM equipments e
            JOIN equipment_tree et ON e.parent_equipment_id = et.id
        )
        SELECT * FROM equipment_tree ORDER BY depth, name
    ''', (tenant_id,))
    equipments = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(equipments)

@app.route('/api/tenants/<tenant_id>/parts')
def get_parts(tenant_id):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute('''
        SELECT p.*,
               COALESCE(
                   (SELECT STRING_AGG(e.name, ', ')
                    FROM equipment_parts ep
                    JOIN equipments e ON ep.equipment_id = e.id
                    WHERE ep.part_id = p.id), ''
               ) AS related_equipments
        FROM parts p
        WHERE p.tenant_id = %s
        ORDER BY p.name
    ''', (tenant_id,))
    parts = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(parts)

@app.route('/api/tenants/<tenant_id>/tasks')
def get_tasks(tenant_id):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute('''
        SELECT t.*, e.name AS equipment_name
        FROM tasks t
        JOIN equipments e ON t.equipment_id = e.id
        WHERE t.tenant_id = %s
        ORDER BY t.created_at DESC
    ''', (tenant_id,))
    tasks = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(tasks)

@app.route('/api/tasks/<task_id>/details')
def get_task_details(task_id):
    conn = get_db_connection()
    cur = conn.cursor()

    # Task basic info
    cur.execute('''
        SELECT t.*, e.name AS equipment_name
        FROM tasks t
        JOIN equipments e ON t.equipment_id = e.id
        WHERE t.id = %s
    ''', (task_id,))
    task = cur.fetchone()

    # Custom fields
    cur.execute('''
        SELECT cfd.field_name, cfd.field_type, cfv.value
        FROM custom_field_values cfv
        JOIN custom_field_definitions cfd ON cfv.field_definition_id = cfd.id
        WHERE cfv.task_id = %s
        ORDER BY cfd.display_order
    ''', (task_id,))
    custom_fields = cur.fetchall()

    # Parts used
    cur.execute('''
        SELECT p.name, p.part_number, tp.quantity
        FROM task_parts tp
        JOIN parts p ON tp.part_id = p.id
        WHERE tp.task_id = %s
    ''', (task_id,))
    parts = cur.fetchall()

    # Comments
    cur.execute('''
        SELECT commented_by, comment, created_at
        FROM task_comments
        WHERE task_id = %s AND deleted_at IS NULL
        ORDER BY created_at
    ''', (task_id,))
    comments = cur.fetchall()

    cur.close()
    conn.close()

    return jsonify({
        'task': task,
        'custom_fields': custom_fields,
        'parts': parts,
        'comments': comments
    })

@app.route('/api/tenants/<tenant_id>/custom_fields')
def get_custom_field_definitions(tenant_id):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute('''
        SELECT * FROM custom_field_definitions
        WHERE tenant_id = %s
        ORDER BY display_order
    ''', (tenant_id,))
    fields = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(fields)

@app.route('/api/tenants/<tenant_id>/stats')
def get_stats(tenant_id):
    conn = get_db_connection()
    cur = conn.cursor()

    # Tasks by status
    cur.execute('''
        SELECT status, COUNT(*) as count
        FROM tasks
        WHERE tenant_id = %s
        GROUP BY status
    ''', (tenant_id,))
    tasks_by_status = cur.fetchall()

    # Tasks by equipment
    cur.execute('''
        SELECT e.name, COUNT(t.id) as count
        FROM equipments e
        LEFT JOIN tasks t ON e.id = t.equipment_id
        WHERE e.tenant_id = %s
        GROUP BY e.id, e.name
        ORDER BY count DESC
    ''', (tenant_id,))
    tasks_by_equipment = cur.fetchall()

    # Parts low stock
    cur.execute('''
        SELECT name, part_number, stock_quantity, reorder_point
        FROM parts
        WHERE tenant_id = %s AND stock_quantity <= reorder_point
        ORDER BY stock_quantity
    ''', (tenant_id,))
    low_stock_parts = cur.fetchall()

    cur.close()
    conn.close()

    return jsonify({
        'tasks_by_status': tasks_by_status,
        'tasks_by_equipment': tasks_by_equipment,
        'low_stock_parts': low_stock_parts
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
