"""Critical authorization paths.

PERMISSION_MATRIX is the executable form of the matrix in README.md: it is
written out by hand (not derived from ROLE_PERMISSIONS) so that a change to
the policy that is not reflected in the docs fails here.
"""

import logging
import threading
import uuid
from collections.abc import Generator
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from unittest.mock import patch

import jwt
import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, col, select

from app.core.config import settings
from app.core.permissions import UserRole
from app.core.security import ALGORITHM, create_access_token
from app.models import User
from app.utils import generate_password_reset_token
from tests.utils.item import create_random_item
from tests.utils.user import create_user_with_role, login_as_new_user
from tests.utils.utils import random_email

API = settings.API_V1_STR
ADMIN, MANAGER, MEMBER = UserRole.ADMIN, UserRole.MANAGER, UserRole.MEMBER
EVERYONE = {ADMIN, MANAGER, MEMBER}
MISSING = uuid.UUID(int=0)  # allowed callers get 404 instead of mutating real data

# (method, path, json body, roles that are allowed)
PERMISSION_MATRIX: list[tuple[str, str, dict[str, object] | None, set[UserRole]]] = [
    ("GET", "/users/me", None, EVERYONE),
    ("PATCH", "/users/me", {"full_name": "New Name"}, EVERYONE),
    (
        "PATCH",
        "/users/me/password",
        {"current_password": "wrong-pass", "new_password": "another-pass"},
        EVERYONE,
    ),
    ("DELETE", "/users/me", None, {MANAGER, MEMBER}),
    ("POST", "/login/test-token", None, EVERYONE),
    ("GET", "/items/", None, EVERYONE),
    ("POST", "/items/", {"title": "Item"}, EVERYONE),
    ("GET", "/users/", None, {ADMIN, MANAGER}),
    ("GET", f"/users/{MISSING}", None, {ADMIN, MANAGER}),
    ("POST", "/users/", {"email": "<random>", "password": "password123"}, {ADMIN}),
    ("PATCH", f"/users/{MISSING}", {"full_name": "Renamed"}, {ADMIN}),
    ("DELETE", f"/users/{MISSING}", None, {ADMIN}),
    ("GET", "/metrics/", None, {ADMIN, MANAGER}),
    ("POST", "/utils/test-email/?email_to=test@example.com", None, {ADMIN}),
    ("POST", "/password-recovery-html-content/nobody@example.com", None, {ADMIN}),
]


@pytest.fixture(autouse=True)
def no_outgoing_email() -> Generator[None]:
    with (
        patch("app.api.routes.users.send_email"),
        patch("app.api.routes.utils.send_email"),
    ):
        yield


@pytest.mark.parametrize("role", list(UserRole))
@pytest.mark.parametrize(
    ("method", "path", "body", "allowed_roles"),
    PERMISSION_MATRIX,
    ids=[f"{method} {path}" for method, path, _, _ in PERMISSION_MATRIX],
)
def test_permission_matrix(
    client: TestClient,
    db: Session,
    role: UserRole,
    method: str,
    path: str,
    body: dict[str, object] | None,
    allowed_roles: set[UserRole],
) -> None:
    _, headers = login_as_new_user(client, db, role)
    if body and body.get("email") == "<random>":
        body = {**body, "email": random_email()}

    r = client.request(method, f"{API}{path}", headers=headers, json=body)

    if role in allowed_roles:
        assert r.status_code not in (401, 403), r.json()
    else:
        assert r.status_code == 403
        assert r.json()["detail"].startswith("Missing permission:")


def test_manager_cannot_create_users_but_admin_can(
    client: TestClient, db: Session
) -> None:
    body = {"email": random_email(), "password": "password123", "role": "member"}
    _, manager = login_as_new_user(client, db, MANAGER)
    _, admin = login_as_new_user(client, db, ADMIN)

    assert client.post(f"{API}/users/", headers=manager, json=body).status_code == 403
    r = client.post(f"{API}/users/", headers=admin, json=body)
    assert r.status_code == 200
    assert r.json()["role"] == "member"


def test_member_cannot_list_users_or_view_metrics(
    client: TestClient, member_token_headers: dict[str, str]
) -> None:
    for path in ("/users/", "/metrics/"):
        assert (
            client.get(f"{API}{path}", headers=member_token_headers).status_code == 403
        )


