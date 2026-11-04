# ADR 001: Permission map + FastAPI dependency factory

- Status: accepted
- Date: 2026-11-03

## Context

The template had one boolean, `is_superuser`, checked inline in routes and in one dependency. We
need three roles and a protected surface that will grow. The model must be readable in five
minutes, enforced the same way everywhere, and cheap to extend.

## Options

1. **Inline role checks** in each route. Easy to start, but the policy spreads across handlers, a
   new role means editing many files, and a forgotten check is invisible in review.
2. **Middleware** keyed on URL patterns. Keeps routes clean, but ties the policy to path strings
   and runs before FastAPI resolves the route and the user.
3. **Policy engine** (Casbin, OPA, Oso). Powerful for attribute-based or multi-tenant rules, but
   adds a dependency, another policy format and operational surface that three static roles do
   not justify.
4. **Permission map + dependency factory.** Routes declare what they need, one module maps roles
   to permissions, and one dependency enforces it.

## Decision

Option 4.

- `app/core/permissions.py` holds `UserRole`, a namespaced `Permission` enum (`users:list`,
  `metrics:view`, …) and `ROLE_PERMISSIONS`. It is the only place that knows which role can do
  what.
- `require_permission(Permission.X)` in `app/api/deps.py` returns a small callable, attached as a
  route or router dependency. It authenticates, checks, logs denials and raises 403.
- Rules that depend on data rather than role (item ownership, self-lockout) are small named
  helpers. They still ask the policy instead of comparing role names.
- A test walks the effective routes and fails if a non-public endpoint has no permission check, so
  a forgotten check fails CI instead of relying on review.

## Consequences

- Adding a role is one enum member and one dict entry, with no migration, because the column is a
  VARCHAR validated by the enum.
- The matrix is explicit, and a parametrized test mirrors the README table.
- It is role-based only. If per-tenant or attribute rules appear, `has_permission(role,
  permission)` is where a policy engine would plug in without touching routes.
