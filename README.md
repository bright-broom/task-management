# M2X課題 — 工場向けタスク管理システム テーブル設計

## 課題概要

### システム概要

本システムは、工場向けのタスク管理システムです。

工場には複数の設備が存在し、各設備に必要な部品を事前に登録することができます。タスク登録時には対象の設備と使用する部品を設定し、後から設備ごと・部品ごとにタスク数の集計を行うことが可能です。

本システムはマルチテナントに対応しており、テナントごとにデータが仮想的に分離されていることを前提としています。

### 課題内容

| 課題 | 内容 |
|---|---|
| **課題1** | 以下のUI（3画面）を参考に、テーブル設計を行う |
| **課題2** | 任意の追加機能を1つ提案し、それに対応するDB設計も行う |

### 画面仕様

#### 設備詳細画面（Equipment Details）

| 項目 | 例 |
|---|---|
| 名前 | Boiler 1 |
| 親設備（Parent Equipment） | Boiler room1 |
| 製造元（Manufacturer） | ABC Company |
| 説明（Description） | Regular maintenance is essential for optimal performance. |

**必須項目:** 名前

#### 部品詳細画面（Part Detail）

| 項目 | 例 |
|---|---|
| 名前 | Oil Filter |
| 型番（Model Number） | 1232-13434AB |
| 保管場所（Location） | Building 2 |
| 説明（Description） | HVAC filter |
| 在庫数（Quantity） | 4 |
| 発注点（Order Point） | 3 |
| 関連設備（Related Equipment） | AC Unit, Boiler 1 |

**必須項目:** 名前、在庫数

#### タスク詳細画面（Task Details）

| 項目 | 例 |
|---|---|
| タスク名 | Replace the oil in the engine |
| ステータス（Status） | todo |
| 期日（Due date） | Dec 20, 2023 |
| 担当者（Assigned to） | John Smith |
| 設備（Equipment） | Boiler 1 |
| 説明（Description） | Boiler 1 has 237 error. We are fixing it now. |
| Cause of stoppage ※ | Oil contamination |
| Repair details ※ | Drained old oil, replaced oil filter, flushed system, filled with new oil to proper level |
| 使用部品（Parts Used） | Oil Filter（1232-13434AB, 数量1）、Oil（#5678, 数量3） |

**必須項目:** タスク名、ステータス

> **※ テナント独自入力項目について:**
> タスクの入力項目はテナントごとに設定可能です。入力項目自体もテナントが独自に作成できます。上記の「Cause of stoppage」「Repair details」はテナント独自入力項目の例です。

---

## 課題2: 追加機能 — タスクコメント機能

タスクに対してコメント（メモ・連絡事項）を複数登録できる機能を追加しました。

工場のタスク管理では、作業の進捗や引き継ぎ事項を複数の担当者が記録するケースが多く、コメント機能により以下が実現できます。

| ユースケース | 説明 |
|---|---|
| **作業履歴の時系列記録** | 誰がいつどのような対応をしたかを追跡できる |
| **担当者間の情報共有** | シフト交代時の引き継ぎがスムーズになる |
| **問題分析の支援** | 過去のコメントを参照して再発防止策を検討できる |

対応テーブル: `task_comments`

---

## テーブル構成

### 基本テーブル（課題1・課題2）

| テーブル | 説明 |
|---|---|
| `tenants` | テナント（工場環境）の管理 |
| `equipments` | 設備マスタ（親子階層対応） |
| `parts` | 部品マスタ（在庫数・発注点管理） |
| `equipment_parts` | 設備 ⇔ 部品の多対多関連 |
| `tasks` | タスク管理 |
| `task_parts` | タスクで使用する部品（数量付き） |
| `custom_field_definitions` | テナント独自のカスタム入力項目定義 |
| `custom_field_values` | カスタムフィールドの値（EAVパターン） |
| `task_comments` | 【課題2】タスクコメント |

### エンタープライズテーブル（高度機能）

| テーブル | 説明 |
|---|---|
| `users` | ユーザー管理（RBAC対応） |
| `audit_logs` | 監査ログ（全変更追跡・不変） |
| `security_events` | セキュリティイベント記録 |
| `api_keys` | APIキー管理 |
| `user_sessions` | セッション管理（RLS対応） |
| `failed_login_attempts` | 失敗ログイン追跡 |
| `ip_blocklist` | IPブロックリスト |
| `password_policies` | パスワードポリシー設定 |
| `rate_limit_configs` | レート制限設定 |
| `password_history` | パスワード履歴 |

