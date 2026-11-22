"""Device token auth (HMAC).

32-byte random token issued to the client. The token is HMAC-SHA256 hashed
for storage/lookup and Fernet-encrypted for safe reveal back to the owner.
"""

from __future__ import annotations

import secrets
from typing import Any

from api.auth.signing import get_device_key, hmac_hash
from api.core.errors import UnauthorizedError
from api.core.time import now_utc_iso


def generate_device_token() -> str:
    return secrets.token_urlsafe(32)


def token_hash(token: str) -> str:
    return hmac_hash(token, get_device_key())


def verify_device_token(token: str) -> dict[str, Any]:
    """Verify a device token. Raises UnauthorizedError on failure.

    NOTE: In a full implementation this looks up `token_hash(token)` in the
    database to resolve the owning account. The generic shell returns the
    token metadata only.
    """
    if not token:
        raise UnauthorizedError("missing device token")
    try:
        token_hash(token)
    except RuntimeError as exc:
        raise UnauthorizedError(str(exc)) from exc
    return {"device_token": True, "verified_at": now_utc_iso()}
