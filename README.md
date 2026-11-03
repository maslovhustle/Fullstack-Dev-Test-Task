# Full Stack FastAPI Template — with role-based access control

[![Test Docker Compose](../../actions/workflows/test-docker-compose.yml/badge.svg)](../../actions/workflows/test-docker-compose.yml)
[![Test Backend](../../actions/workflows/test-backend.yml/badge.svg)](../../actions/workflows/test-backend.yml)
[![Security](../../actions/workflows/security.yml/badge.svg)](../../actions/workflows/security.yml)

This fork adds role-based access control (RBAC) to the template. There are three roles, **admin**,
**manager** and **member**, enforced the same way in the API and in the UI.
Design records: [ADR 001](docs/adr/001-permission-map-and-dependency-factory.md),
[ADR 002](docs/adr/002-backend-supplied-capabilities.md). Trade-offs and scope cuts: [NOTES.md](NOTES.md).

## Quick start (Docker Compose)

Requirements: Docker with Compose v2.

```bash
docker compose up -d --build
```

The backend container applies migrations and seeds the users before it starts, so after about a
minute everything is ready. Follow the startup with `docker compose logs -f backend`.

| URL | What |
|---|---|
| <http://localhost:8000> | App (React UI served by FastAPI) |
| <http://localhost:8000/docs> | Swagger UI |
| <http://localhost:8080> | Adminer (database) |
| <http://localhost:8025> | Mailpit (captured emails) |

For live reload while editing, use `docker compose watch` instead of `up`.

### Seeded users

The seed (`backend/app/initial_data.py`, run by `backend/scripts/prestart.sh`) is idempotent: it
creates missing users and never modifies existing ones. Credentials come from the repo-root `.env`.
The values there are **local development defaults only**.

| Role | Email (env var) | Password (env var) |
|---|---|---|
| admin | `FIRST_SUPERUSER` (`admin@example.com`) | `FIRST_SUPERUSER_PASSWORD` |
| manager | `SEED_MANAGER_EMAIL` (`manager@example.com`) | `SEED_MANAGER_PASSWORD` |
| member | `SEED_MEMBER_EMAIL` (`member@example.com`) | `SEED_MEMBER_PASSWORD` |

The admin is always seeded. The manager and member demo accounts are created only when
`SEED_DEMO_USERS=true`. `compose.override.yml` (local Docker) sets it, and it is deliberately
absent from the committed `.env`, which deploy pipelines also read, so deployments never get demo
users. When demo seeding is on, the default `changethis` passwords are refused outside development.
To re-run the seed by hand: `docker compose exec backend bash scripts/prestart.sh`.

## Local development (uv + bun)