## ER図

```mermaid
erDiagram
    tenants ||--o{ equipments : "has"
    tenants ||--o{ parts : "has"
    tenants ||--o{ tasks : "has"
    tenants ||--o{ custom_field_definitions : "defines"
    equipments ||--o{ equipments : "parent-child"
    equipments ||--o{ equipment_parts : "related"
    parts ||--o{ equipment_parts : "related"
    equipments ||--o{ tasks : "has"
    tasks ||--o{ task_parts : "uses"
    parts ||--o{ task_parts : "used_in"
    tasks ||--o{ custom_field_values : "has"
    custom_field_definitions ||--o{ custom_field_values : "defines"
    tasks ||--o{ task_comments : "has"
```

> 詳細なER図（カラム定義含む）は [`docs/er-diagram.mmd`](docs/er-diagram.mmd) を参照

---

## セットアップ

### 前提条件

- Docker / Docker Compose

### 起動

```bash
docker compose up -d
```

PostgreSQL が起動し、マイグレーション（テーブル作成 + シードデータ投入）が自動実行されます。

### Web UI

ブラウザで以下のURLにアクセスすると、データを視覚的に確認できます。

**http://localhost:8080**

Web UIでは以下の機能を提供しています:

| タブ | 機能 |
|---|---|
| **Dashboard** | タスク数統計、在庫アラート |
| **Tasks** | タスク一覧・詳細（カスタムフィールド・コメント表示） |
| **Equipments** | 設備の階層構造表示 |
| **Parts** | 部品在庫一覧・ステータス |
| **Custom Fields** | テナント独自入力項目定義（EAVパターン） |

### データベース接続情報

| 項目 | 値 |
|---|---|
| Host | `localhost` |
| Port | `5432` |
| Database | `m2x_task_management` |
| User | `m2x_user` |
| Password | `m2x_password` |

### 接続確認

```bash
docker compose exec db psql -U m2x_user -d m2x_task_management

# テーブル一覧の確認
\dt

# サンプルクエリの実行
\i /docker-entrypoint-initdb.d/sample_queries.sql
```

### 停止

```bash
docker compose down        # コンテナ停止
docker compose down -v     # コンテナ停止 + データ削除
```

---

## 設計方針

### 1. マルチテナント対応（論理分離方式）

本システムはマルチテナント対応が求められるため、**全テーブルに `tenant_id` カラムを保持**し、論理的なデータ分離を実現しています。

```
┌─────────────────────────────────────────────────────────┐
│                    データベース                          │
│  ┌─────────────────┐  ┌─────────────────┐              │
│  │ Tenant A のデータ │  │ Tenant B のデータ │  ...        │
│  │ tenant_id = 'A'  │  │ tenant_id = 'B'  │              │
│  └─────────────────┘  └─────────────────┘              │
└─────────────────────────────────────────────────────────┘
```

**採用理由:**
- **シンプルな実装**: 単一データベースで管理でき、運用コストが低い
- **クエリの一貫性**: 全テーブルで `WHERE tenant_id = ?` を付与するだけで分離可能
- **将来の拡張性**: 必要に応じて物理分離（スキーマ分離・DB分離）への移行も可能

**実装上の考慮点:**
- すべてのクエリで `tenant_id` による絞り込みを行うことが前提
- インデックスは `tenant_id` を先頭に配置し、テナント単位のクエリを高速化
- アプリケーション層でのテナント分離チェックが必須

---

### 2. テナント独自入力項目（EAVパターン）

課題の要件「入力する項目自体もテナントごとに独自に作成することができる」を満たすため、**EAV（Entity-Attribute-Value）パターン**を採用しました。

```
┌─────────────────────────────────────────────────────────────────────┐
│ EAV パターンの構造                                                    │
│                                                                     │
│  custom_field_definitions (Attribute: 項目定義)                      │
│  ┌──────────┬─────────────────────┬────────────┐                   │
│  │ tenant_id │ field_name          │ field_type │                   │
│  ├──────────┼─────────────────────┼────────────┤                   │
│  │ Tenant A │ Cause of stoppage   │ select     │                   │
│  │ Tenant A │ Repair details      │ text       │                   │
│  │ Tenant B │ Defect type         │ select     │  ← 異なる項目     │
│  └──────────┴─────────────────────┴────────────┘                   │
│                          ↓                                          │
│  custom_field_values (Value: 各タスクの値)                           │
│  ┌─────────┬─────────────────────┬──────────────────────┐          │
│  │ task_id │ field_definition_id │ value                │          │
│  ├─────────┼─────────────────────┼──────────────────────┤          │
│  │ Task 1  │ Cause of stoppage   │ Mechanical failure   │          │
│  │ Task 1  │ Repair details      │ Replaced motor unit  │          │
│  └─────────┴─────────────────────┴──────────────────────┘          │
└─────────────────────────────────────────────────────────────────────┘
```

