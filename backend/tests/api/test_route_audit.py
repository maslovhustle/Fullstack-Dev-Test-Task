"""Fail fast when someone adds an endpoint and forgets to authorize it."""

from collections.abc import Iterator

from fastapi.dependencies.models import Dependant
from fastapi.routing import APIRoute, iter_route_contexts

from app.api.deps import PermissionChecker
from app.core.config import settings
from app.main import app

API = settings.API_V1_STR

# Endpoints reachable without a permission. Keep this list short and explicit.
PUBLIC_ENDPOINTS = {
    ("POST", f"{API}/login/access-token"),
    ("POST", f"{API}/password-recovery/{{email}}"),
    ("POST", f"{API}/reset-password/"),
    ("POST", f"{API}/users/signup"),
    ("GET", f"{API}/utils/health-check/"),
    # Development-only router, not mounted unless FASTAPI_ENV=development
    ("POST", f"{API}/private/users/"),
}


def _permission_checkers(dependant: Dependant) -> Iterator[PermissionChecker]:
    for dependency in dependant.dependencies:
        if isinstance(dependency.call, PermissionChecker):
            yield dependency.call
        yield from _permission_checkers(dependency)


def _api_endpoints() -> Iterator[tuple[str, str, Dependant]]:
    # iter_route_contexts flattens included routers and merges router-level
    # dependencies, so this sees exactly what a request would go through.
    for route in iter_route_contexts(app.routes):
        path = route.path or ""
        if isinstance(route.original_route, APIRoute) and path.startswith(API):
            for method in route.methods or ():
                yield method, path, route.dependant


def test_every_non_public_endpoint_requires_a_permission() -> None:
    unprotected = {
        (method, path)
        for method, path, dependant in _api_endpoints()
        if not any(_permission_checkers(dependant))
    }

    assert unprotected - PUBLIC_ENDPOINTS == set(), "add require_permission(...)"


def test_public_allowlist_has_no_stale_entries() -> None:
    endpoints = {(method, path) for method, path, _ in _api_endpoints()}

    assert len(endpoints) > len(PUBLIC_ENDPOINTS), "route discovery found nothing"
    assert PUBLIC_ENDPOINTS - endpoints == set()
