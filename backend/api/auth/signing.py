"""HMAC + Fernet token primitives.

- HMAC-SHA256: hash a token for lookup (never store the raw token).
- Fernet: encrypt a secret (e.g. reveal a device token back to its owner).
"""

from __future__ import annotations

import hashlib
import hmac

from cryptography.fernet import Fernet

from api.config import get_settings


def hmac_hash(token: str, key: str) -> str:
    return hmac.new(key.encode(), token.encode(), hashlib.sha256).hexdigest()


def encrypt_secret(secret: str, fernet_key: str) -> str:
    return Fernet(fernet_key.encode()).encrypt(secret.encode()).decode()


def decrypt_secret(encrypted: str, fernet_key: str) -> str:
    return Fernet(fernet_key.encode()).decrypt(encrypted.encode()).decode()


def get_fernet_key() -> str:
    settings = get_settings()
    if not settings.fernet_key:
        raise RuntimeError("SAASBASE_FERNET_KEY is not configured")
    return settings.fernet_key


def get_device_key() -> str:
    settings = get_settings()
    if not settings.device_token_key:
        raise RuntimeError("SAASBASE_DEVICE_TOKEN_KEY is not configured")
    return settings.device_token_key
