"""Health/root endpoints (public)."""
from __future__ import annotations

from tests.conftest import ApiEnv


def test_root(api: ApiEnv) -> None:
    resp = api.client.get("/")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_health(api: ApiEnv) -> None:
    resp = api.client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["environment"] == "test"
