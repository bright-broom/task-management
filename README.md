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

### 1. マルチテナント対応（論理分離方式 + Row Level Security）

本システムはマルチテナント対応が求められるため、**全テーブルに `tenant_id` カラムを保持**し、さらに **PostgreSQL の Row Level Security (RLS)** を使用してデータベースレベルでの強制的なテナント分離を実現しています。

```
┌─────────────────────────────────────────────────────────────────────┐
│                         データベース (RLS有効)                        │
│  ┌─────────────────┐  ┌─────────────────┐                          │
│  │ Tenant A のデータ │  │ Tenant B のデータ │  ...                    │
│  │ tenant_id = 'A'  │  │ tenant_id = 'B'  │                          │
│  └────────┬────────┘  └────────┬────────┘                          │
│           │                     │                                    │
│           │  RLSポリシーが自動的にフィルタリング                      │
│           └─────────────────────┘                                    │
└─────────────────────────────────────────────────────────────────────┘
```

**Row Level Security (RLS) の導入:**

従来のアプリケーション層のみでのテナント分離では、クエリの `WHERE` 句の付け忘れなどのバグでデータ漏洩のリスクがありました。RLSを導入することで、**データベースが自動的にテナントフィルタを適用**し、アプリケーションにバグがあっても他テナントのデータにアクセスできなくなります。

```sql
-- RLSポリシーの例
CREATE POLICY tasks_tenant_isolation ON tasks
    FOR ALL
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- アプリケーションは接続時にテナントコンテキストを設定
SET app.current_tenant_id = '11111111-1111-1111-1111-111111111111';
```

**採用理由:**
- **Defense in Depth（多層防御）**: アプリケーション層 + データベース層の二重チェック
- **シンプルな実装**: 単一データベースで管理でき、運用コストが低い
- **クエリの一貫性**: 全テーブルで `WHERE tenant_id = ?` を付与するだけで分離可能
- **将来の拡張性**: 必要に応じて物理分離（スキーマ分離・DB分離）への移行も可能

**実装上の考慮点:**
- すべてのクエリで `tenant_id` による絞り込みを行うことが前提
- インデックスは `tenant_id` を先頭に配置し、テナント単位のクエリを高速化
- RLSを有効にしたテーブルでは、テナントコンテキスト設定が必須

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

### 6. RESTful API 設計

本システムのAPIは以下の設計原則に従っています。

**CRUD操作:**

| メソッド | エンドポイント例 | 説明 |
|----------|------------------|------|
| GET | `/api/tenants/{id}/tasks` | タスク一覧取得 |
| GET | `/api/tasks/{id}/details` | タスク詳細取得 |
| POST | `/api/tenants/{id}/tasks` | タスク新規作成 |
| PATCH | `/api/tasks/{id}` | タスク部分更新 |
| DELETE | `/api/comments/{id}` | コメント削除（ソフトデリート） |

**ページネーション:**

リスト取得APIは全てページネーションに対応しています。

```json
// リクエスト: GET /api/tenants/{id}/tasks?page=1&per_page=20&status=todo

// レスポンス:
{
  "items": [...],
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total": 150,
    "total_pages": 8
  }
}
```

**フィルタリング:**

| エンドポイント | クエリパラメータ | 説明 |
|----------------|------------------|------|
| `/tasks` | `status` | ステータスでフィルタ (todo, in_progress, done) |
| `/tasks` | `equipment_id` | 設備IDでフィルタ |
| `/parts` | `low_stock` | 在庫不足のみ表示 (true/false) |

**入力バリデーション:**

- UUID形式チェック（カスタムデコレータ）
- 必須フィールドチェック
- 文字列長制限（サニタイズ処理）
- ENUM値チェック（status等）

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
├── .pre-commit-config.yaml            # Pre-commit フック設定
├── .github/
│   └── workflows/
│       └── ci.yml                     # GitHub Actions CI/CD
├── db/
│   ├── migrations/
│   │   ├── 001_create_tables.sql      # テーブル定義（課題1 + 課題2）
│   │   ├── 002_seed_data.sql          # サンプルデータ
│   │   └── 003_row_level_security.sql # RLSポリシー定義
│   └── queries/
│       └── sample_queries.sql         # 集計クエリ例
├── web/                               # Web UI（Flask）
│   ├── Dockerfile
│   ├── app.py                         # APIサーバー（CRUD対応）
│   ├── requirements.txt
│   ├── requirements-dev.txt           # 開発用依存関係
│   ├── templates/
│   │   └── index.html                 # SPA フロントエンド
│   └── tests/                         # テストコード（60+テストケース）
│       ├── conftest.py                # pytest設定・フィクスチャ
│       ├── test_database.py           # DB・スキーマテスト
│       └── test_api.py                # APIエンドポイント・CRUDテスト
└── docs/
    ├── er-diagram.mmd                 # ER図（Mermaid形式）
    └── openapi.yaml                   # API仕様書（OpenAPI 3.0）
```

---

## 品質管理

### テスト

pytest を使用したテストスイートを実装しています。

```bash
# 開発用依存関係のインストール
pip install -r web/requirements-dev.txt

# テスト実行
cd web && pytest tests/ -v

# カバレッジ付きテスト実行
cd web && pytest tests/ -v --cov=. --cov-report=term-missing
```

**テストカテゴリ:**

| カテゴリ | ファイル | 内容 |
|----------|----------|------|
| DBスキーマ | `test_database.py` | テーブル構造、制約、マルチテナント分離 |
| API | `test_api.py` | エンドポイント、レスポンス形式、エラーハンドリング |
| EAV | `test_database.py` | カスタムフィールド定義・値の整合性 |

### CI/CD

GitHub Actions で以下を自動実行しています（`.github/workflows/ci.yml`）:

| ジョブ | 内容 |
|--------|------|
| **test** | pytest + カバレッジレポート（Codecov連携） |
| **lint** | Black, isort, flake8 によるコードフォーマット・静的解析 |
| **docker** | Docker イメージビルド・ヘルスチェック・API スモークテスト |

### Pre-commit Hooks

開発時のコード品質を自動的にチェックするため、pre-commit フックを設定しています。

```bash
# 初回セットアップ
pip install pre-commit
pre-commit install

# 全ファイルに対して手動実行
pre-commit run --all-files
```

**設定済みフック:**

| フック | 説明 |
|--------|------|
| trailing-whitespace | 末尾空白の削除 |
| end-of-file-fixer | ファイル末尾の改行修正 |
| black | Python コードフォーマット |
| isort | import 文のソート |
| flake8 | Python lint |
| bandit | セキュリティスキャン |

### API仕様書

OpenAPI 3.0 形式の仕様書を提供しています: [`docs/openapi.yaml`](docs/openapi.yaml)

Swagger UI などで閲覧可能です:
```bash
# Swagger UI で閲覧（Docker使用）
docker run -p 8081:8080 -e SWAGGER_JSON=/docs/openapi.yaml -v $(pwd)/docs:/docs swaggerapi/swagger-ui
```

### コード品質

| 項目 | 対応状況 |
|------|----------|
| 入力バリデーション | UUID形式チェック、エラーレスポンス |
| エラーハンドリング | 404/500/DB エラーハンドラー実装 |
| ログ出力 | Python logging モジュール使用 |
| DB接続管理 | コンテキストマネージャで漏れ防止 |
| XSS対策 | フロントエンドで `escapeHtml()` 実装 |
| SQLインジェクション対策 | パラメータ化クエリ使用 |

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