**採用理由:**
- **柔軟性**: テナントごとに異なる入力項目を、スキーマ変更なしで追加・変更可能
- **要件適合**: 画面仕様の「Cause of stoppage」「Repair details」等のテナント固有項目を実現
- **運用効率**: 新規項目追加時にマイグレーション不要

**トレードオフと対策:**

| トレードオフ | 対策 |
|---|---|
| 型安全性の低下 | `field_type` カラムで型情報を保持し、アプリケーション層でバリデーション |
| クエリの複雑化 | ピボットクエリやJSON集約で対応（`sample_queries.sql` 参照） |
| パフォーマンス懸念 | 適切なインデックス設計、必要に応じてマテリアライズドビューを検討 |

**代替案の検討:**

| 方式 | 特徴 | 不採用理由 |
|---|---|---|
| JSON カラム | 柔軟だが検索・集計が複雑 | 項目定義の管理が困難、型バリデーションが難しい |
| 動的カラム追加 | パフォーマンス良好 | スキーマ変更が必要、テナント数増加で管理困難 |
| テナント別テーブル | 完全分離 | 運用コスト高、共通処理の実装が複雑 |

---

### 3. UUID 主キー

全テーブルで **UUID 型の主キー**を採用しています。

**採用理由:**
- **ID衝突の回避**: マルチテナント環境で、テナント間でのID重複リスクを排除
- **分散環境対応**: 将来的なシャーディングやデータ移行に対応しやすい
- **予測困難性**: 連番IDと異なり、外部からIDを推測されにくい（セキュリティ面）

**トレードオフ:**
- 連番に比べてストレージ容量が増加（16バイト vs 4/8バイト）
- インデックスサイズの増大
- デバッグ時の可読性が低下

これらのトレードオフは、マルチテナント環境でのデータ整合性・移行容易性のメリットが上回ると判断しました。

---

### 4. 設備の階層構造（自己参照）

設備詳細画面の「Parent Equipment」項目から、設備は親子関係を持つと想定し、**自己参照の外部キー**で階層を表現しています。

```sql
equipments.parent_equipment_id → equipments.id
```

**設計例:**
```
Assembly Line A          (parent_equipment_id = NULL)
  ├── Conveyor Belt A-1  (parent_equipment_id = Assembly Line A)
  ├── Robot Arm A-1      (parent_equipment_id = Assembly Line A)
  └── Quality Scanner    (parent_equipment_id = Assembly Line A)
```

**階層データの取得:** PostgreSQL の `WITH RECURSIVE` を使用（`sample_queries.sql` 参照）

---

### 5. タスクコメント機能【課題2】

工場現場での実用性を考慮し、以下の設計としました。

| 項目 | 設計 | 理由 |
|---|---|---|
| 投稿者 | `commented_by VARCHAR(255)` | ユーザーテーブル未定義のため文字列で保持。将来的にFKへ変更可能 |
| 削除 | `deleted_at` によるソフトデリート | 履歴保持の観点から物理削除は避ける |
| 時系列表示 | `created_at` でソート | コメント一覧は投稿順で表示することを想定 |

---

## 高度機能（エンタープライズ対応）

本システムでは、基本要件に加えてエンタープライズ環境で必要となる高度な機能を実装しています。

### グローバル基準準拠

| 規格 | 対応内容 |
|------|----------|
| **ISO 27001** | 監査ログによる全変更追跡 |
| **SOC 2** | アクセス制御とデータ整合性 |
| **GDPR** | ソフトデリートによる履歴保持 |
| **OWASP Top 10** | セキュリティイベント監視 |

### 追加テーブル（エンタープライズ機能）

| テーブル | 説明 |
|----------|------|
| `users` | RBAC対応ユーザー管理（admin/manager/operator/viewer） |
| `audit_logs` | 全データ変更の監査ログ（不変） |
| `security_events` | セキュリティイベント記録 |
| `api_keys` | APIキー管理（スコープ・有効期限付き） |
| `user_sessions` | セッション管理（RLS対応） |
| `failed_login_attempts` | ブルートフォース検出 |
| `ip_blocklist` | IP制限リスト |
| `password_policies` | テナント別パスワードポリシー |
| `rate_limit_configs` | APIレート制限設定 |

