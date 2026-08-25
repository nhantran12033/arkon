"""
Roles router — CRUD for custom RBAC roles (Permission model v2).

A Role is a named, reusable set of scoped permission strings (see
app.services.permissions.ALL_PERMISSIONS). Roles can be assigned to employees
via Employee.custom_role_id, where they override the fixed `global_role` map.

System roles (is_system=True) are seeded and cannot be edited or deleted.

Gating:
  - Read endpoints  → org:roles:read
  - Write endpoints → org:roles:manage
"""

import uuid
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.database.models import Employee, Role
from app.services.audit_service import log_audit
from app.services.auth_service import get_current_user, require_permission
from app.services.permissions import (
    ALL_PERMISSIONS,
    PERMISSION_DESCRIPTIONS,
    PERMISSION_GROUPS,
    PERMISSION_LABELS,
)

router = APIRouter()

_VALID_PERMISSIONS = set(ALL_PERMISSIONS)


# ---------------------------------------------------------------------------
# DTOs
# ---------------------------------------------------------------------------

class RoleCreate(BaseModel):
    name: str
    description: Optional[str] = None
    permissions: list[str] = []


class RoleOut(BaseModel):
    id: str
    name: str
    description: Optional[str] = None
    permissions: list[str] = []
    is_system: bool = False
    member_count: int = 0

    class Config:
        from_attributes = True


class PermissionItem(BaseModel):
    code: str
    label: str
    description: Optional[str] = None


class PermissionGroup(BaseModel):
    key: str
    permissions: list[PermissionItem]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _clean_permissions(perms: list[str]) -> list[str]:
    """Keep only known permission codes, de-duplicated, preserving catalog order."""
    requested = set(perms)
    unknown = requested - _VALID_PERMISSIONS
    if unknown:
        raise HTTPException(
            400, f"Unknown permission(s): {', '.join(sorted(unknown))}"
        )
    # Order by ALL_PERMISSIONS for stable storage/UI.
    return [p for p in ALL_PERMISSIONS if p in requested]


async def _member_counts(db: AsyncSession) -> dict[uuid.UUID, int]:
    rows = (
        await db.execute(
            select(Employee.custom_role_id, func.count(Employee.id))
            .where(Employee.custom_role_id.is_not(None))
            .group_by(Employee.custom_role_id)
        )
    ).all()
    return {row[0]: row[1] for row in rows}


# ---------------------------------------------------------------------------
# Permission catalog (for the role editor UI)
# ---------------------------------------------------------------------------

@router.get("/roles/permission-catalog", response_model=list[PermissionGroup])
async def permission_catalog(
    _user: Employee = require_permission("org:roles:read"),
):
    """Grouped list of every assignable permission, with labels + descriptions."""
    groups: list[PermissionGroup] = []
    for group_key, codes in PERMISSION_GROUPS.items():
        groups.append(
            PermissionGroup(
                key=group_key,
                permissions=[
                    PermissionItem(
                        code=code,
                        label=PERMISSION_LABELS.get(code, code),
                        description=PERMISSION_DESCRIPTIONS.get(code),
                    )
                    for code in codes
                ],
            )
        )
    return groups


# ---------------------------------------------------------------------------
# Role CRUD
# ---------------------------------------------------------------------------

@router.get("/roles", response_model=list[RoleOut])
async def list_roles(
    db: AsyncSession = Depends(get_db),
    _user: Employee = require_permission("org:roles:read"),
):
    """List all roles (system + custom) with their member counts."""
    roles = (
        await db.execute(select(Role).order_by(Role.is_system.desc(), Role.name))
    ).scalars().all()
    counts = await _member_counts(db)

    return [
        RoleOut(
            id=str(r.id),
            name=r.name,
            description=r.description,
            permissions=list(r.permissions or []),
            is_system=r.is_system,
            member_count=counts.get(r.id, 0),
        )
        for r in roles
    ]


@router.post("/roles", response_model=RoleOut, status_code=201)
async def create_role(
    body: RoleCreate,
    db: AsyncSession = Depends(get_db),
    _user: Employee = require_permission("org:roles:manage"),
):
    """Create a new custom role."""
    name = body.name.strip()
    if not name:
        raise HTTPException(400, "Role name is required")

    existing = (
        await db.execute(select(Role).where(func.lower(Role.name) == name.lower()))
    ).scalar_one_or_none()
    if existing:
        raise HTTPException(409, "A role with this name already exists")

    perms = _clean_permissions(body.permissions)
    role = Role(
        name=name,
        description=(body.description or None),
        permissions=perms,
        is_system=False,
    )
    db.add(role)
    await db.flush()
    await log_audit(db, _user, "create", "role", str(role.id), reason=role.name)

    return RoleOut(
        id=str(role.id),
        name=role.name,
        description=role.description,
        permissions=perms,
        is_system=False,
        member_count=0,
    )


@router.put("/roles/{role_id}", response_model=RoleOut)
async def update_role(
    role_id: str,
    body: RoleCreate,
    db: AsyncSession = Depends(get_db),
    _user: Employee = require_permission("org:roles:manage"),
):
    """Update a custom role's name, description, and permissions."""
    role = await db.get(Role, uuid.UUID(role_id))
    if not role:
        raise HTTPException(404, "Role not found")
    if role.is_system:
        raise HTTPException(400, "System roles cannot be edited")

    name = body.name.strip()
    if not name:
        raise HTTPException(400, "Role name is required")

    clash = (
        await db.execute(
            select(Role).where(
                func.lower(Role.name) == name.lower(), Role.id != role.id
            )
        )
    ).scalar_one_or_none()
    if clash:
        raise HTTPException(409, "A role with this name already exists")

    role.name = name
    role.description = body.description or None
    role.permissions = _clean_permissions(body.permissions)
    await db.flush()
    await log_audit(db, _user, "update", "role", str(role.id), reason=role.name)

    counts = await _member_counts(db)
    return RoleOut(
        id=str(role.id),
        name=role.name,
        description=role.description,
        permissions=list(role.permissions or []),
        is_system=role.is_system,
        member_count=counts.get(role.id, 0),
    )


@router.delete("/roles/{role_id}")
async def delete_role(
    role_id: str,
    db: AsyncSession = Depends(get_db),
    _user: Employee = require_permission("org:roles:manage"),
):
    """Delete a custom role. Assigned employees revert to their global_role
    (custom_role_id is set NULL by the FK ON DELETE rule)."""
    role = await db.get(Role, uuid.UUID(role_id))
    if not role:
        raise HTTPException(404, "Role not found")
    if role.is_system:
        raise HTTPException(400, "System roles cannot be deleted")

    await log_audit(db, _user, "delete", "role", str(role.id), reason=role.name)
    await db.delete(role)
    return {"deleted": True}
