"""Caller dataclass + authorization helpers.

Caller is the authenticated identity attached to every request.
Admins bypass all group/owner checks.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from api.core.errors import ForbiddenError

ADMIN_GROUP = "admin"


@dataclass(frozen=True)
class Caller:
    sub: str
    email: str | None = None
    groups: frozenset[str] = field(default_factory=frozenset)
    is_anonymous: bool = False

    @classmethod
    def from_jwt(cls, payload: dict[str, Any]) -> "Caller":
        groups = payload.get("cognito:groups") or []
        return cls(
            sub=payload["sub"],
            email=payload.get("email"),
            groups=frozenset(groups),
        )

    @property
    def is_admin(self) -> bool:
        return ADMIN_GROUP in self.groups


def require_group(caller: Caller, group: str) -> None:
    """Raise ForbiddenError unless caller is in the group (or is admin)."""
    if caller.is_admin or group in caller.groups:
        return
    raise ForbiddenError(f"group '{group}' required")


def require_owner(caller: Caller, owner_sub: str) -> None:
    """Raise ForbiddenError unless caller owns the resource (or is admin)."""
    if caller.is_admin or caller.sub == owner_sub:
        return
    raise ForbiddenError("resource belongs to another user")
