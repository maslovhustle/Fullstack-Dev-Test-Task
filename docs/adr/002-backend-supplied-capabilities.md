# ADR 002: The backend supplies capabilities; the role comes from the DB, not the JWT

- Status: accepted
- Date: 2026-11-03

## Context

The UI has to hide navigation and controls the user cannot use, and guard
routes on direct navigation, consistently with what the API enforces. We also
have to decide where the role lives at request time. The token is a
long-lived (8-day) bearer JWT with no revocation.

## Options

**Frontend capabilities**

1. Mirror the role→permission map in TypeScript and branch on `user.role`.
   This duplicates the policy in two languages, the copies drift, and the
   frontend has to be redeployed whenever the policy changes.
2. The backend returns the role and its effective permissions;
   the frontend only asks "does this user have permission X?".

**Role at request time**

1. Put the role (or permissions) in the JWT claims. This saves a lookup, but a
   demoted or deactivated user keeps their old powers until the token expires,
   which here is up to 8 days.
2. The token carries only `sub`. The user, and therefore the role, is loaded
   from the database on every request (the template already did this lookup).

## Decision

- `GET /users/me` returns `UserMePublic`: the user plus a computed
  `permissions: Permission[]` derived from `ROLE_PERMISSIONS`. The generated
  OpenAPI client types `Permission` as a union with runtime constants, so the
  frontend writes `hasPermission(user, Permission.USERS_LIST)`. It contains no
  role→permission map and never compares role names.
- Route guards (`beforeLoad`) read the cached current user from TanStack Query
  (`ensureQueryData`), so navigation does not refetch `/users/me`.
- The JWT stays `{sub, exp}`. `get_current_user` loads the user from the
  database each time and rejects missing or inactive users with 401, so a role
  change applies on the very next request (covered by a test).
- Status semantics follow from this: 401 means "your credentials are not
  valid", so the frontend logs out. 403 means "valid session, not allowed", so
  the frontend shows an "Access denied" page, keeps the session, and refreshes
  `/users/me` in case the role changed.

## Consequences

- One source of truth. A permission change is a backend deploy, and the UI
  follows on the next `/users/me`.
- The frontend can show stale capabilities between a role change and its next
  `/users/me` fetch. This is harmless: the API still enforces the policy, and
  a 403 triggers a refetch.
- One primary-key lookup per request, which the template already paid for.
- Hiding UI is a convenience, not a security boundary. Every rule is enforced
  server-side.
