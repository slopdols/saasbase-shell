"""Auth matrix: every route must be protected exactly as declared.

This test MUST fail if any route becomes under-protected. Critical security gate.
"""

from __future__ import annotations

from tests.conftest import ApiEnv

# (method, path, requires_auth, optional_auth)
ROUTE_MATRIX: list[tuple[str, str, bool, bool]] = [
    ("GET", "/", False, False),
    ("GET", "/health", False, False),
    ("GET", "/v1/auth/me", True, False),
    ("GET", "/v1/auth/whoami", False, True),
    ("GET", "/v1/auth/admin/status", True, False),
    ("POST", "/v1/items", True, False),
    ("GET", "/v1/items", True, False),
    ("GET", "/v1/items/some-id", True, False),
    ("PUT", "/v1/items/some-id", True, False),
    ("DELETE", "/v1/items/some-id", True, False),
]


def test_route_protection_matrix(api: ApiEnv) -> None:
    for method, path, requires_auth, _optional in ROUTE_MATRIX:
        resp = api.client.request(method, path)
        if requires_auth:
            assert resp.status_code == 401, f"{method} {path} should require auth"
        else:
            assert resp.status_code != 401, f"{method} {path} should be public/optional"


def test_admin_route_rejects_non_admin(api: ApiEnv) -> None:
    resp = api.client.get("/v1/auth/admin/status", headers=api.auth(groups=["advertiser"]))
    assert resp.status_code == 403


def test_admin_route_allows_admin(api: ApiEnv) -> None:
    resp = api.client.get("/v1/auth/admin/status", headers=api.auth(groups=["admin"]))
    assert resp.status_code == 200
    assert resp.json()["admin"] is True


def test_me_returns_caller_identity(api: ApiEnv) -> None:
    resp = api.client.get("/v1/auth/me", headers=api.auth(sub="user-9", groups=["admin"]))
    assert resp.status_code == 200
    body = resp.json()
    assert body["sub"] == "user-9"
    assert body["is_admin"] is True
