"""Shared test fixtures.

- Env vars are set BEFORE importing the app so Settings() picks them up.
- mock DynamoDB (moto) per test, bound to a fresh DynamoCrud.
- Stubbed Cognito JWKS so valid JWTs can be minted and verified locally.
"""

from __future__ import annotations

import os
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

os.environ.setdefault("SAASBASE_ENVIRONMENT", "test")
os.environ.setdefault("SAASBASE_DB_BACKEND", "dynamo")
os.environ.setdefault("SAASBASE_REGION", "us-east-2")
os.environ.setdefault("SAASBASE_TABLE_MAIN", "saasbase-main-test")
os.environ.setdefault("SAASBASE_TABLE_LEDGER", "saasbase-ledger-test")
os.environ.setdefault("SAASBASE_TABLE_THROTTLE", "saasbase-throttle-test")
os.environ.setdefault("SAASBASE_TABLE_WEBMETRICS", "saasbase-webmetrics-test")
os.environ.setdefault("SAASBASE_COGNITO_ISSUER", "https://cognito-idp.us-east-2.amazonaws.com/test")
os.environ.setdefault("SAASBASE_COGNITO_AUDIENCE", "test-audience")
os.environ.setdefault(
    "SAASBASE_COGNITO_JWKS_URL",
    "https://cognito-idp.us-east-2.amazonaws.com/test/.well-known/jwks.json",
)
os.environ.setdefault("SAASBASE_CORS_ORIGINS", '["http://localhost:8080"]')

import boto3
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from moto import mock_aws

from api.auth import cognito
from api.crud.backend_flag import get_crud
from api.crud.dynamo_crud import DynamoCrud
from api.main import app

TABLE = "saasbase-main-test"

# --- RSA key pair to mint + verify test JWTs ---
_private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_public_pem = (
    _private_key.public_key()
    .public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    .decode()
)


def make_jwt(
    sub: str = "user-123",
    groups: list[str] | None = None,
    email: str = "user@example.com",
    token_use: str = "access",
    exp_delta_minutes: int = 60,
) -> str:
    now = datetime.now(UTC)
    payload = {
        "sub": sub,
        "email": email,
        "cognito:groups": groups or [],
        "token_use": token_use,
        "iss": os.environ["SAASBASE_COGNITO_ISSUER"],
        "aud": os.environ["SAASBASE_COGNITO_AUDIENCE"],
        "iat": now,
        "exp": now + timedelta(minutes=exp_delta_minutes),
    }
    return jwt.encode(payload, _private_key, algorithm="RS256")


class _FakeSigningKey:
    def __init__(self, key: str) -> None:
        self.key = key


class _FakeJwksClient:
    def get_signing_key_from_jwt(self, token: str) -> _FakeSigningKey:
        return _FakeSigningKey(_public_pem)


@pytest.fixture(autouse=True)
def _stub_jwks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cognito, "_jwks_client", lambda url: _FakeJwksClient())


def _create_table() -> None:
    client = boto3.client("dynamodb", region_name="us-east-2")
    client.create_table(
        TableName=TABLE,
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
            {"AttributeName": "gsi1_pk", "AttributeType": "S"},
            {"AttributeName": "gsi1_sk", "AttributeType": "S"},
        ],
        GlobalSecondaryIndexes=[
            {
                "IndexName": "gsi1",
                "KeySchema": [
                    {"AttributeName": "gsi1_pk", "KeyType": "HASH"},
                    {"AttributeName": "gsi1_sk", "KeyType": "RANGE"},
                ],
                "Projection": {"ProjectionType": "ALL"},
            }
        ],
        BillingMode="PAY_PER_REQUEST",
    )


@pytest.fixture
def crud() -> DynamoCrud:
    """Fresh mock DynamoDB tables for each test."""
    with mock_aws():
        get_crud.cache_clear()
        _create_table()
        yield DynamoCrud(table_name=TABLE, region="us-east-2")
        get_crud.cache_clear()


@dataclass
class ApiEnv:
    client: TestClient
    crud: DynamoCrud
    make_jwt: Callable[..., str]

    def auth(self, **kwargs: Any) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.make_jwt(**kwargs)}"}


@pytest.fixture
def api(crud: DynamoCrud) -> ApiEnv:
    """FastAPI TestClient with stubbed auth, bound to mock DynamoDB."""
    return ApiEnv(client=TestClient(app), crud=crud, make_jwt=make_jwt)