### セキュリティ機能

```sql
-- Row Level Security（テナント分離）
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
CREATE POLICY users_tenant_isolation ON users
    USING (tenant_id = current_tenant_id());

-- 監査ログは変更・削除不可（コンプライアンス要件）
CREATE TRIGGER prevent_audit_log_update
    BEFORE UPDATE OR DELETE ON audit_logs
    EXECUTE FUNCTION prevent_audit_log_modification();

-- 楽観的ロック（コンフリクト検出）
-- 全主要テーブルにversion列を追加
```

### データ整合性

| 機能 | 説明 |
|------|------|
| **楽観的ロック** | `version`列による並行更新コンフリクト検出 |
| **ソフトデリート** | 全テーブルに`deleted_at`追加、物理削除なし |
| **クロステナント制約** | トリガーによる親子関係の整合性保証 |
| **JSONバリデーション** | カスタムフィールド値の型チェック |

---

## 前提条件・仮定事項

| # | 仮定内容 | 根拠・補足 |
|---|---|---|
| 1 | マルチテナントは論理分離方式を採用 | 全テーブルに `tenant_id` を保持。物理分離が必要な場合は別途検討 |
| 2 | 設備は親子階層を持つ | 設備詳細画面の「Parent Equipment」項目から推定 |
| 3 | タスクステータスは固定の3種類 | 画面の「todo」表示から推定。必要に応じてマスタテーブル化可能 |
| 4 | 部品と設備は多対多の関係 | 部品詳細画面の「Related Equipment」から推定 |
| 5 | タスクに複数部品を使用数量付きで登録可能 | タスク詳細画面の「Parts Used」から推定 |
| 6 | カスタムフィールドはタスクに紐づく | 画面仕様の独自入力項目がタスク詳細画面に表示されていることから推定 |
| 7 | コメント投稿者はユーザーテーブルとは別管理 | ユーザーテーブルの仕様が不明なため、文字列で保持 |

---

## ディレクトリ構成

```
.
├── README.md                          # 本ドキュメント
├── docker-compose.yml                 # Docker Compose 設定
├── pyproject.toml                     # Python プロジェクト設定
│
├── db/                                # 【課題の解答】データベース設計
│   ├── migrations/
│   │   ├── 001_create_tables.sql      # テーブル定義（課題1 + 課題2）
│   │   ├── 002_seed_data.sql          # サンプルデータ
│   │   ├── 004_global_standard.sql    # エンタープライズ機能（RBAC/監査ログ）
│   │   ├── 005_seed_data_extension.sql # 追加シードデータ
│   │   └── 006_security_enhancements.sql # セキュリティ強化
│   └── queries/
│       └── sample_queries.sql         # 集計クエリ例（10種類）
│
├── docs/
│   └── er-diagram.mmd                 # ER図（Mermaid形式・詳細版）
│
├── web/                               # Web UI（データ確認用）
│   ├── api/                           # REST API エンドポイント
│   │   ├── auth.py                    # 認証API
│   │   └── tasks.py                   # タスクAPI
│   ├── core/                          # 設定・例外
│   ├── models/                        # Pydantic スキーマ
│   ├── repositories/                  # データアクセス層
│   ├── static/js/app.js               # フロントエンド（Vanilla JS）
│   ├── templates/index.html           # HTMLテンプレート
│   ├── tests/                         # テストスイート
│   ├── app.py                         # Flaskアプリケーション
│   └── requirements.txt               # Python依存関係
│
└── .github/workflows/ci.yml           # CI/CD設定
```

> **Note:** `web/` ディレクトリは課題の解答を視覚的に確認するためのUIです。
> 課題の本質的な解答は `db/` と `docs/er-diagram.mmd` に含まれています。

---

## 参考: サンプルクエリ

`db/queries/sample_queries.sql` に以下のクエリ例を収録しています。

1. 設備ごとのタスク数集計
2. 部品ごとの使用回数・在庫状況
3. タスク詳細（カスタムフィールド値を含む）の取得
4. カスタムフィールドをピボット形式で表示
5. 設備階層構造の表示（WITH RECURSIVE）
6. 部品の関連設備一覧
7. 期限切れ・期限間近のタスク
8. タスクコメント履歴【課題2】
9. 停止原因別の集計（カスタムフィールド分析）
10. 設備別ダウンタイム合計
