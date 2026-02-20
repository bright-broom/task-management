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
            },
            "Equipment": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "format": "uuid"},
                    "tenant_id": {"type": "string", "format": "uuid"},
                    "name": {"type": "string"},
                    "parent_id": {"type": "string", "format": "uuid", "nullable": True},
                    "depth": {"type": "integer"},
                    "created_at": {"type": "string", "format": "date-time"},
                    "updated_at": {"type": "string", "format": "date-time"},
                },
            },
            "Part": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "format": "uuid"},
                    "tenant_id": {"type": "string", "format": "uuid"},
                    "name": {"type": "string"},
                    "stock_quantity": {"type": "integer"},
                    "reorder_point": {"type": "integer"},
                    "related_equipments": {"type": "string"},
                    "created_at": {"type": "string", "format": "date-time"},
                    "updated_at": {"type": "string", "format": "date-time"},
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
                        "enum": ["todo", "in_progress", "done"],
                    },
                    "due_date": {"type": "string", "format": "date", "nullable": True},
                    "created_at": {"type": "string", "format": "date-time"},
                    "updated_at": {"type": "string", "format": "date-time"},
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
                        "enum": ["todo", "in_progress", "done"],
                        "default": "todo",
                    },
                    "due_date": {"type": "string", "format": "date"},
                },
            },
            "TaskUpdate": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "minLength": 1, "maxLength": 255},
                    "description": {"type": "string", "maxLength": 2000},
                    "status": {"type": "string", "enum": ["todo", "in_progress", "done"]},
                    "due_date": {"type": "string", "format": "date"},
                    "version": {
                        "type": "integer",
                        "description": "楽観的ロック用バージョン",
                    },
                },
            },
            "AuthLogin": {
                "type": "object",
                "required": ["email", "password"],
                "properties": {
                    "email": {"type": "string", "format": "email"},
                    "password": {"type": "string", "minLength": 8},
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
    from flasgger import Swagger  # type: ignore[import-untyped]

    Swagger(app, template=SWAGGER_TEMPLATE, config=SWAGGER_CONFIG)
