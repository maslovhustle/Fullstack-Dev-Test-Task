# Notes

What I want a reviewer to know beyond the README and the ADRs.

## Decisions worth flagging

- **Permissions, not roles, in code.** Routes and UI ask for a `Permission`;
  only `app/core/permissions.py` maps roles to them. The only places that name
  a role are that map, the seed, and the Alembic migration.
- **Own-profile endpoints are gated too** (`profile:*`). Every authenticated
  endpoint goes through the same dependency, which keeps the route-audit test
  trivial and lets a future restricted role (for example "suspended") be a
  one-line change.
- **Admins hold every permission except `profile:delete`.** Together with the
  self-lockout guard (nobody can change their own role, deactivate or delete
  themselves through `/users/{id}`), this means the last user who can manage
  users can never be removed by accident.
- **`GET /users/{id}` requires `users:list`, even for your own id.** Your own
  profile is `/users/me`. The template let anyone read themselves by id; I
  dropped that special case to keep one check per route.
- **Role stored as VARCHAR(32)**, validated by the `UserRole` enum rather than a
  Postgres enum or CHECK constraint, so adding a role needs no migration. The
  trade-off is that raw SQL could write an unknown role. The application would
  reject it on read, and it is acceptable here.
- **The migration downgrade is lossy by design**: managers become regular
  users, because the old schema has no equivalent.
- **Env var names `FIRST_SUPERUSER*` were kept** (they now seed an admin) to
  avoid churn in CI, Playwright and deployment docs.
- **403 before 422.** A caller without permission gets 403 even for an invalid
  body, so unauthorized users do not learn request schemas.
- **Non-owners get 403 (not 404) for other people's items**, matching the
  template. IDs are random UUIDs, so this does not enable enumeration.
- **Queries no longer retry 4xx responses** (the TanStack default is 3 retries
  with backoff). Without this, a 403 left the page in a loading state for
  about 7 s before showing Access denied. A Playwright test that demotes a
  manager mid-session found this.
- **A 403 refetches `/users/me`**, so the sidebar follows a role change without
  a reload, except when `/users/me` itself is the failing query (that would
  loop).
- **Frontend unit tests use `bun test`.** Bun is already the toolchain, so the
  only addition is `@types/bun`, which is kept out of the app build's
  tsconfig.

## Scope cuts

- No permission management UI or custom roles at runtime. Roles are code, on
  purpose (see ADR 001).
- The metrics page is a stub: aggregate counts only, no time series.
- The "System settings" page has a single action (send a test email). It
  exists so "global settings" is a real, admin-only surface.
- No audit trail of *successful* privileged actions. Only denials are logged.

## Known limitations (inherited or out of scope)

- The access token lives in `localStorage` (XSS-readable). An httpOnly,
  SameSite cookie with CSRF protection would be safer.
- No refresh tokens and no revocation. Tokens live 8 days. Role changes and
  deactivation still apply immediately because the user is reloaded on every
  request, but a stolen token stays valid until it expires.
- No rate limiting or lockout on `/login/access-token` or password recovery.
- `POST /users/` emails the new user their password in plain text (template
  behaviour) when SMTP is configured.
- Locally, the dev `SECRET_KEY` (`changethis`) is shorter than PyJWT
  recommends, so tests print `InsecureKeyLengthWarning`. Real deployments must
  set a long random key; the settings already refuse `changethis` outside
  development.
- The backend test suite deletes all users and items when it finishes (template
  `conftest.py`). Point it at a separate database (see README) or re-run the
  seed afterwards.
- The remaining `bun audit` advisories are in dev-only build tooling
  (openapi-ts YAML parser, react-email). The CI security job fails only on
  high or critical advisories in production dependencies.
- **Diff size: about 56 hand-written files** (excluding the generated client,
  lockfiles and `routeTree.gen.ts`), more than the "well under 50" target.
  The extra comes from scope added on purpose: in-range dependency upgrades,
  two CI workflows (security, frontend), frontend unit tests and a Playwright
  RBAC suite. The RBAC core itself is about 30 files.

## With more time

- Move the token to an httpOnly cookie, add refresh and revocation (a token
  version on the user), and rate-limit authentication endpoints.
- Structured JSON logging (the denial log already carries `extra` fields) and
  an audit log for privileged actions.
- Per-resource policies (for example "managers can edit members, not admins")
  behind the same `has_permission` seam.
- Run the backend tests against a dedicated database by default.
