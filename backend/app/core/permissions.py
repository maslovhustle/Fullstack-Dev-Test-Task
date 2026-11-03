"""Authorization policy: the single source of truth for who may do what.

Routes never compare roles. They declare the Permission they need
(see `require_permission` in app/api/deps.py), and this module decides
which roles hold it. Adding a role = one UserRole member + one entry in
ROLE_PERMISSIONS.
"""

from enum import StrEnum


class UserRole(StrEnum):
    ADMIN = "admin"
    MANAGER = "manager"
    MEMBER = "member"


class Permission(StrEnum):
    PROFILE_READ = "profile:read"
    PROFILE_UPDATE = "profile:update"
    PROFILE_DELETE = "profile:delete"
    ITEMS_USE = "items:use"
    ITEMS_MANAGE_ALL = "items:manage_all"
    USERS_LIST = "users:list"
    USERS_CREATE = "users:create"
    USERS_UPDATE = "users:update"
    USERS_DELETE = "users:delete"
    METRICS_VIEW = "metrics:view"
    SETTINGS_MANAGE = "settings:manage"


_SELF_SERVICE = frozenset(
    {
        Permission.PROFILE_READ,
        Permission.PROFILE_UPDATE,
        Permission.PROFILE_DELETE,
        Permission.ITEMS_USE,
    }
)

ROLE_PERMISSIONS: dict[UserRole, frozenset[Permission]] = {
    # Admins cannot delete their own account (PROFILE_DELETE is withheld)
    # so the system can never be left without someone who manages users.
    UserRole.ADMIN: frozenset(Permission) - {Permission.PROFILE_DELETE},
    UserRole.MANAGER: _SELF_SERVICE | {Permission.USERS_LIST, Permission.METRICS_VIEW},
    UserRole.MEMBER: _SELF_SERVICE,
}


def permissions_for(role: UserRole) -> frozenset[Permission]:
    return ROLE_PERMISSIONS[role]


def has_permission(role: UserRole, permission: Permission) -> bool:
    return permission in ROLE_PERMISSIONS[role]
