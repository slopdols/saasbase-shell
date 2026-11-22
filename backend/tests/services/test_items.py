"""Item service business logic tests (CRUD orchestration)."""
from __future__ import annotations

from api.crud.dynamo_crud import DynamoCrud
from api.services import items as items_service


def test_create_list_get_flow(crud: DynamoCrud) -> None:
    created = items_service.create_item("user-1", "hello")
    assert created["status"] == "active"
    assert created["version"] == 0

    listed, cursor = items_service.list_items("user-1")
    assert len(listed) == 1
    assert listed[0]["id"] == created["id"]
    assert cursor is None

    fetched = items_service.get_item(created["id"], "user-1")
    assert fetched["name"] == "hello"


def test_update_increments_version(crud: DynamoCrud) -> None:
    created = items_service.create_item("user-1", "a")
    updated = items_service.update_item(created["id"], "user-1", {"name": "b"}, 0)
    assert updated["name"] == "b"
    assert updated["version"] == 1


def test_delete_hides_from_list(crud: DynamoCrud) -> None:
    created = items_service.create_item("user-1", "a")
    items_service.delete_item(created["id"], "user-1")
    items, _ = items_service.list_items("user-1")
    assert items == []


def test_list_returns_active_items_after_deleted_pages(crud: DynamoCrud) -> None:
    deleted = items_service.create_item("user-1", "deleted")
    expected = [items_service.create_item("user-1", name) for name in ("second", "third")]
    items_service.delete_item(deleted["id"], "user-1")
    items_service.create_item("user-2", "foreign")

    items, cursor = items_service.list_items("user-1", limit=1)
    assert [item["id"] for item in items] == [item["id"] for item in expected]
    assert cursor is None
