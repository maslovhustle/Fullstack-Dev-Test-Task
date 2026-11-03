import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import col, delete, func, select

from app import crud
from app.api.deps import (
    CurrentUser,
    LimitParam,
    SessionDep,
    SkipParam,
    require_permission,
)
from app.core.config import settings
from app.core.permissions import Permission, UserRole, has_permission
from app.core.security import get_password_hash, verify_password
from app.models import (
    Item,
    Message,
    UpdatePassword,
    User,
    UserCreate,
    UserMePublic,
    UserPublic,
    UserRegister,
    UsersPublic,
    UserUpdate,
    UserUpdateMe,
)
from app.utils import generate_new_account_email, send_email

router = APIRouter(prefix="/users", tags=["users"])


def ensure_not_self_lockout(
    current_user: User, target: User, user_in: UserUpdate | None = None
) -> None:
    """Forbid changing your own role, deactivating or deleting yourself via the
    admin endpoints. Whoever manages users therefore always keeps that power,
    so the last admin can never be removed.
    """
    if target.id != current_user.id:
        return
    if user_in is None:
        raise HTTPException(status_code=403, detail="You cannot delete yourself")
    if user_in.role is not None and user_in.role != current_user.role:
        raise HTTPException(status_code=403, detail="You cannot change your own role")
    if user_in.is_active is False:
        raise HTTPException(status_code=403, detail="You cannot deactivate yourself")


# Roles whose holders can manage users; at least one active such user must remain
USER_MANAGER_ROLES = [
    role for role in UserRole if has_permission(role, Permission.USERS_UPDATE)
]


def ensure_a_user_manager_remains(
    session: SessionDep, target: User, user_in: UserUpdate | None = None
) -> None:
    """Refuse to remove the last active user who can manage users.

    The row lock makes concurrent removals (two admins demoting each other)
    wait for one another, so the second request sees the first one's result.
    """
    removes_manager = (
        target.role in USER_MANAGER_ROLES
        and target.is_active
        and (
            user_in is None
            or user_in.is_active is False
            or (user_in.role is not None and user_in.role not in USER_MANAGER_ROLES)
        )
    )
    if not removes_manager:
        return
    statement = (
        select(User.id)
        .where(col(User.role).in_(USER_MANAGER_ROLES), col(User.is_active))
        .with_for_update()
    )
    if len(session.exec(statement).all()) <= 1:
        raise HTTPException(
            status_code=409,
            detail="At least one active user must be able to manage users",
        )


@router.get(
    "/",
    dependencies=[Depends(require_permission(Permission.USERS_LIST))],
    response_model=UsersPublic,
)
def read_users(
    session: SessionDep, skip: SkipParam = 0, limit: LimitParam = 100
) -> Any:
    """
    Retrieve users.
    """

    count_statement = select(func.count()).select_from(User)
    count = session.exec(count_statement).one()

    statement = (
        select(User).order_by(col(User.created_at).desc()).offset(skip).limit(limit)
    )
    users = session.exec(statement).all()

    users_public = [UserPublic.model_validate(user) for user in users]
    return UsersPublic(data=users_public, count=count)


@router.post(
    "/",
    dependencies=[Depends(require_permission(Permission.USERS_CREATE))],
    response_model=UserPublic,
)
def create_user(*, session: SessionDep, user_in: UserCreate) -> Any:
    """
    Create new user.
    """
    user = crud.get_user_by_email(session=session, email=user_in.email)
    if user:
        raise HTTPException(
            status_code=400,
            detail="The user with this email already exists in the system.",
        )

    user = crud.create_user(session=session, user_create=user_in)
    if settings.emails_enabled and user_in.email:
        email_data = generate_new_account_email(
            email_to=user_in.email, username=user_in.email, password=user_in.password
        )
        send_email(
            email_to=user_in.email,
            subject=email_data.subject,
            html_content=email_data.html_content,
        )
    return user