def test_member_updates_own_profile_but_not_someone_elses(
    client: TestClient, db: Session
) -> None:
    member, headers = login_as_new_user(client, db, MEMBER)
    other, _ = create_user_with_role(db, MEMBER)

    r = client.patch(f"{API}/users/me", headers=headers, json={"full_name": "Me"})
    assert r.status_code == 200
    assert r.json()["full_name"] == "Me"

    r = client.patch(
        f"{API}/users/{other.id}", headers=headers, json={"full_name": "Hacked"}
    )
    assert r.status_code == 403
    db.refresh(other)
    assert other.full_name != "Hacked"


def test_member_cannot_touch_someone_elses_item_but_admin_can(
    client: TestClient, db: Session
) -> None:
    item = create_random_item(db)
    _, member = login_as_new_user(client, db, MEMBER)
    _, admin = login_as_new_user(client, db, ADMIN)

    assert client.get(f"{API}/items/{item.id}", headers=member).status_code == 403
    assert client.get(f"{API}/items/{item.id}", headers=admin).status_code == 200


@pytest.mark.parametrize(
    ("path", "body"),
    [
        ("/users/me", {"role": "admin"}),
        (
            "/users/signup",
            {"email": "<random>", "password": "password123", "role": "admin"},
        ),
    ],
)
def test_role_cannot_be_self_assigned(
    client: TestClient, db: Session, path: str, body: dict[str, str]
) -> None:
    member, headers = login_as_new_user(client, db, MEMBER)
    if body.get("email") == "<random>":
        body = {**body, "email": random_email()}
    method = "PATCH" if path == "/users/me" else "POST"

    r = client.request(method, f"{API}{path}", headers=headers, json=body)

    assert r.status_code == 422
    assert r.json()["detail"][0]["type"] == "extra_forbidden"
    db.refresh(member)
    assert member.role == MEMBER


@pytest.mark.parametrize(
    ("method", "body", "detail"),
    [
        ("PATCH", {"role": "member"}, "You cannot change your own role"),
        ("PATCH", {"is_active": False}, "You cannot deactivate yourself"),
        ("DELETE", None, "You cannot delete yourself"),
    ],
)
def test_admin_cannot_lock_themselves_out(
    client: TestClient,
    db: Session,
    method: str,
    body: dict[str, object] | None,
    detail: str,
) -> None:
    admin, headers = login_as_new_user(client, db, ADMIN)

    r = client.request(method, f"{API}/users/{admin.id}", headers=headers, json=body)

    assert r.status_code == 403
    assert r.json()["detail"] == detail
    db.refresh(admin)
    assert admin.role == ADMIN and admin.is_active


def test_concurrent_demotions_keep_one_user_manager(
    client: TestClient, db: Session
) -> None:
    """Two admins demoting each other at once must not leave zero admins."""
    admin_a, headers_a = login_as_new_user(client, db, ADMIN)
    admin_b, headers_b = login_as_new_user(client, db, ADMIN)
    id_a, id_b = admin_a.id, admin_b.id
    others = db.exec(
        select(User).where(
            User.role == ADMIN,
            col(User.is_active),
            col(User.id).not_in([id_a, id_b]),
        )
    ).all()
    for user in others:
        user.is_active = False
    db.add_all(others)
    db.commit()
    barrier = threading.Barrier(2)

    def demote(headers: dict[str, str], target_id: uuid.UUID) -> int:
        barrier.wait()
        url = f"{API}/users/{target_id}"
        return client.patch(url, headers=headers, json={"role": "member"}).status_code

    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            statuses = sorted(pool.map(demote, [headers_a, headers_b], [id_b, id_a]))
    finally:
        for user in others:
            user.is_active = True
        db.add_all(others)
        db.commit()

    assert statuses[0] == 200 and statuses[1] in (403, 409)
    db.refresh(admin_a)
    db.refresh(admin_b)
    assert [admin_a.role, admin_b.role].count(ADMIN) == 1


