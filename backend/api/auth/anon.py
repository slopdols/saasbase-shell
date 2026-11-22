"""Anonymous session tokens.

Used for pre-auth / anonymous sessions. HMAC-signed with the device key so
they cannot be forged, and scoped to a session id.
"""

from __future__ import annotations

import hashlib
import hmac

from api.auth.signing import get_device_key
from api.core.errors import UnauthorizedError


def create_anon_token(session_id: str) -> str:
    key = get_device_key()
    return hmac.new(key.encode(), session_id.encode(), hashlib.sha256).hexdigest()


def verify_anon_token(token: str, session_id: str) -> bool:
    expected = create_anon_token(session_id)
    if not hmac.compare_digest(token, expected):
        raise UnauthorizedError("invalid anonymous token")
    return True
