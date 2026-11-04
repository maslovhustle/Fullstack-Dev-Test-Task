import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlmodel import col, func, select

from app.api.deps import (
    CurrentUser,
    LimitParam,
    SessionDep,
    SkipParam,
    ensure_permission,
    require_permission,
)
from app.core.permissions import Permission, has_permission
from app.models import (
    Item,
    ItemCreate,
    ItemPublic,
    ItemsPublic,
    ItemUpdate,
    Message,
    User,
)

router = APIRouter(
    prefix="/items",
    tags=["items"],
    dependencies=[Depends(require_permission(Permission.ITEMS_USE))],
)


def get_accessible_item(
    session: SessionDep, current_user: User, item_id: uuid.UUID, request: Request
) -> Item:
    """Load an item the caller owns, or any item if they may manage all items."""
    item = session.get(Item, item_id)
    if not item:
        raise HTTPException(status_code=404, detail="Item not found")
    if item.owner_id != current_user.id:
        ensure_permission(current_user, Permission.ITEMS_MANAGE_ALL, request)
    return item


@router.get("/", response_model=ItemsPublic)
def read_items(
    session: SessionDep,
    current_user: CurrentUser,
    skip: SkipParam = 0,
    limit: LimitParam = 100,
) -> Any:
    """
    Retrieve items: all of them for item managers, otherwise only your own.
    """
    count_statement = select(func.count()).select_from(Item)
    statement = select(Item)
    if not has_permission(current_user.role, Permission.ITEMS_MANAGE_ALL):
        count_statement = count_statement.where(Item.owner_id == current_user.id)
        statement = statement.where(Item.owner_id == current_user.id)

    count = session.exec(count_statement).one()
    items = session.exec(
        statement.order_by(col(Item.created_at).desc()).offset(skip).limit(limit)
    ).all()

    items_public = [ItemPublic.model_validate(item) for item in items]
    return ItemsPublic(data=items_public, count=count)


@router.get("/{id}", response_model=ItemPublic)
def read_item(
    session: SessionDep, current_user: CurrentUser, id: uuid.UUID, request: Request
) -> Any:
    """
    Get item by ID.
    """
    return get_accessible_item(session, current_user, id, request)


@router.post("/", response_model=ItemPublic)
def create_item(
    *, session: SessionDep, current_user: CurrentUser, item_in: ItemCreate
) -> Any:
    """
    Create new item.
    """
    item = Item.model_validate(item_in, update={"owner_id": current_user.id})
    session.add(item)
    session.commit()
    session.refresh(item)
    return item


@router.put("/{id}", response_model=ItemPublic)
def update_item(
    *,
    session: SessionDep,
    current_user: CurrentUser,
    id: uuid.UUID,
    item_in: ItemUpdate,
    request: Request,
) -> Any:
    """
    Update an item.
    """
    item = get_accessible_item(session, current_user, id, request)
    update_dict = item_in.model_dump(exclude_unset=True)
    item.sqlmodel_update(update_dict)
    session.add(item)
    session.commit()
    session.refresh(item)
    return item


@router.delete("/{id}")
def delete_item(
    session: SessionDep, current_user: CurrentUser, id: uuid.UUID, request: Request
) -> Message:
    """
    Delete an item.
    """
    item = get_accessible_item(session, current_user, id, request)
    session.delete(item)
    session.commit()
    return Message(message="Item deleted successfully")
