"""Auth endpoints - demonstrate the caller dependency injectors."""
from __future__ import annotations

from fastapi import APIRouter, Depends

from api.auth.caller import Caller
from api.auth.deps import optional_caller, require_admin, require_caller

router = APIRouter(prefix="/v1/auth", tags=["auth"])


@router.get("/me")
def me(caller: Caller = Depends(require_caller)) -> dict:
    return {
        "sub": caller.sub,
        "email": caller.email,
        "groups": sorted(caller.groups),
        "is_admin": caller.is_admin,
    }


@router.get("/whoami")
def whoami(caller: Caller | None = Depends(optional_caller)) -> dict:
    if caller is None:
        return {"authenticated": False}
    return {"authenticated": True, "sub": caller.sub}


@router.get("/admin/status")
def admin_status(caller: Caller = Depends(require_admin)) -> dict:
    return {"admin": True, "sub": caller.sub}
