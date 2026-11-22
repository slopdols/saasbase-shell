"""FastAPI dependency injectors.

Usage in routers:
    caller: Caller = Depends(require_caller)
    caller: Caller | None = Depends(optional_caller)
    caller: Caller = Depends(require_admin)
    device: dict[str, Any] = Depends(require_device)
"""

from __future__ import annotations

from typing import Any

from fastapi import Depends, Request

from api.auth.caller import Caller
from api.auth.cognito import verify_jwt
from api.auth.device import verify_device_token
from api.core.errors import ForbiddenError, UnauthorizedError


def _extract_bearer(request: Request) -> str | None:
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        return header[len("Bearer ") :].strip()
    return None


def require_caller(request: Request) -> Caller:
    token = _extract_bearer(request)
    if not token:
        raise UnauthorizedError("missing bearer token")
    return Caller.from_jwt(verify_jwt(token))


def optional_caller(request: Request) -> Caller | None:
    token = _extract_bearer(request)
    if not token:
        return None
    try:
        return Caller.from_jwt(verify_jwt(token))
    except UnauthorizedError:
        return None


def require_admin(caller: Caller = Depends(require_caller)) -> Caller:
    if not caller.is_admin:
        raise ForbiddenError("admin role required")
    return caller


def require_device(request: Request) -> dict[str, Any]:
    token = request.headers.get("X-Device-Token")
    if not token:
        raise UnauthorizedError("missing device token")
    return verify_device_token(token)
