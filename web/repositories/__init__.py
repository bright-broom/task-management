"""Repositories module for M2X Task Management System."""

from repositories.base import BaseRepository
from repositories.comment import CommentRepository, comment_repository
from repositories.equipment import EquipmentRepository, equipment_repository
from repositories.part import PartRepository, part_repository
from repositories.task import TaskRepository, task_repository
from repositories.tenant import TenantRepository, tenant_repository

__all__ = [
    # Base
    "BaseRepository",
    # Task
    "TaskRepository",
    "task_repository",
    # Comment
    "CommentRepository",
    "comment_repository",
    # Equipment
    "EquipmentRepository",
    "equipment_repository",
    # Part
    "PartRepository",
    "part_repository",
    # Tenant
    "TenantRepository",
    "tenant_repository",
]
