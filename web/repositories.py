"""Backward compatibility re-export for repositories module.

This module re-exports from repositories package for backward compatibility.
New code should import from repositories directly.
"""

from repositories import (
    BaseRepository,
    CommentRepository,
    EquipmentRepository,
    PartRepository,
    TaskRepository,
    TenantRepository,
    comment_repository,
    equipment_repository,
    part_repository,
    task_repository,
    tenant_repository,
)

__all__ = [
    "BaseRepository",
    "TaskRepository",
    "CommentRepository",
    "EquipmentRepository",
    "PartRepository",
    "TenantRepository",
    "task_repository",
    "comment_repository",
    "equipment_repository",
    "part_repository",
    "tenant_repository",
]
