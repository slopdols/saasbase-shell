"""Item CRUD endpoint tests (auth + optimistic locking + owner isolation)."""

from __future__ import annotations

from tests.conftest import ApiEnv


def test_create_requires_auth(api: ApiEnv) -> None:
    resp = api.client.post("/v1/items", json={"name": "x"})
    assert resp.status_code == 401


def test_create_and_get(api: ApiEnv) -> None:
    headers = api.auth()
    resp = api.client.post("/v1/items", json={"name": "first"}, headers=headers)
    assert resp.status_code == 201
    item = resp.json()
    assert item["name"] == "first"
    assert item["version"] == 0

    fetched = api.client.get(f"/v1/items/{item['id']}", headers=headers)
    assert fetched.status_code == 200
    assert fetched.json()["name"] == "first"


def test_get_missing_returns_404(api: ApiEnv) -> None:
    resp = api.client.get("/v1/items/nope", headers=api.auth())
    assert resp.status_code == 404


def test_update_with_stale_version_conflicts(api: ApiEnv) -> None:
    headers = api.auth()
    created = api.client.post("/v1/items", json={"name": "a"}, headers=headers).json()
    ok = api.client.put(
        f"/v1/items/{created['id']}", json={"name": "b", "version": 0}, headers=headers
    )
    assert ok.status_code == 200
    assert ok.json()["version"] == 1

    stale = api.client.put(
        f"/v1/items/{created['id']}", json={"name": "c", "version": 0}, headers=headers
    )
    assert stale.status_code == 409


def test_delete_is_soft(api: ApiEnv) -> None:
    headers = api.auth()
    created = api.client.post("/v1/items", json={"name": "a"}, headers=headers).json()
    resp = api.client.delete(f"/v1/items/{created['id']}", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "deleted"
    assert api.client.get(f"/v1/items/{created['id']}", headers=headers).status_code == 404


def test_owner_isolation(api: ApiEnv) -> None:
    created = api.client.post(
        "/v1/items", json={"name": "a"}, headers=api.auth(sub="user-a")
    ).json()
    resp = api.client.get(f"/v1/items/{created['id']}", headers=api.auth(sub="user-b"))
    assert resp.status_code == 403


def test_list_filters_deleted(api: ApiEnv) -> None:
    headers = api.auth()
    created = api.client.post("/v1/items", json={"name": "a"}, headers=headers).json()
    api.client.delete(f"/v1/items/{created['id']}", headers=headers)
    items = api.client.get("/v1/items", headers=headers).json()
    assert items == []


def test_list_combines_pages_and_filters_deleted_and_other_owners(api: ApiEnv) -> None:
    headers = api.auth(sub="user-a")
    ids = []
    for name in ("deleted-first", "second", "third"):
        created = api.client.post("/v1/items", json={"name": name}, headers=headers)
        assert created.status_code == 201
        ids.append(created.json()["id"])
    api.client.delete(f"/v1/items/{ids[0]}", headers=headers)
    api.client.post("/v1/items", json={"name": "foreign"}, headers=api.auth(sub="user-b"))

    response = api.client.get("/v1/items?limit=1", headers=headers)
    assert response.status_code == 200
    assert [item["id"] for item in response.json()] == ids[1:]