@router.patch(
    "/me",
    dependencies=[Depends(require_permission(Permission.PROFILE_UPDATE))],
    response_model=UserMePublic,
)
def update_user_me(
    *, session: SessionDep, user_in: UserUpdateMe, current_user: CurrentUser
) -> Any:
    """
    Update own user.
    """

    if user_in.email:
        existing_user = crud.get_user_by_email(session=session, email=user_in.email)
        if existing_user and existing_user.id != current_user.id:
            raise HTTPException(
                status_code=409, detail="User with this email already exists"
            )
    user_data = user_in.model_dump(exclude_unset=True)
    current_user.sqlmodel_update(user_data)
    session.add(current_user)
    session.commit()
    session.refresh(current_user)
    return current_user


@router.patch(
    "/me/password",
    dependencies=[Depends(require_permission(Permission.PROFILE_UPDATE))],
    response_model=Message,
)
def update_password_me(
    *, session: SessionDep, body: UpdatePassword, current_user: CurrentUser
) -> Any:
    """
    Update own password.
    """
    verified, _ = verify_password(body.current_password, current_user.hashed_password)
    if not verified:
        raise HTTPException(status_code=400, detail="Incorrect password")
    if body.current_password == body.new_password:
        raise HTTPException(
            status_code=400, detail="New password cannot be the same as the current one"
        )
    hashed_password = get_password_hash(body.new_password)
    current_user.hashed_password = hashed_password
    session.add(current_user)
    session.commit()
    return Message(message="Password updated successfully")


@router.get(
    "/me",
    dependencies=[Depends(require_permission(Permission.PROFILE_READ))],
    response_model=UserMePublic,
)
def read_user_me(current_user: CurrentUser) -> Any:
    """
    Get current user, including the permissions granted by their role.
    """
    return current_user


@router.delete(
    "/me",
    dependencies=[Depends(require_permission(Permission.PROFILE_DELETE))],
    response_model=Message,
)
def delete_user_me(session: SessionDep, current_user: CurrentUser) -> Any:
    """
    Delete own user.
    """
    session.delete(current_user)
    session.commit()
    return Message(message="User deleted successfully")


@router.post("/signup", response_model=UserPublic)
def register_user(session: SessionDep, user_in: UserRegister) -> Any:
    """
    Create new user without the need to be logged in.
    """
    user = crud.get_user_by_email(session=session, email=user_in.email)
    if user:
        raise HTTPException(
            status_code=400,
            detail="The user with this email already exists in the system",
        )
    user_create = UserCreate.model_validate(user_in)
    user = crud.create_user(session=session, user_create=user_create)
    return user


@router.get(
    "/{user_id}",
    dependencies=[Depends(require_permission(Permission.USERS_LIST))],
    response_model=UserPublic,
)
def read_user_by_id(user_id: uuid.UUID, session: SessionDep) -> Any:
    """
    Get a specific user by id.
    """
    user = session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@router.patch(
    "/{user_id}",
    dependencies=[Depends(require_permission(Permission.USERS_UPDATE))],
    response_model=UserPublic,
)
def update_user(
    *,
    session: SessionDep,
    current_user: CurrentUser,
    user_id: uuid.UUID,
    user_in: UserUpdate,
) -> Any:
    """
    Update a user.
    """

    db_user = session.get(User, user_id)
    if not db_user:
        raise HTTPException(
            status_code=404,
            detail="The user with this id does not exist in the system",
        )
    ensure_not_self_lockout(current_user, db_user, user_in)
    ensure_a_user_manager_remains(session, db_user, user_in)
    if user_in.email:
        existing_user = crud.get_user_by_email(session=session, email=user_in.email)
        if existing_user and existing_user.id != user_id:
            raise HTTPException(
                status_code=409, detail="User with this email already exists"
            )

    db_user = crud.update_user(session=session, db_user=db_user, user_in=user_in)
    return db_user


@router.delete(
    "/{user_id}", dependencies=[Depends(require_permission(Permission.USERS_DELETE))]
)
def delete_user(
    session: SessionDep, current_user: CurrentUser, user_id: uuid.UUID
) -> Message:
    """
    Delete a user.
    """
    user = session.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    ensure_not_self_lockout(current_user, user)
    ensure_a_user_manager_remains(session, user)
    statement = delete(Item).where(col(Item.owner_id) == user_id)
    session.exec(statement)
    session.delete(user)
    session.commit()
    return Message(message="User deleted successfully")
