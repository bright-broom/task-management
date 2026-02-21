"""
Swagger/OpenAPI configuration for M2X Task Management API.

This module provides:
- OpenAPI 3.0 specification
- Swagger UI configuration
- API documentation templates
"""

from __future__ import annotations

SWAGGER_TEMPLATE = {
    "openapi": "3.0.3",
    "info": {
        "title": "M2X Task Management API",
        "description": """
## 概要

工場向けマルチテナント対応タスク管理システムのREST API。

### 主な機能

- **テナント管理**: マルチテナント環境でのデータ分離
- **設備管理**: 階層構造対応の設備マスタ
- **部品管理**: 在庫・発注点管理
- **タスク管理**: カスタムフィールド・コメント対応

### 認証

JWT Bearer認証を使用。`/api/auth/login`でトークンを取得し、
`Authorization: Bearer <token>`ヘッダーで認証。

### レート制限

- 一般エンドポイント: 60リクエスト/分
- 認証エンドポイント: 10リクエスト/分

### エラーレスポンス

すべてのエラーは以下の形式で返されます:

```json
{
  "error": "エラーメッセージ"
}
```
        """,
        "version": "1.0.0",
        "contact": {
            "name": "M2X Support",
            "email": "support@m2x.example.com",
        },
        "license": {
            "name": "MIT",
            "url": "https://opensource.org/licenses/MIT",
        },
    },
    "servers": [
        {"url": "/", "description": "Current server"},
    ],
    "tags": [
        {"name": "Health", "description": "ヘルスチェック"},
        {"name": "Tenants", "description": "テナント管理"},
        {"name": "Equipments", "description": "設備管理"},
        {"name": "Parts", "description": "部品管理"},
        {"name": "Tasks", "description": "タスク管理"},
        {"name": "Auth", "description": "認証"},
    ],
    "components": {
        "securitySchemes": {
            "BearerAuth": {
                "type": "http",
                "scheme": "bearer",
                "bearerFormat": "JWT",
                "description": "JWT認証トークン",
            }
        },
        "schemas": {
            "Error": {
                "type": "object",
                "properties": {"error": {"type": "string", "description": "エラーメッセージ"}},
            },
            "Pagination": {
                "type": "object",
                "properties": {
                    "page": {"type": "integer", "description": "現在のページ番号"},
                    "per_page": {"type": "integer", "description": "1ページあたりの件数"},
                    "total": {"type": "integer", "description": "総件数"},
                    "total_pages": {"type": "integer", "description": "総ページ数"},
                },
            },
            "Tenant": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "format": "uuid"},
                    "name": {"type": "string"},
                    "created_at": {"type": "string", "format": "date-time"},
                    "updated_at": {"type": "string", "format": "date-time"},
                },
                "example": {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "name": "東京工場",
                    "created_at": "2024-01-01T00:00:00Z",
                    "updated_at": "2024-01-01T00:00:00Z",
                },
            },
            "Equipment": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "format": "uuid"},
                    "tenant_id": {"type": "string", "format": "uuid"},
                    "name": {"type": "string"},
                    "parent_id": {"type": "string", "format": "uuid", "nullable": True},
                    "manufacturer": {"type": "string"},
                    "description": {"type": "string"},
                    "depth": {"type": "integer"},
                    "created_at": {"type": "string", "format": "date-time"},
                    "updated_at": {"type": "string", "format": "date-time"},
                },
                "example": {
                    "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    "tenant_id": "11111111-1111-1111-1111-111111111111",
                    "name": "CNC旋盤 A-001",
                    "parent_id": None,
                    "manufacturer": "ファナック",
                    "description": "メイン加工エリア旋盤",
                    "depth": 0,
                    "created_at": "2024-01-01T00:00:00Z",
                    "updated_at": "2024-01-01T00:00:00Z",
                },
            },
            "Part": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "format": "uuid"},
                    "tenant_id": {"type": "string", "format": "uuid"},
                    "name": {"type": "string"},
                    "part_number": {"type": "string"},
                    "stock_quantity": {"type": "integer"},
                    "reorder_point": {"type": "integer"},
                    "unit_price": {"type": "number"},
                    "related_equipments": {"type": "string"},
                    "created_at": {"type": "string", "format": "date-time"},
                    "updated_at": {"type": "string", "format": "date-time"},
                },
                "example": {
                    "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                    "tenant_id": "11111111-1111-1111-1111-111111111111",
                    "name": "ベアリング 6205",
                    "part_number": "SKF-6205-2RS",
                    "stock_quantity": 15,
                    "reorder_point": 5,
                    "unit_price": 1500.00,
                    "related_equipments": "CNC旋盤 A-001, CNC旋盤 A-002",
                    "created_at": "2024-01-01T00:00:00Z",
                    "updated_at": "2024-01-01T00:00:00Z",
                },
            },
            "Task": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "format": "uuid"},
                    "tenant_id": {"type": "string", "format": "uuid"},
                    "equipment_id": {"type": "string", "format": "uuid"},
                    "equipment_name": {"type": "string"},
                    "title": {"type": "string"},
                    "description": {"type": "string", "nullable": True},
                    "status": {
                        "type": "string",
                        "enum": ["open", "in_progress", "completed", "cancelled"],
                    },
                    "priority": {
                        "type": "string",
                        "enum": ["low", "medium", "high", "critical"],
                    },
                    "category": {
                        "type": "string",
                        "enum": ["maintenance", "repair", "inspection", "emergency"],
                    },
                    "assigned_to": {"type": "string", "nullable": True},
                    "due_date": {"type": "string", "format": "date", "nullable": True},
                    "version": {"type": "integer"},
                    "created_at": {"type": "string", "format": "date-time"},
                    "updated_at": {"type": "string", "format": "date-time"},
                },
                "example": {
                    "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
                    "tenant_id": "11111111-1111-1111-1111-111111111111",
                    "equipment_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    "equipment_name": "CNC旋盤 A-001",
                    "title": "定期メンテナンス - 潤滑油交換",
                    "description": "月次定期メンテナンスとして潤滑油の交換を実施",
                    "status": "open",
                    "priority": "medium",
                    "category": "maintenance",
                    "assigned_to": "田中太郎",
                    "due_date": "2024-02-01",
                    "version": 1,
                    "created_at": "2024-01-15T09:00:00Z",
                    "updated_at": "2024-01-15T09:00:00Z",
                },
            },
            "TaskCreate": {
                "type": "object",
                "required": ["title", "equipment_id"],
                "properties": {
                    "title": {"type": "string", "minLength": 1, "maxLength": 255},
                    "description": {"type": "string", "maxLength": 2000},
                    "equipment_id": {"type": "string", "format": "uuid"},
                    "status": {
                        "type": "string",
                        "enum": ["open", "in_progress", "completed", "cancelled"],
                        "default": "open",
                    },
                    "priority": {
                        "type": "string",
                        "enum": ["low", "medium", "high", "critical"],
                        "default": "medium",
                    },
                    "category": {
                        "type": "string",
                        "enum": ["maintenance", "repair", "inspection", "emergency"],
                        "default": "maintenance",
                    },
                    "assigned_to": {"type": "string", "maxLength": 255},
                    "due_date": {"type": "string", "format": "date"},
                },
                "example": {
                    "title": "ベアリング交換",
                    "description": "主軸ベアリングの異音が発生しているため交換",
                    "equipment_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    "status": "open",
                    "priority": "high",
                    "category": "repair",
                    "assigned_to": "山田花子",
                    "due_date": "2024-02-15",
                },
            },
            "TaskUpdate": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "minLength": 1, "maxLength": 255},
                    "description": {"type": "string", "maxLength": 2000},
                    "status": {
                        "type": "string",
                        "enum": ["open", "in_progress", "completed", "cancelled"],
                    },
                    "priority": {
                        "type": "string",
                        "enum": ["low", "medium", "high", "critical"],
                    },
                    "category": {
                        "type": "string",
                        "enum": ["maintenance", "repair", "inspection", "emergency"],
                    },
                    "assigned_to": {"type": "string", "maxLength": 255},
                    "due_date": {"type": "string", "format": "date"},
                    "version": {
                        "type": "integer",
                        "description": "楽観的ロック用バージョン（必須）",
                    },
                },
                "example": {
                    "status": "completed",
                    "description": "ベアリング交換完了。試運転OK。",
                    "version": 1,
                },
            },
            "Comment": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "format": "uuid"},
                    "task_id": {"type": "string", "format": "uuid"},
                    "tenant_id": {"type": "string", "format": "uuid"},
                    "commented_by": {"type": "string"},
                    "comment": {"type": "string"},
                    "created_at": {"type": "string", "format": "date-time"},
                    "deleted_at": {"type": "string", "format": "date-time", "nullable": True},
                },
                "example": {
                    "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
                    "task_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
                    "tenant_id": "11111111-1111-1111-1111-111111111111",
                    "commented_by": "田中太郎",
                    "comment": "部品の在庫を確認しました。明日到着予定です。",
                    "created_at": "2024-01-15T10:30:00Z",
                    "deleted_at": None,
                },
            },
            "CommentCreate": {
                "type": "object",
                "required": ["commented_by", "comment"],
                "properties": {
                    "commented_by": {"type": "string", "minLength": 1, "maxLength": 255},
                    "comment": {"type": "string", "minLength": 1, "maxLength": 5000},
                },
                "example": {
                    "commented_by": "山田花子",
                    "comment": "作業を開始しました。予定通り完了見込みです。",
                },
            },
            "AuthLogin": {
                "type": "object",
                "required": ["email", "password", "tenant_id"],
                "properties": {
                    "email": {"type": "string", "format": "email"},
                    "password": {"type": "string", "minLength": 8},
                    "tenant_id": {"type": "string", "format": "uuid"},
                },
                "example": {
                    "email": "user@example.com",
                    "password": "securepassword123",
                    "tenant_id": "11111111-1111-1111-1111-111111111111",
                },
            },
            "AuthToken": {
                "type": "object",
                "properties": {
                    "access_token": {"type": "string"},
                    "refresh_token": {"type": "string"},
                    "token_type": {"type": "string", "example": "Bearer"},
                    "expires_in": {"type": "integer", "example": 3600},
                },
                "example": {
                    "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
                    "refresh_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                },
            },
            "HealthCheck": {
                "type": "object",
                "properties": {
                    "status": {"type": "string", "example": "healthy"},
                    "database": {"type": "string", "example": "connected"},
                    "timestamp": {"type": "string", "format": "date-time"},
                },
            },
        },
    },
}

SWAGGER_CONFIG = {
    "headers": [],
    "specs": [
        {
            "endpoint": "apispec",
            "route": "/apispec.json",
            "rule_filter": lambda rule: True,
            "model_filter": lambda tag: True,
        }
    ],
    "static_url_path": "/flasgger_static",
    "swagger_ui": True,
    "specs_route": "/docs",
}


def init_swagger(app: object) -> None:
    """
    FlaskアプリケーションにSwagger UIを初期化。

    Args:
        app: Flaskアプリケーションインスタンス
    """
    from flasgger import Swagger

    Swagger(app, template=SWAGGER_TEMPLATE, config=SWAGGER_CONFIG)
