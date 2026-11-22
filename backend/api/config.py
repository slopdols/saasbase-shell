"""Application settings.

Every field maps to a `SAASBASE_<NAME>` env var (or `.env` entry).
In production, values can be injected from AWS Secrets Manager at cold start.
"""

from functools import lru_cache
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SAASBASE_", env_file=".env")

    # Environment
    environment: str = "local"
    db_backend: Literal["dynamo", "relational"] = "dynamo"
    region: str = "us-east-2"

    # CORS
    cors_origins: list[str] = Field(default_factory=lambda: ["http://localhost:8080"])

    # API
    api_prefix: str = "/v1"

    # Data stores
    table_main: str = "saasbase-main-dev"
    table_ledger: str = "saasbase-ledger-dev"
    table_throttle: str = "saasbase-throttle-dev"
    table_webmetrics: str = "saasbase-webmetrics-dev"

    # Auth (Cognito)
    cognito_user_pool_id: str = ""
    cognito_issuer: str = ""
    cognito_audience: str = ""
    cognito_jwks_url: str = ""

    # Auth (device / anonymous tokens)
    device_token_key: str = ""
    fernet_key: str = ""

    # Stripe
    stripe_secret_key: str = ""
    stripe_webhook_secret: str = ""
    stripe_publishable_key: str = ""

    # Email (SES)
    email_from: str = "no-reply@example.com"

    # Alerts
    alert_telegram_bot_token: str = ""
    alert_telegram_chat_id: str = ""

    # Secrets
    secrets_arn: str = ""


@lru_cache
def get_settings() -> Settings:
    return Settings()
