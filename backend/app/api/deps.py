import logging
from collections.abc import Generator
from dataclasses import dataclass
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException, Query, Request, status
from fastapi.security import OAuth2PasswordBearer
from jwt.exceptions import InvalidTokenError
from pydantic import ValidationError
from sqlmodel import Session

from app.core import security
from app.core.config import settings
from app.core.db import engine
from app.core.permissions import Permission, has_permission
from app.models import TokenPayload, User

logger = logging.getLogger(__name__)

reusable_oauth2 = OAuth2PasswordBearer(
    tokenUrl=f"{settings.API_V1_STR}/login/access-token"
)


def get_db() -> Generator[Session]:
    with Session(engine) as session:
        yield session


SessionDep = Annotated[Session, Depends(get_db)]
TokenDep = Annotated[str, Depends(reusable_oauth2)]

MAX_PAGE_SIZE = 100
SkipParam = Annotated[int, Query(ge=0)]
LimitParam = Annotated[int, Query(ge=1, le=MAX_PAGE_SIZE)]


def _unauthenticated(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def get_current_user(session: SessionDep, token: TokenDep) -> User:
    """Resolve the bearer token to a user, or fail with 401.

    The token only identifies the user (`sub`); the role is always loaded
    from the database, so role changes apply on the very next request.
    """
    try:
        payload = jwt.decode(
            token,
            settings.SECRET_KEY,
            algorithms=[security.ALGORITHM],
            options={"require": ["exp", "sub"]},
        )
        token_data = TokenPayload(**payload)
    except InvalidTokenError, ValidationError:
        raise _unauthenticated("Could not validate credentials")
    user = session.get(User, token_data.sub)
    if not user:
        raise _unauthenticated("Could not validate credentials")
    if not user.is_active:
        raise _unauthenticated("Inactive user")
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


def _path_template(request: Request) -> str:
    """The request path with path parameters replaced by their names
    (/users/{user_id}), so values such as emails never reach the logs."""
    names = {str(value): name for name, value in request.path_params.items()}
    segments = request.url.path.split("/")
    return "/".join(f"{{{names[s]}}}" if s in names else s for s in segments)


def denied(
    user: User,
    request: Request,
    reason: str,
    *,
    status_code: int = status.HTTP_403_FORBIDDEN,
) -> HTTPException:
    """Log a refused action and build the error to raise for it."""
    path = _path_template(request)
    logger.warning(
        "authorization denied user_id=%s role=%s reason=%r method=%s path=%s",
        user.id,
        user.role,
        reason,
        request.method,
        path,
        extra={
            "user_id": str(user.id),
            "role": str(user.role),
            "reason": reason,
            "method": request.method,
            "path": path,
        },
    )
    return HTTPException(status_code=status_code, detail=reason)


def ensure_permission(user: User, permission: Permission, request: Request) -> None:
    """Raise 403 unless the user's role grants `permission`."""
    if not has_permission(user.role, permission):
        raise denied(user, request, f"Missing permission: {permission}")


@dataclass(frozen=True)
class PermissionChecker:
    """FastAPI dependency that authenticates the caller and checks one permission."""

    permission: Permission

    def __call__(self, request: Request, current_user: CurrentUser) -> User:
        ensure_permission(current_user, self.permission, request)
        return current_user


def require_permission(permission: Permission) -> PermissionChecker:
    """Use as `dependencies=[Depends(require_permission(Permission.X))]`."""
    return PermissionChecker(permission)
