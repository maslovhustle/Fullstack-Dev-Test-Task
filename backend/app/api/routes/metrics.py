from fastapi import APIRouter, Depends
from sqlmodel import col, func, select

from app.api.deps import SessionDep, require_permission
from app.core.permissions import Permission, UserRole
from app.models import Item, MetricsPublic, User

router = APIRouter(prefix="/metrics", tags=["metrics"])


@router.get(
    "/",
    dependencies=[Depends(require_permission(Permission.METRICS_VIEW))],
    response_model=MetricsPublic,
)
def read_metrics(session: SessionDep) -> MetricsPublic:
    """
    Aggregate counts for the insights page (stub: no time series yet).
    """
    role_counts = dict(
        session.exec(select(User.role, func.count()).group_by(col(User.role))).all()
    )
    return MetricsPublic(
        total_users=sum(role_counts.values()),
        active_users=session.exec(
            select(func.count()).select_from(User).where(col(User.is_active))
        ).one(),
        users_by_role={role: role_counts.get(role, 0) for role in UserRole},
        total_items=session.exec(select(func.count()).select_from(Item)).one(),
    )