@pytest.mark.parametrize(
    ("path", "body"),
    [("/users/me", {"email": None}), ("/users/{id}", {"role": None})],
)
def test_explicit_null_is_rejected_not_a_server_error(
    client: TestClient, db: Session, path: str, body: dict[str, None]
) -> None:
    admin, headers = login_as_new_user(client, db, ADMIN)
    target, _ = create_user_with_role(db, MEMBER)

    r = client.patch(f"{API}{path.format(id=target.id)}", headers=headers, json=body)

    assert r.status_code == 422


def test_admin_can_change_another_users_role(client: TestClient, db: Session) -> None:
    _, admin = login_as_new_user(client, db, ADMIN)
    target, _ = create_user_with_role(db, MEMBER)

    r = client.patch(
        f"{API}/users/{target.id}", headers=admin, json={"role": "manager"}
    )

    assert r.status_code == 200
    db.refresh(target)
    assert target.role == MANAGER


def test_role_change_applies_on_next_request_with_same_token(
    client: TestClient, db: Session
) -> None:
    manager, headers = login_as_new_user(client, db, MANAGER)
    assert client.get(f"{API}/users/", headers=headers).status_code == 200

    manager.role = MEMBER
    db.add(manager)
    db.commit()

    assert client.get(f"{API}/users/", headers=headers).status_code == 403
    me = client.get(f"{API}/users/me", headers=headers).json()
    assert me["role"] == "member"
    assert "users:list" not in me["permissions"]


def _token_for(user: User, *, expires_in: timedelta = timedelta(minutes=5)) -> str:
    return create_access_token(user.id, expires_delta=expires_in)


@pytest.mark.parametrize(
    "case",
    [
        "garbage",
        "wrong_signature",
        "expired",
        "no_expiry",
        "password_reset_token",
        "deleted_user",
        "inactive_user",
    ],
)
def test_invalid_credentials_are_401(
    client: TestClient, db: Session, case: str
) -> None:
    user, _ = create_user_with_role(db, ADMIN, is_active=case != "inactive_user")
    token = {
        "garbage": "not-a-jwt",
        "wrong_signature": jwt.encode({"sub": str(user.id)}, "other-key", ALGORITHM),
        "expired": _token_for(user, expires_in=timedelta(minutes=-1)),
        "no_expiry": jwt.encode({"sub": str(user.id)}, settings.SECRET_KEY, ALGORITHM),
        "password_reset_token": generate_password_reset_token(user.email),
    }.get(case) or _token_for(user)
    if case == "deleted_user":
        db.delete(user)
        db.commit()

    r = client.get(f"{API}/users/", headers={"Authorization": f"Bearer {token}"})

    assert r.status_code == 401
    assert r.headers["WWW-Authenticate"] == "Bearer"


def test_missing_permission_is_403_not_401(
    client: TestClient, member_token_headers: dict[str, str]
) -> None:
    r = client.get(f"{API}/users/", headers=member_token_headers)

    assert r.status_code == 403
    assert "WWW-Authenticate" not in r.headers
    assert r.json() == {"detail": "Missing permission: users:list"}


def test_denied_attempt_is_logged(
    client: TestClient, db: Session, caplog: pytest.LogCaptureFixture
) -> None:
    member, headers = login_as_new_user(client, db, MEMBER)

    with caplog.at_level(logging.WARNING, logger="app.api.deps"):
        client.post(
            f"{API}/password-recovery-html-content/{member.email}", headers=headers
        )

    [record] = [r for r in caplog.records if r.name == "app.api.deps"]
    assert record.levelno == logging.WARNING
    assert record.__dict__["user_id"] == str(member.id)
    assert record.__dict__["role"] == "member"
    assert record.__dict__["permission"] == "settings:manage"
    # The route template is logged, so the email in the URL never reaches the log
    assert record.__dict__["path"] == f"{API}/password-recovery-html-content/{{email}}"
    assert member.email not in record.getMessage()


def test_metrics_counts_users_by_role(client: TestClient, db: Session) -> None:
    _, headers = login_as_new_user(client, db, MANAGER)

    metrics = client.get(f"{API}/metrics/", headers=headers).json()

    assert set(metrics["users_by_role"]) == {"admin", "manager", "member"}
    assert sum(metrics["users_by_role"].values()) == metrics["total_users"]
    assert metrics["users_by_role"]["manager"] >= 1
