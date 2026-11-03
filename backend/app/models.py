import uuid
from datetime import UTC, datetime

import sqlalchemy as sa
from pydantic import EmailStr, computed_field, field_validator
from sqlmodel import Field, Relationship, SQLModel
from sqlmodel._compat import SQLModelConfig

from app.core.permissions import Permission, UserRole, permissions_for


def get_datetime_utc() -> datetime:
    return datetime.now(UTC)


# Shared properties
class UserBase(SQLModel):
    email: EmailStr = Field(unique=True, index=True, max_length=255)
    is_active: bool = True
    full_name: str | None = Field(default=None, max_length=255)


# Properties to receive via API on creation
class UserCreate(UserBase):
    password: str = Field(min_length=8, max_length=128)
    role: UserRole = UserRole.MEMBER


# Self-service schemas reject unknown fields so a client cannot smuggle in `role`
class UserRegister(SQLModel):
    model_config = SQLModelConfig(extra="forbid")

    email: EmailStr = Field(max_length=255)
    password: str = Field(min_length=8, max_length=128)
    full_name: str | None = Field(default=None, max_length=255)


def _reject_null(value: object) -> object:
    if value is None:
        raise ValueError("may be omitted, but not null")
    return value


# Properties to receive via API on update, all are optional
class UserUpdate(SQLModel):
    email: EmailStr | None = Field(default=None, max_length=255)
    is_active: bool | None = None
    role: UserRole | None = None
    full_name: str | None = Field(default=None, max_length=255)
    password: str | None = Field(default=None, min_length=8, max_length=128)

    _not_null = field_validator("email", "is_active", "role", "password")(_reject_null)


class UserUpdateMe(SQLModel):
    model_config = SQLModelConfig(extra="forbid")

    full_name: str | None = Field(default=None, max_length=255)
    email: EmailStr | None = Field(default=None, max_length=255)

    _not_null = field_validator("email")(_reject_null)


class UpdatePassword(SQLModel):
    current_password: str = Field(min_length=8, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)


# Database model, database table inferred from class name
class User(UserBase, table=True):
    id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    hashed_password: str
    # Stored as a plain string (not a native Postgres enum) so adding a role
    # needs no migration; values are validated against UserRole in Python.
    role: UserRole = Field(
        default=UserRole.MEMBER,
        sa_type=sa.Enum(
            UserRole,
            native_enum=False,
            create_constraint=False,
            length=32,
            values_callable=lambda roles: [role.value for role in roles],
        ),
        sa_column_kwargs={"server_default": UserRole.MEMBER.value},
    )
    created_at: datetime | None = Field(default_factory=get_datetime_utc)
    items: list[Item] = Relationship(back_populates="owner", cascade_delete=True)


# Properties to return via API, id is always required
class UserPublic(UserBase):
    id: uuid.UUID
    role: UserRole
    created_at: datetime | None = None


# The current user, plus what they may do: the frontend renders from
# `permissions` and never maps roles to capabilities itself.
class UserMePublic(UserPublic):
    @computed_field  # type: ignore[prop-decorator]
    @property
    def permissions(self) -> list[Permission]:
        return sorted(permissions_for(self.role))


class UsersPublic(SQLModel):
    data: list[UserPublic]
    count: int


# Shared properties
class ItemBase(SQLModel):
    title: str = Field(min_length=1, max_length=255)
    description: str | None = Field(default=None, max_length=255)


# Properties to receive on item creation
class ItemCreate(ItemBase):
    pass


# Properties to receive on item update
class ItemUpdate(SQLModel):
    title: str | None = Field(default=None, min_length=1, max_length=255)
    description: str | None = Field(default=None, max_length=255)


# Database model, database table inferred from class name
class Item(ItemBase, table=True):
    id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    created_at: datetime | None = Field(default_factory=get_datetime_utc)
    owner_id: uuid.UUID = Field(
        foreign_key="user.id", nullable=False, ondelete="CASCADE"
    )
    owner: User | None = Relationship(back_populates="items")


# Properties to return via API, id is always required
class ItemPublic(ItemBase):
    id: uuid.UUID
    owner_id: uuid.UUID
    created_at: datetime | None = None


class ItemsPublic(SQLModel):
    data: list[ItemPublic]
    count: int


class MetricsPublic(SQLModel):
    total_users: int
    active_users: int
    users_by_role: dict[UserRole, int]
    total_items: int


# Generic message
class Message(SQLModel):
    message: str


# JSON payload containing access token
class Token(SQLModel):
    access_token: str
    token_type: str = "bearer"


# Contents of JWT token
class TokenPayload(SQLModel):
    sub: str | None = None


class NewPassword(SQLModel):
    token: str
    new_password: str = Field(min_length=8, max_length=128)
