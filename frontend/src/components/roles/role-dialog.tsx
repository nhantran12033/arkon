"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

export type PermissionItem = {
  code: string;
  label: string;
  description?: string | null;
};

export type PermissionGroup = {
  key: string;
  permissions: PermissionItem[];
};

export type Role = {
  id: string;
  name: string;
  description?: string | null;
  permissions: string[];
  is_system: boolean;
  member_count: number;
};

type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  role: Role | null; // null = create mode
  onSaved: () => void;
};

/** A checkbox that can render the indeterminate (partial) state. */
function TriCheckbox({
  checked,
  indeterminate = false,
  onChange,
  id,
}: {
  checked: boolean;
  indeterminate?: boolean;
  onChange: (checked: boolean) => void;
  id?: string;
}) {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (ref.current) ref.current.indeterminate = indeterminate && !checked;
  }, [indeterminate, checked]);

  return (
    <div className="relative flex items-center justify-center">
      <input
        id={id}
        ref={ref}
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="peer h-4 w-4 shrink-0 rounded-sm border border-primary appearance-none cursor-pointer checked:bg-primary indeterminate:bg-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
      />
      <span className="material-symbols-outlined pointer-events-none absolute text-[13px] leading-none text-primary-foreground opacity-0 peer-checked:opacity-100">
        check
      </span>
      <span className="material-symbols-outlined pointer-events-none absolute text-[13px] leading-none text-primary-foreground opacity-0 peer-indeterminate:opacity-100">
        remove
      </span>
    </div>
  );
}

export function RoleDialog({ open, onOpenChange, role, onSaved }: Props) {
  const isEdit = !!role;
  const readOnly = !!role?.is_system;

  const [catalog, setCatalog] = useState<PermissionGroup[]>([]);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  // Load the permission catalog once (first time the dialog opens).
  useEffect(() => {
    if (!open || catalog.length > 0) return;
    api<PermissionGroup[]>("/api/roles/permission-catalog")
      .then(setCatalog)
      .catch(() => setCatalog([]));
  }, [open, catalog.length]);

  // Reset form each time the dialog opens / target role changes.
  useEffect(() => {
    if (!open) return;
    setName(role?.name ?? "");
    setDescription(role?.description ?? "");
    setSelected(new Set(role?.permissions ?? []));
    setError("");
  }, [open, role]);

  const allCodes = useMemo(
    () => catalog.flatMap((g) => g.permissions.map((p) => p.code)),
    [catalog]
  );
  const totalCount = allCodes.length;

  const toggle = useCallback(
    (code: string, on: boolean) => {
      if (readOnly) return;
      setSelected((prev) => {
        const next = new Set(prev);
        if (on) next.add(code);
        else next.delete(code);
        return next;
      });
    },
    [readOnly]
  );

  const toggleGroup = useCallback(
    (group: PermissionGroup, on: boolean) => {
      if (readOnly) return;
      setSelected((prev) => {
        const next = new Set(prev);
        for (const p of group.permissions) {
          if (on) next.add(p.code);
          else next.delete(p.code);
        }
        return next;
      });
    },
    [readOnly]
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (readOnly) {
      onOpenChange(false);
      return;
    }
    if (!name.trim()) {
      setError("Role name is required");
      return;
    }
    setSaving(true);
    setError("");
    try {
      const body = {
        name: name.trim(),
        description: description.trim() || null,
        permissions: allCodes.filter((c) => selected.has(c)),
      };
      if (isEdit) {
        await api(`/api/roles/${role!.id}`, { method: "PUT", body });
      } else {
        await api("/api/roles", { method: "POST", body });
      }
      onSaved();
      onOpenChange(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Save failed");
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle className="text-xl">
            {isEdit ? (readOnly ? "View Role" : "Edit Role") : "Create Role"}
          </DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="flex flex-col gap-5 mt-2">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="flex flex-col gap-2">
              <Label htmlFor="role-name">Name</Label>
              <Input
                id="role-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                disabled={readOnly}
                required
                autoFocus
                className="bg-background"
              />
            </div>
            <div className="flex flex-col gap-2">
              <Label htmlFor="role-desc">Description</Label>
              <Input
                id="role-desc"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                disabled={readOnly}
                placeholder="Optional"
                className="bg-background"
              />
            </div>
          </div>

          <div className="flex items-center justify-between">
            <Label className="text-sm font-medium">Permissions</Label>
            <span className="text-xs text-muted-foreground">
              {selected.size} of {totalCount} selected
            </span>
          </div>

          {readOnly && (
            <p className="text-xs text-muted-foreground -mt-3">
              This is a system role and cannot be edited.
            </p>
          )}

          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
            {catalog.map((group) => {
              const codes = group.permissions.map((p) => p.code);
              const selCount = codes.filter((c) => selected.has(c)).length;
              const allOn = selCount === codes.length && codes.length > 0;
              const someOn = selCount > 0 && !allOn;
              return (
                <div
                  key={group.key}
                  className="rounded-lg border border-black/[0.06] bg-background p-3"
                >
                  <label className="flex items-center gap-2 pb-2 mb-2 border-b border-black/[0.05] cursor-pointer">
                    <TriCheckbox
                      checked={allOn}
                      indeterminate={someOn}
                      onChange={(on) => toggleGroup(group, on)}
                    />
                    <span className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
                      {group.key}
                    </span>
                  </label>
                  <div className="flex flex-col gap-2.5">
                    {group.permissions.map((perm) => (
                      <label
                        key={perm.code}
                        className="flex items-start gap-2 cursor-pointer"
                        title={perm.description ?? undefined}
                      >
                        <span className="mt-0.5">
                          <TriCheckbox
                            checked={selected.has(perm.code)}
                            onChange={(on) => toggle(perm.code, on)}
                          />
                        </span>
                        <span className="flex flex-col leading-tight">
                          <span className="text-[13px] text-foreground">
                            {perm.label}
                          </span>
                          <span className="text-[11px] font-mono text-muted-foreground/70">
                            {perm.code}
                          </span>
                        </span>
                      </label>
                    ))}
                  </div>
                </div>
              );
            })}
          </div>

          {error && (
            <p className="text-destructive text-sm bg-destructive/10 px-3 py-2 rounded-lg">
              {error}
            </p>
          )}

          <div className="flex justify-end gap-2 mt-1">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              {readOnly ? "Close" : "Cancel"}
            </Button>
            {!readOnly && (
              <Button
                type="submit"
                disabled={saving}
                className="bg-primary text-primary-foreground hover:bg-primary/90"
              >
                {saving ? "Saving..." : isEdit ? "Update" : "Create"}
              </Button>
            )}
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}
