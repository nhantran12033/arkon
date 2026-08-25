"""add custom roles

Re-introduces a `roles` table (custom RBAC roles) and an
`employees.custom_role_id` FK. Unlike the pre-034 design, `global_role` is
kept as the fallback — a custom role only *overrides* it when assigned.
Seeds two system roles (Admin, Employee) so the Roles admin UI has content.

Revision ID: 037_add_custom_roles
Revises: 036_verbatim_sources
Create Date: 2026-08-20

"""
import json
import uuid
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

# revision identifiers
revision: str = "037_add_custom_roles"
down_revision: Union[str, None] = "036_verbatim_sources"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "roles",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(length=100), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column(
            "permissions",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column(
            "is_system", sa.Boolean(), nullable=False, server_default=sa.text("false")
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("name"),
    )

    op.add_column(
        "employees",
        sa.Column("custom_role_id", postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.create_foreign_key(
        "fk_employees_custom_role_id_roles",
        "employees",
        "roles",
        ["custom_role_id"],
        ["id"],
        ondelete="SET NULL",
    )

    # --- Seed system roles ------------------------------------------------
    # Import here (not at module top) so migration import never fails if the
    # app package is unavailable during offline SQL generation.
    try:
        from app.services.permissions import (
            ALL_PERMISSIONS,
            EMPLOYEE_DEFAULT_PERMISSIONS,
        )
    except Exception:  # pragma: no cover — fallback keeps the migration runnable
        ALL_PERMISSIONS = []
        EMPLOYEE_DEFAULT_PERMISSIONS = []

    conn = op.get_bind()
    seed = [
        ("Admin", "Full access to all features", list(ALL_PERMISSIONS)),
        (
            "Employee",
            "Default access for regular employees",
            list(EMPLOYEE_DEFAULT_PERMISSIONS),
        ),
    ]
    for name, description, perms in seed:
        conn.execute(
            sa.text(
                """
                INSERT INTO roles (id, name, description, permissions, is_system)
                VALUES (:id, :name, :description, CAST(:perms AS JSONB), true)
                ON CONFLICT (name) DO NOTHING
                """
            ),
            {
                "id": str(uuid.uuid4()),
                "name": name,
                "description": description,
                "perms": json.dumps(perms),
            },
        )


def downgrade() -> None:
    op.drop_constraint(
        "fk_employees_custom_role_id_roles", "employees", type_="foreignkey"
    )
    op.drop_column("employees", "custom_role_id")
    op.drop_table("roles")
