"use client";

import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";
import { PageHeader } from "@/components/shared/page-header";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { RoleDialog, type Role } from "@/components/roles/role-dialog";

export default function RolesPage() {
  const [roles, setRoles] = useState<Role[]>([]);
  const [loading, setLoading] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editRole, setEditRole] = useState<Role | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<Role | null>(null);
  const [deleting, setDeleting] = useState(false);

  const loadRoles = useCallback(async () => {
    setLoading(true);
    try {
      const data = await api<Role[]>("/api/roles");
      setRoles(data);
    } catch {
      setRoles([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadRoles();
  }, [loadRoles]);

  const handleCreate = () => {
    setEditRole(null);
    setDialogOpen(true);
  };

  const handleEdit = (role: Role) => {
    setEditRole(role);
    setDialogOpen(true);
  };

  const confirmDelete = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await api(`/api/roles/${deleteTarget.id}`, { method: "DELETE" });
      setDeleteTarget(null);
      loadRoles();
    } finally {
      setDeleting(false);
    }
  };

  return (
    <>
      <PageHeader
        title="Roles"
        description="Define permission sets that can be assigned to employees."
        action={
          <Button
            onClick={handleCreate}
            className="bg-primary text-primary-foreground hover:bg-primary/90"
          >
            <span className="material-symbols-outlined text-base mr-1">add</span>
            Create Role
          </Button>
        }
      />

      {loading ? (
        <p className="text-sm text-muted-foreground py-8">Loading roles…</p>
      ) : roles.length === 0 ? (
        <p className="text-sm text-muted-foreground py-8">
          No roles yet. Create one to get started.
        </p>
      ) : (
        <div className="flex flex-col gap-3">
          {roles.map((role) => (
            <div
              key={role.id}
              className="rounded-xl border border-black/[0.06] bg-background p-4"
            >
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <h3 className="font-medium text-foreground">{role.name}</h3>
                    {role.is_system ? (
                      <span className="inline-flex items-center rounded-md bg-secondary px-2 py-0.5 text-[11px] font-medium text-secondary-foreground">
                        System
                      </span>
                    ) : (
                      <span className="text-[11px] text-muted-foreground">
                        {role.member_count} member{role.member_count === 1 ? "" : "s"}
                      </span>
                    )}
                  </div>
                  {role.description && (
                    <p className="text-sm text-muted-foreground mt-0.5">
                      {role.description}
                    </p>
                  )}
                  <p className="text-[11px] text-muted-foreground/70 mt-1">
                    {role.permissions.length} permission
                    {role.permissions.length === 1 ? "" : "s"}
                  </p>
                </div>

                <div className="flex items-center gap-1 shrink-0">
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => handleEdit(role)}
                    className="text-muted-foreground"
                  >
                    <span className="material-symbols-outlined text-base mr-1">
                      {role.is_system ? "visibility" : "edit"}
                    </span>
                    {role.is_system ? "View" : "Edit"}
                  </Button>
                  {!role.is_system && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => setDeleteTarget(role)}
                      className="text-destructive hover:text-destructive"
                    >
                      <span className="material-symbols-outlined text-base mr-1">
                        delete
                      </span>
                      Delete
                    </Button>
                  )}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}

      <RoleDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        role={editRole}
        onSaved={loadRoles}
      />

      <Dialog
        open={!!deleteTarget}
        onOpenChange={(o) => !o && setDeleteTarget(null)}
      >
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>Delete role</DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground py-1">
            Delete <span className="font-medium text-foreground">{deleteTarget?.name}</span>?
            Employees with this role will revert to their base role.
          </p>
          <div className="flex justify-end gap-2 mt-2">
            <Button variant="outline" onClick={() => setDeleteTarget(null)}>
              Cancel
            </Button>
            <Button
              onClick={confirmDelete}
              disabled={deleting}
              className="bg-destructive text-white hover:bg-destructive/90"
            >
              {deleting ? "Deleting…" : "Delete"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