Requirements: [uv](https://docs.astral.sh/uv/) (Python ≥ 3.14 is installed by uv), [bun](https://bun.sh), Docker.

```bash
docker compose up -d db mailpit                                   # Postgres 18 + Mailpit
cd backend && uv sync && SEED_DEMO_USERS=true uv run bash scripts/prestart.sh  # migrate + seed
uv run fastapi dev                                                # API on :8000
```

In a second terminal, from the repo root, run `bun install && bun run dev`. The Vite dev server
starts at <http://localhost:5173> and talks to the API on :8000. Stop the Compose `backend`
service first (`docker compose stop backend`) because it also uses port 8000.

## Database migrations

Migrations are managed by Alembic (run inside `backend/`, or prefix with
`docker compose exec backend`):

```bash
uv run alembic upgrade head                                   # apply
uv run alembic downgrade -1                                   # roll back one revision
uv run alembic revision --autogenerate -m "describe change"   # after editing app/models.py
```

The RBAC migration (`b7c4e9a1d2f3`) adds `user.role`, backfills it
(`is_superuser = true` → `admin`, everyone else → `member`) and drops `is_superuser`. The
downgrade reverses it (managers become regular users). Both directions were tested on Postgres
with data.

## Tests and checks

| Layer | What it covers | Command |
|---|---|---|
| Backend unit | Policy invariants, `/users/me` permissions, schema `role` rejection, self-lockout rule (`tests/core/`) | `cd backend && uv run bash scripts/tests-start.sh` |
| Backend integration | Every endpoint against Postgres, including the role × endpoint matrix and the route audit (`tests/api/`) | same command (pytest + coverage) |
| Backend lint | mypy (strict), ty, ruff check, ruff format, on `app/` and `tests/` | `cd backend && uv run bash scripts/lint.sh` |
| Frontend unit | `hasPermission`, `requirePermission`, the 401/403 error policy, no-retry on 4xx (`src/**/*.test.ts`, `bun test`) | `cd frontend && bun run test:unit` |
| Frontend lint / types | biome; `tsc` for app, unit and e2e code | `cd frontend && bun run lint && bun run typecheck` |
| End-to-end | Playwright: login, items, settings, admin, plus RBAC flows per role (`tests/rbac.spec.ts`) | `cd frontend && bunx playwright test` |
| Security (CI) | pip-audit, `bun audit` (production deps, high and above), gitleaks, CodeQL | `.github/workflows/security.yml` |
| AI PR review (CI) | Claude reviews each pull request for authorization gaps, security issues and bugs, with inline comments | `.github/workflows/claude-pr-review.yml` (needs the `ANTHROPIC_API_KEY` repository secret; skipped without it) |

Backend tests need the `db` service. The template's test teardown **deletes every user and item**
in the target database, which includes the seeded accounts. Either re-run the seed afterwards, or
point the tests at a throwaway database:

```bash
docker compose exec db createdb -U postgres app_test
export DATABASE_URL=postgresql://postgres:changethis@localhost:5432/app_test
uv run alembic upgrade head && uv run bash scripts/tests-start.sh
```

Playwright needs the backend on :8000 with seeded users. Run `bunx playwright install chromium`
once first. For a stable run, test the built app served by the backend (this is what CI does):
`PLAYWRIGHT_BASE_URL=http://localhost:8000 bunx playwright test`, or inside Docker
`docker compose run --rm playwright bunx playwright test`. Without `PLAYWRIGHT_BASE_URL` the
config starts the Vite dev server on :5173. Its unbundled modules can occasionally exceed the 5 s
assertion timeout when six workers run in parallel.

`PERMISSION_MATRIX` in `backend/tests/api/test_authorization.py` is the executable form of the table
below, written out by hand. `test_route_audit.py` fails if any non-public endpoint has no
permission check.

## Permission matrix

| Permission | Endpoints | UI | admin | manager | member |
|---|---|---|:-:|:-:|:-:|
| `profile:read` | `GET /users/me`, `POST /login/test-token` | everywhere | ✓ | ✓ | ✓ |
| `profile:update` | `PATCH /users/me`, `PATCH /users/me/password` | Settings → My profile, Password | ✓ | ✓ | ✓ |
| `profile:delete` | `DELETE /users/me` | Settings → Danger zone | ✗¹ | ✓ | ✓ |
| `items:use` | `/items/*` on your own items | Items | ✓ | ✓ | ✓ |
| `items:manage_all` | `/items/*` on anyone's items | Items (sees all) | ✓ | ✗ | ✗ |
| `users:list` | `GET /users/`, `GET /users/{id}` | Admin (read-only list) | ✓ | ✓ | ✗ |
| `users:create` | `POST /users/` (including `role`) | Admin → Add User | ✓ | ✗ | ✗ |
| `users:update` | `PATCH /users/{id}` (including `role`, `is_active`) | Admin → Edit user | ✓ | ✗ | ✗ |
| `users:delete` | `DELETE /users/{id}` | Admin → Delete user | ✓ | ✗ | ✗ |
| `metrics:view` | `GET /metrics/` | Metrics | ✓ | ✓ | ✗ |
| `settings:manage` | `POST /utils/test-email/`, `POST /password-recovery-html-content/{email}` | System | ✓ | ✗ | ✗ |

Public (no token): `POST /login/access-token`, `POST /password-recovery/{email}`,
`POST /reset-password/`, `POST /users/signup`, `GET /utils/health-check/`, and the dev-only
`POST /private/users/`.

¹ Admins cannot delete their own account, and nobody can change their own role, deactivate or
delete themselves through `/users/{id}` (403). The last user who manages users can therefore never
lock everyone out.

**Status codes:** `401` with `WWW-Authenticate: Bearer` is returned for a missing, malformed,
expired or forged token, a deleted user, or an inactive user. `403` with
`Missing permission: <permission>` is returned when you are authenticated but not allowed. `422`
is returned when `role` (or any unknown field) is sent to `/users/signup` or `PATCH /users/me`.

## How authorization works

**Where checks live.** `backend/app/core/permissions.py` is the single policy: a `UserRole` enum,
a namespaced `Permission` enum (`users:list`, `metrics:view`, …) and `ROLE_PERMISSIONS`, which
maps each role to a frozenset of permissions. Each route declares what it needs with a FastAPI
dependency, `dependencies=[Depends(require_permission(Permission.USERS_LIST))]` (see
`backend/app/api/deps.py`); the items router declares it once at router level. No route compares
role names. Data-scoped rules are small named helpers that still ask the policy:
`get_accessible_item` (owner, or `items:manage_all`) and `ensure_not_self_lockout`. Every denial is
logged at WARNING with `user_id`, `role`, `permission`, `method` and `path`, and no other personal
data.

**How roles are stored and validated.** `user.role` is a `VARCHAR(32)` column validated by the
`UserRole` enum (default `member`), so a new role needs no schema migration. The JWT carries only
`sub`; `get_current_user` reloads the user from the database on every request, so a demotion or
deactivation takes effect on the next request with the same token. `role` can only be written
through the admin endpoints (`users:create` and `users:update`). The self-service schemas
(`UserRegister`, `UserUpdateMe`) use `extra="forbid"`, so a smuggled `role` field is rejected.

**How the frontend learns capabilities.** `GET /users/me` returns the user's `role` and a computed
`permissions` list, both derived on the backend. The generated OpenAPI client exposes `Permission`
as typed runtime constants. The UI calls one helper, `hasPermission(user, Permission.X)`
(`frontend/src/lib/permissions.ts`). It uses it to filter the sidebar, to show or hide controls,
and in `beforeLoad` route guards that read the cached current user instead of refetching. The
frontend has no role→permission map. A 401 logs the user out. A 403 never does: it shows an
"Access denied" page inside the layout, with a way back, and refreshes `/users/me` in case the
role changed.

```mermaid
flowchart LR
    subgraph Browser
        G["Route guard (beforeLoad)<br/>hasPermission(cached /users/me)"]
        G -- missing --> AD["Access denied page<br/>(session kept)"]
        G -- ok --> P["Page → API call<br/>Authorization: Bearer JWT"]
    end
    P --> CU["get_current_user<br/>decode JWT (sub only) → load user from DB"]
    CU -- "bad / expired token,<br/>unknown or inactive user" --> E401["401 + WWW-Authenticate<br/>→ frontend logs out"]
    CU --> RP["require_permission(P)<br/>has_permission(user.role, P)<br/>via ROLE_PERMISSIONS"]
    RP -- no --> E403["403 Missing permission<br/>+ WARNING log<br/>→ Access denied, refetch /users/me"]
    RP -- yes --> H["Route handler<br/>(+ ownership / self-lockout helpers)"] --> OK["2xx"]
```

## Adding a new role

1. Add a member to `UserRole` in `backend/app/core/permissions.py`.
2. Add its entry to `ROLE_PERMISSIONS` in the same file.

That's all: no migration, no route changes, and no frontend changes (the UI reads permissions from
`/users/me`). Then add the role's column to `PERMISSION_MATRIX` in
`backend/tests/api/test_authorization.py` and to the table above, and regenerate the client
(`bash scripts/generate-client.sh`) so the role appears in the admin role picker.

