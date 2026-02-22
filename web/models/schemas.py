"""
Pydantic schemas for M2X Task Management System.

This module provides request/response validation using Pydantic v2.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator


class TaskStatus(str, Enum):
    """Task status enumeration matching DB schema."""

    TODO = "todo"
    IN_PROGRESS = "in_progress"
    DONE = "done"


class TaskPriority(str, Enum):
    """Task priority enumeration."""

    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"


class TaskCategory(str, Enum):
    """Task category enumeration."""

    MAINTENANCE = "maintenance"
    REPAIR = "repair"
    INSPECTION = "inspection"
    EMERGENCY = "emergency"


class BaseSchema(BaseModel):
    """Base schema with common configuration."""

    model_config = ConfigDict(
        from_attributes=True,
        str_strip_whitespace=True,
        validate_assignment=True,
    )


class TaskCreate(BaseSchema):
    """Schema for creating a new task."""

    title: str = Field(..., min_length=1, max_length=255, description="Task title")
    equipment_id: UUID | None = Field(None, description="Equipment UUID (optional)")
    description: str | None = Field(None, max_length=2000, description="Task description")
    status: TaskStatus = Field(default=TaskStatus.TODO, description="Task status")
    priority: TaskPriority = Field(default=TaskPriority.MEDIUM, description="Task priority")
    category: TaskCategory = Field(default=TaskCategory.MAINTENANCE, description="Task category")
    assigned_to: str | None = Field(None, max_length=255, description="Assignee name")
    due_date: datetime | None = Field(None, description="Due date")

    @field_validator("title")
    @classmethod
    def title_not_empty(cls, v: str) -> str:
        """Ensure title is not just whitespace."""
        if not v.strip():
            raise ValueError("Title cannot be empty")
        return v.strip()


class TaskUpdate(BaseSchema):
    """Schema for updating an existing task."""

    title: str | None = Field(None, min_length=1, max_length=255)
    description: str | None = Field(None, max_length=2000)
    status: TaskStatus | None = None
    priority: TaskPriority | None = None
    category: TaskCategory | None = None
    assigned_to: str | None = Field(None, max_length=255)
    due_date: datetime | None = None
    version: int = Field(..., ge=1, description="Version for optimistic locking")


class TaskResponse(BaseSchema):
    """Schema for task response."""

    id: UUID
    tenant_id: UUID
    equipment_id: UUID | None = None
    title: str
    description: str | None = None
    status: TaskStatus
    priority: TaskPriority
    category: TaskCategory
    assigned_to: str | None = None
    due_date: datetime | None = None
    version: int
    created_at: datetime
    updated_at: datetime


class CommentCreate(BaseSchema):
    """Schema for creating a task comment."""

    commented_by: str = Field(..., min_length=1, max_length=255, description="Commenter name")
    comment: str = Field(..., min_length=1, max_length=5000, description="Comment text")

    @field_validator("commented_by", "comment")
    @classmethod
    def not_empty(cls, v: str) -> str:
        """Ensure field is not just whitespace."""
        if not v.strip():
            raise ValueError("Field cannot be empty")
        return v.strip()


class CommentResponse(BaseSchema):
    """Schema for comment response."""

    id: UUID
    task_id: UUID
    tenant_id: UUID
    commented_by: str
    comment: str
    created_at: datetime
    deleted_at: datetime | None = None


class LoginRequest(BaseSchema):
    """Schema for login request."""

    email: EmailStr = Field(..., description="User email")
    password: str = Field(..., min_length=8, max_length=128, description="User password")
    tenant_id: UUID = Field(..., description="Tenant UUID")


class TokenResponse(BaseSchema):
    """Schema for authentication token response."""

    access_token: str
    refresh_token: str
    token_type: str = "Bearer"
    expires_in: int = 3600


class RefreshRequest(BaseSchema):
    """Schema for token refresh request."""

    refresh_token: str = Field(..., description="Refresh token")


class UserResponse(BaseSchema):
    """Schema for user response."""

    id: UUID
    email: str
    tenant_id: UUID
    role: str
    created_at: datetime


class PaginationMeta(BaseSchema):
    """Schema for pagination metadata."""

    page: int = Field(..., ge=1)
    per_page: int = Field(..., ge=1, le=100)
    total: int = Field(..., ge=0)
    total_pages: int = Field(..., ge=0)


class PaginatedResponse(BaseSchema):
    """Schema for paginated response."""

    items: list[dict[str, Any]]
    pagination: PaginationMeta


class EquipmentResponse(BaseSchema):
    """Schema for equipment response."""

    id: UUID
    tenant_id: UUID
    name: str
    parent_equipment_id: UUID | None = None
    manufacturer: str | None = None
    description: str | None = None


class PartResponse(BaseSchema):
    """Schema for part response."""

    id: UUID
    tenant_id: UUID
    name: str
    part_number: str | None = None
    stock_quantity: int = 0
    reorder_point: int = 0
    unit_price: float | None = None


class HealthCheckResponse(BaseSchema):
    """Schema for health check response."""

    status: str
    database: str


class TenantResponse(BaseSchema):
    """Schema for tenant response."""

    id: UUID
    name: str
    description: str | None = None


class ErrorResponse(BaseSchema):
    """Schema for error response."""

    error: str
    code: str | None = None
    details: dict[str, Any] | None = None
