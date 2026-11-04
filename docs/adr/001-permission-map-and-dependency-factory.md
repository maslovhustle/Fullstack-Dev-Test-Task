# ADR 001: Permission map + FastAPI dependency factory

- Status: accepted
- Date: 2026-11-03

## Context

The template had one boolean, `is_superuser`, checked inline in route bodies
and in a `get_current_active_superuser` dependency. We need three roles
(admin, manager, member) and a protected surface that will keep growing.
The authorization model must be readable in five minutes, enforced the same
way everywhere, and cheap to extend: adding a role should not mean touching
ten files.

## Options

1. **Inline role checks** (`if user.role not in {"admin", "manager"}`) in each
   route. Easy to start, but the policy ends up spread across handlers, every
   new role means a grep-and-edit across the codebase, and a forgotten check
   is invisible in review.
2. **Middleware** keyed on URL patterns. Keeps routes clean, but couples the
   policy to path strings, runs before FastAPI resolves the route, and cannot
   see path parameters or the loaded user without duplicating work.
3. **Policy engine** (Casbin, OPA/Rego, Oso). Powerful for attribute-based or
   multi-tenant rules, but adds a dependency, a second language or config
   format, and an operational surface that three static roles do not justify.
4. **Permission map + dependency factory.** Routes declare *what* they need
   (`Permission.USERS_LIST`). One module maps roles to permissions. One
   dependency enforces it.

## Decision

Option 4.

- `app/core/permissions.py` holds `UserRole`, a namespaced `Permission`
  StrEnum (`users:list`, `metrics:view`, …) and
  `ROLE_PERMISSIONS: dict[UserRole, frozenset[Permission]]`. This is the only
  place that knows which role can do what.
- `require_permission(Permission.X)` in `app/api/deps.py` returns a small
  callable `PermissionChecker`, attached as
  `dependencies=[Depends(require_permission(...))]` on the route (or on the
  router for items). It authenticates, checks, logs denials at WARNING and
  raises 403.
- Rules that depend on data rather than role (item ownership, "you cannot
  demote yourself") are small named helpers (`get_accessible_item`,
  `ensure_not_self_lockout`). Even they ask the policy (`ITEMS_MANAGE_ALL`)
  instead of comparing role names.
- A test walks the effective FastAPI routes and fails if a non-public endpoint
  has no `PermissionChecker`, so "forgot the check" is a CI failure, not a
  review comment.

## Consequences

- Adding a role = one enum member + one dict entry (no migration: the column
  is a VARCHAR validated by the enum). Adding a permission = one enum member,
  the roles that get it, and the routes that require it.
- The matrix is explicit and testable; the README matrix is mirrored by a
  parametrized test.
- Role-based only: no per-tenant or attribute rules. If those appear, the
  `has_permission(role, permission)` seam is where a policy engine would plug
  in without touching routes.
