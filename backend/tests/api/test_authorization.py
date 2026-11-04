"""Critical authorization paths.

PERMISSION_MATRIX is the executable form of the matrix in README.md: it is
written out by hand (not derived from ROLE_PERMISSIONS) so that a change to
the policy that is not reflected in the docs fails here.
"""

import logging
import threading
import uuid
from collections.abc import Callable, Generator
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import timedelta
from unittest.mock import patch

import jwt
import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, col, select

from app.core.config import settings
from app.core.permissions import UserRole
from app.core.security import ALGORITHM, create_access_token, verify_password
from app.models import Item, User
from app.utils import generate_password_reset_token
from tests.utils.item import create_random_item
from tests.utils.user import (
    create_user_with_role,
    login_as_new_user,
    user_authentication_headers,
)
from tests.utils.utils import random_email

API = settings.API_V1_STR
ADMIN, MANAGER, MEMBER = UserRole.ADMIN, UserRole.MANAGER, UserRole.MEMBER
EVERYONE = {ADMIN, MANAGER, MEMBER}
MISSING_ID = uuid.UUID(int=0)
NEW_PASSWORD = "new-password-123"


@dataclass(frozen=True)
class Scenario:
    """The real resources one matrix case acts on."""

    db: Session
    actor_id: uuid.UUID
    password: str
    target_id: uuid.UUID
    target_email: str
    new_email: str

    def user(self, user_id: uuid.UUID) -> User | None:
        self.db.expire_all()
        return self.db.get(User, user_id)


def _actor_renamed(s: Scenario) -> bool:
    actor = s.user(s.actor_id)
    return actor is not None and actor.full_name == "New Name"


def _password_changed(s: Scenario) -> bool:
    actor = s.user(s.actor_id)
    return actor is not None and verify_password(NEW_PASSWORD, actor.hashed_password)[0]


def _actor_deleted(s: Scenario) -> bool:
    return s.user(s.actor_id) is None


def _item_created(s: Scenario) -> bool:
    statement = select(Item).where(Item.owner_id == s.actor_id)
    return s.db.exec(statement).first() is not None


def _user_created(s: Scenario) -> bool:
    return s.db.exec(select(User).where(User.email == s.new_email)).first() is not None


def _target_renamed(s: Scenario) -> bool:
    target = s.user(s.target_id)
    return target is not None and target.full_name == "Renamed"


def _target_deleted(s: Scenario) -> bool:
    return s.user(s.target_id) is None


@dataclass(frozen=True)
class Case:
    method: str
    path: str  # formatted with the Scenario, like the string values of `body`
    allowed: set[UserRole]
    success_status: int = 200
    body: dict[str, str] | None = None
    # Must hold after an allowed request and must not hold after a denied one
    took_effect: Callable[[Scenario], bool] | None = None


PERMISSION_MATRIX = [
    Case("GET", "/users/me", EVERYONE),
    Case(
        "PATCH",
        "/users/me",
        EVERYONE,
        body={"full_name": "New Name"},
        took_effect=_actor_renamed,
    ),
    Case(
        "PATCH",
        "/users/me/password",
        EVERYONE,
        body={"current_password": "{s.password}", "new_password": NEW_PASSWORD},
        took_effect=_password_changed,
    ),
    Case("DELETE", "/users/me", {MANAGER, MEMBER}, took_effect=_actor_deleted),
    Case("POST", "/login/test-token", EVERYONE),
    Case("GET", "/items/", EVERYONE),
    Case(
        "POST", "/items/", EVERYONE, body={"title": "Item"}, took_effect=_item_created
    ),
    Case("GET", "/users/", {ADMIN, MANAGER}),
    Case("GET", "/users/{s.target_id}", {ADMIN, MANAGER}),
    Case(
        "POST",
        "/users/",
        {ADMIN},
        body={"email": "{s.new_email}", "password": NEW_PASSWORD},
        took_effect=_user_created,
    ),
    Case(
        "PATCH",
        "/users/{s.target_id}",
        {ADMIN},
        body={"full_name": "Renamed"},
        took_effect=_target_renamed,
    ),
    Case("DELETE", "/users/{s.target_id}", {ADMIN}, took_effect=_target_deleted),
    Case("GET", "/metrics/", {ADMIN, MANAGER}),
    Case(
        "POST", "/utils/test-email/?email_to={s.new_email}", {ADMIN}, success_status=201
    ),
    Case("POST", "/password-recovery-html-content/{s.target_email}", {ADMIN}),
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
    "case", PERMISSION_MATRIX, ids=lambda c: f"{c.method} {c.path}"
)
def test_permission_matrix(
    client: TestClient, db: Session, role: UserRole, case: Case
) -> None:
    actor, password = create_user_with_role(db, role)
    target, _ = create_user_with_role(db, MEMBER)
    scenario = Scenario(db, actor.id, password, target.id, target.email, random_email())
    headers = user_authentication_headers(
        client=client, email=actor.email, password=password
    )
    body = case.body and {k: v.format(s=scenario) for k, v in case.body.items()}

    r = client.request(
        case.method,
        f"{API}{case.path.format(s=scenario)}",
        headers=headers,
        json=body,
    )

    allowed = role in case.allowed
    assert r.status_code == (case.success_status if allowed else 403), r.text
    if not allowed:
        assert r.json()["detail"].startswith("Missing permission:")
    if case.took_effect:
        assert case.took_effect(scenario) == allowed


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", f"/users/{MISSING_ID}"),
        ("PATCH", f"/users/{MISSING_ID}"),
        ("DELETE", f"/users/{MISSING_ID}"),
        ("POST", "/password-recovery-html-content/nobody@example.com"),
    ],
)
def test_missing_resource_is_404_only_for_callers_with_permission(
    client: TestClient,
    db: Session,
    member_token_headers: dict[str, str],
    method: str,
    path: str,
) -> None:
    _, admin = login_as_new_user(client, db, ADMIN)
    body = {"full_name": "Nobody"} if method == "PATCH" else None

    r = client.request(method, f"{API}{path}", headers=admin, json=body)
    assert r.status_code == 404

    # Without the permission the answer must not reveal whether it exists
    r = client.request(method, f"{API}{path}", headers=member_token_headers, json=body)
    assert r.status_code == 403


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
    assert record.__dict__["reason"] == "Missing permission: settings:manage"
    # The route template is logged, so the email in the URL never reaches the log
    assert record.__dict__["path"] == f"{API}/password-recovery-html-content/{{email}}"
    assert member.email not in record.getMessage()


def test_refused_self_lockout_is_logged(
    client: TestClient, db: Session, caplog: pytest.LogCaptureFixture
) -> None:
    admin, headers = login_as_new_user(client, db, ADMIN)

    with caplog.at_level(logging.WARNING, logger="app.api.deps"):
        client.delete(f"{API}/users/{admin.id}", headers=headers)

    [record] = [r for r in caplog.records if r.name == "app.api.deps"]
    assert record.__dict__["user_id"] == str(admin.id)
    assert record.__dict__["reason"] == "You cannot delete yourself"
    assert record.__dict__["path"] == f"{API}/users/{{user_id}}"


def test_metrics_counts_users_by_role(client: TestClient, db: Session) -> None:
    _, headers = login_as_new_user(client, db, MANAGER)

    metrics = client.get(f"{API}/metrics/", headers=headers).json()

    assert set(metrics["users_by_role"]) == {"admin", "manager", "member"}
    assert sum(metrics["users_by_role"].values()) == metrics["total_users"]
    assert metrics["users_by_role"]["manager"] >= 1
