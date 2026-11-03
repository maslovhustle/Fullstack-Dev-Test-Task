"""Unit tests for the authorization policy and the rules built on it (no HTTP)."""

import uuid

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from app.api.routes.users import ensure_not_self_lockout
from app.core.permissions import (
    ROLE_PERMISSIONS,
    Permission,
    UserRole,
    has_permission,
    permissions_for,
)
from app.models import User, UserMePublic, UserRegister, UserUpdate, UserUpdateMe

SELF_SERVICE = {
    Permission.PROFILE_READ,
    Permission.PROFILE_UPDATE,
    Permission.PROFILE_DELETE,
    Permission.ITEMS_USE,
}


def _user(role: UserRole) -> User:
    return User(id=uuid.uuid4(), email="u@example.com", hashed_password="x", role=role)


def test_every_role_has_a_policy_entry() -> None:
    assert set(ROLE_PERMISSIONS) == set(UserRole)


def test_every_permission_is_granted_to_some_role() -> None:
    granted = set().union(*ROLE_PERMISSIONS.values())

    assert granted == set(Permission)


def test_permissions_are_namespaced() -> None:
    assert all(p.value.count(":") == 1 for p in Permission)


def test_role_permissions() -> None:
    assert permissions_for(UserRole.MEMBER) == SELF_SERVICE
    assert permissions_for(UserRole.MANAGER) == SELF_SERVICE | {
        Permission.USERS_LIST,
        Permission.METRICS_VIEW,
    }
    assert permissions_for(UserRole.ADMIN) == set(Permission) - {
        Permission.PROFILE_DELETE
    }


def test_only_admins_can_manage_users_or_settings() -> None:
    privileged = {
        Permission.USERS_CREATE,
        Permission.USERS_UPDATE,
        Permission.USERS_DELETE,
        Permission.SETTINGS_MANAGE,
        Permission.ITEMS_MANAGE_ALL,
    }
    for role in UserRole:
        expected = role == UserRole.ADMIN
        assert all(has_permission(role, p) == expected for p in privileged), role


def test_me_schema_exposes_sorted_permissions_of_the_role() -> None:
    me = UserMePublic.model_validate(_user(UserRole.MANAGER)).model_dump(mode="json")

    assert me["role"] == "manager"
    assert me["permissions"] == sorted(
        p.value for p in permissions_for(UserRole.MANAGER)
    )


@pytest.mark.parametrize(
    ("schema", "valid_payload"),
    [
        (UserRegister, {"email": "u@example.com", "password": "password123"}),
        (UserUpdateMe, {"full_name": "Me"}),
    ],
)
def test_self_service_schemas_reject_role(
    schema: type[UserRegister | UserUpdateMe], valid_payload: dict[str, str]
) -> None:
    schema.model_validate(valid_payload)

    with pytest.raises(ValidationError) as exc:
        schema.model_validate({**valid_payload, "role": "admin"})

    [error] = exc.value.errors()
    assert error["type"] == "extra_forbidden"
    assert error["loc"] == ("role",)


def test_unknown_role_is_rejected() -> None:
    with pytest.raises(ValidationError):
        UserUpdate.model_validate({"role": "superadmin"})


@pytest.mark.parametrize(
    "update",
    [UserUpdate(role=UserRole.MEMBER), UserUpdate(is_active=False), None],
    ids=["demote", "deactivate", "delete"],
)
def test_self_lockout_is_forbidden(update: UserUpdate | None) -> None:
    admin = _user(UserRole.ADMIN)

    with pytest.raises(HTTPException) as exc:
        ensure_not_self_lockout(admin, admin, update)

    assert exc.value.status_code == 403


@pytest.mark.parametrize(
    "update",
    [
        UserUpdate(full_name="New"),
        UserUpdate(role=UserRole.ADMIN),
        UserUpdate(is_active=True),
    ],
    ids=["rename", "same-role", "stay-active"],
)
def test_harmless_self_updates_are_allowed(update: UserUpdate) -> None:
    admin = _user(UserRole.ADMIN)

    ensure_not_self_lockout(admin, admin, update)


def test_changes_to_other_users_are_not_lockout() -> None:
    admin, other = _user(UserRole.ADMIN), _user(UserRole.ADMIN)

    ensure_not_self_lockout(admin, other, UserUpdate(role=UserRole.MEMBER))
    ensure_not_self_lockout(admin, other, None)
