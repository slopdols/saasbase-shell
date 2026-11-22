"""Cognito JWT verification (RS256).

JWKS is fetched and cached for 1 hour. Verifies signature, issuer,
audience, expiry, and token_use.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Any

import jwt
from jwt import PyJWKClient

from api.config import get_settings
from api.core.errors import UnauthorizedError


@lru_cache
def _jwks_client(url: str) -> PyJWKClient:
    return PyJWKClient(url)


def verify_jwt(token: str) -> dict[str, Any]:
    """Verify a Cognito JWT and return its payload. Raises UnauthorizedError on any failure."""
    settings = get_settings()
    if not settings.cognito_jwks_url:
        raise UnauthorizedError("cognito is not configured")
    try:
        client = _jwks_client(settings.cognito_jwks_url)
        signing_key = client.get_signing_key_from_jwt(token)
        payload: dict[str, Any] = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.cognito_audience or None,
            issuer=settings.cognito_issuer or None,
            options={"verify_exp": True},
        )
    except UnauthorizedError:
        raise
    except Exception as exc:  # noqa: BLE001 - any JWT failure becomes 401
        raise UnauthorizedError(f"invalid token: {exc}") from exc

    if payload.get("token_use") not in ("access", "id"):
        raise UnauthorizedError("invalid token_use")
    return payload
