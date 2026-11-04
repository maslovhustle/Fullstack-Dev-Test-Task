# ADR 002: The backend supplies capabilities; the role comes from the DB, not the JWT

- Status: accepted
- Date: 2026-11-03

## Context

The UI must hide what a user cannot use and guard routes, consistently with what the API enforces.
We also have to decide where the role lives at request time. The token is an 8-day bearer JWT with
no revocation.

## Options

**Frontend capabilities**

1. Mirror the role-to-permission map in TypeScript. This duplicates the policy in two languages,
   and the copies drift.
2. The backend returns effective permissions, and the frontend only asks whether the user has
   permission X.

**Role at request time**

1. Put the role in the JWT claims. This saves a lookup, but a demoted user keeps their old powers
   until the token expires, up to 8 days later.
2. The token carries only `sub`, and the role is loaded from the database on every request. The
   template already did this lookup.

## Decision

- `GET /users/me` returns the user plus computed `permissions`. The generated client exposes
  `Permission` as typed constants, so the frontend writes `hasPermission(user,
  Permission.USERS_LIST)`. It has no role-to-permission map and never compares role names.
- Route guards read the cached current user, so navigation does not refetch `/users/me`.
- `get_current_user` loads the user on every request and rejects missing or inactive users with
  401, so a role change applies on the next request. A test covers this.
- 401 means the credentials are not valid, so the frontend logs out. 403 means a valid session that
  is not allowed, so the frontend shows Access denied, keeps the session and refreshes `/users/me`.

## Consequences

- There is one source of truth: a permission change is a backend deploy, and the UI follows on the
  next `/users/me`.
- The UI can show stale capabilities until that fetch. This is harmless, because the API still
  enforces the policy and a 403 triggers a refetch.
- Each request costs one primary-key lookup, which the template already paid for.
- Hiding UI is a convenience, not a security boundary.