---

## About the base template

## Technology Stack and Features

- ⚡ [**FastAPI**](https://fastapi.tiangolo.com) for the Python backend API.
  - 🧰 [SQLModel](https://sqlmodel.tiangolo.com) for the Python SQL database interactions (ORM).
  - 🔍 [Pydantic](https://docs.pydantic.dev), used by FastAPI, for the data validation and settings management.
  - 💾 [PostgreSQL](https://www.postgresql.org) as the SQL database.
- 🚀 [React](https://react.dev) for the frontend.
  - 🧩 Built into the backend application and served by FastAPI on the same domain as the API.
  - 💃 Using TypeScript, hooks, [Vite](https://vitejs.dev), and other parts of a modern frontend stack.
  - 🎨 [Tailwind CSS](https://tailwindcss.com) and [shadcn/ui](https://ui.shadcn.com) for the frontend components.
  - 🤖 An automatically generated frontend client.
  - 🧪 [Playwright](https://playwright.dev) for end-to-end testing.
  - 🦇 Dark mode support.
- ☁️ [FastAPI Cloud](https://fastapicloud.com) for deployment.
- 🐋 [Docker Compose](https://www.docker.com) for local services and self-hosted deployment.
  - 📞 [Traefik](https://traefik.io) as a reverse proxy with automatic HTTPS.
- 🔒 Secure password hashing by default.
- 🔑 JWT (JSON Web Token) authentication.
- 📫 Email-based password recovery.
- ✉️ [React Email](https://react.email) for email templates.
- 📬 [Mailpit](https://mailpit.axllent.org) for local email testing during development.
- ✅ Tests with [Pytest](https://pytest.org).
- 🏭 CI (continuous integration) and CD (continuous deployment) based on GitHub Actions.

### Dashboard Login

![Dashboard login screenshot](img/login.png)

### Dashboard - Admin

![Admin dashboard screenshot](img/dashboard.png)

### Dashboard - Items

![Items dashboard screenshot](img/dashboard-items.png)

### Dashboard - Dark Mode

![Dark mode dashboard screenshot](img/dashboard-dark.png)

### React Email Templates

![Email templates screenshot](img/react-email.png)

### Mailpit - Local Email Testing

![Mailpit screenshot](img/mailpit.png)

### Interactive API Documentation

![API docs](img/docs.png)

## How to Use It

Click the **Use this template** button at the top of this page to create a new repository.

## Backend Development

Backend docs: [backend/README.md](./backend/README.md).

## Frontend Development

Frontend docs: [frontend/README.md](./frontend/README.md).

## Deployment

FastAPI Cloud deployment: [deployment.md](./deployment.md).

Self-hosted deployment with Docker Compose: [deployment-docker-compose.md](./deployment-docker-compose.md).

## Development

General development docs: [development.md](./development.md).

This includes the local FastAPI and Vite workflow, Docker Compose services, `.env` configuration, and more.

## Release Notes

Check the file [release-notes.md](./release-notes.md).

## License

The Full Stack FastAPI Template is licensed under the terms of the MIT license.
