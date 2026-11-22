"""Health and root endpoints."""
from __future__ import annotations

from fastapi import APIRouter

from api.config import get_settings

router = APIRouter(tags=["health"])


@router.get("/")
def root() -> dict:
    return {"service": "saasbase-api", "status": "ok"}


@router.get("/health")
def health() -> dict:
    settings = get_settings()
    return {"status": "ok", "environment": settings.environment}
