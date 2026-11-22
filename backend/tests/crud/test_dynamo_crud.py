"""CRUD layer tests: put/get, conflict, optimistic lock, soft delete, queries."""
from __future__ import annotations

import pytest
from botocore.exceptions import ClientError
from botocore.stub import Stubber

from api.core.errors import ConflictError
from api.crud.dynamo_crud import DynamoCrud
from api.crud.models import new_item


def test_put_and_get(crud: DynamoCrud) -> None:
    crud.put(new_item("item", "abc", name="hello"))
    fetched = crud.get("ITEM#abc", "ITEM#abc")
    assert fetched is not None
    assert fetched["name"] == "hello"
    assert fetched["version"] == 0
    assert fetched["status"] == "active"


def test_put_duplicate_raises_conflict(crud: DynamoCrud) -> None:
    crud.put(new_item("item", "abc"))
    with pytest.raises(ConflictError):
        crud.put(new_item("item", "abc"))


def test_get_missing_returns_none(crud: DynamoCrud) -> None:
    assert crud.get("ITEM#nope", "ITEM#nope") is None


def test_update_with_optimistic_lock(crud: DynamoCrud) -> None:
    crud.put(new_item("item", "abc", name="v1"))
    updated = crud.update("ITEM#abc", "ITEM#abc", {"name": "v2"}, expected_version=0)
    assert updated["name"] == "v2"
    assert updated["version"] == 1

    # Stale version must fail
    with pytest.raises(ConflictError):
        crud.update("ITEM#abc", "ITEM#abc", {"name": "v3"}, expected_version=0)


def test_touch_update_without_version(crud: DynamoCrud) -> None:
    crud.put(new_item("item", "abc", name="v1"))
    updated = crud.update("ITEM#abc", "ITEM#abc", {"name": "v2"}, expected_version=None)
    assert updated["name"] == "v2"


def test_soft_delete(crud: DynamoCrud) -> None:
    crud.put(new_item("item", "abc"))
    deleted = crud.soft_delete("ITEM#abc", "ITEM#abc")
    assert deleted["status"] == "deleted"
    assert crud.get("ITEM#abc", "ITEM#abc") is not None  # never physically removed


def test_main_key_query_with_prefix(crud: DynamoCrud) -> None:
    for i in range(3):
        crud.put(new_item("item", f"x{i}", pk="ACCOUNT#u1", sk=f"LEDGER#{i:04d}"))
    items, cursor = crud.query("ACCOUNT#u1", sk_prefix="LEDGER#")
    assert len(items) == 3
    assert cursor is None


def test_gsi_query(crud: DynamoCrud) -> None:
    for i in range(3):
        crud.put(
            new_item("item", f"id{i}", gsi1_pk="OWNER#u1", gsi1_sk=f"ITEM#ts#{i}")
        )
    items, cursor = crud.query_index("gsi1", "OWNER#u1", sk_prefix="ITEM#")
    assert len(items) == 3
    assert cursor is None


@pytest.mark.parametrize("index_name", [None, "gsi1"])
def test_query_combines_pages_beyond_one_megabyte(crud: DynamoCrud, index_name: str | None) -> None:
    for i in range(4):
        crud.put(
            new_item(
                "item",
                f"large{i}",
                pk="ACCOUNT#u1",
                sk=f"ITEM#{i}",
                gsi1_pk="OWNER#u1",
                gsi1_sk=f"ITEM#{i}",
                payload="x" * 300_000,
            )
        )
    if index_name:
        items, cursor = crud.query_index(index_name, "OWNER#u1", sk_prefix="ITEM#")
    else:
        items, cursor = crud.query("ACCOUNT#u1", sk_prefix="ITEM#")
    assert [item["id"] for item in items] == [f"large{i}" for i in range(4)]
    assert cursor is None


@pytest.mark.parametrize("index_name", [None, "gsi1"])
def test_query_follows_empty_pages_and_propagates_later_page_errors(
    crud: DynamoCrud, index_name: str | None
) -> None:
    start = {"pk": {"S": "ACCOUNT#u1"}, "sk": {"S": "ITEM#0"}}
    parameters = {
        "TableName": crud.table_name,
        "Limit": 1,
        "KeyConditionExpression": "pk = :pk",
        "ExpressionAttributeValues": {":pk": {"S": "ACCOUNT#u1"}},
    }
    if index_name:
        start.update({"gsi1_pk": {"S": "OWNER#u1"}, "gsi1_sk": {"S": "ITEM#0"}})
        parameters.update(
            {
                "IndexName": index_name,
                "KeyConditionExpression": "#pk = :pk",
                "ExpressionAttributeNames": {"#pk": "gsi1_pk"},
                "ExpressionAttributeValues": {":pk": {"S": "OWNER#u1"}},
            }
        )
    for fail in (False, True):
        with Stubber(crud._client) as stubber:
            stubber.add_response("query", {"Items": [], "LastEvaluatedKey": start}, parameters)
            continued = {**parameters, "ExclusiveStartKey": start}
            if fail:
                stubber.add_client_error(
                    "query",
                    service_error_code="ProvisionedThroughputExceededException",
                    expected_params=continued,
                )
                with pytest.raises(ClientError):
                    if index_name:
                        crud.query_index(index_name, "OWNER#u1", limit=1)
                    else:
                        crud.query("ACCOUNT#u1", limit=1)
            else:
                stubber.add_response("query", {"Items": [{"id": {"S": "later"}}]}, continued)
                if index_name:
                    items, cursor = crud.query_index(index_name, "OWNER#u1", limit=1)
                else:
                    items, cursor = crud.query("ACCOUNT#u1", limit=1)
                assert items == [{"id": "later"}]
                assert cursor is None
            stubber.assert_no_pending_responses()


def test_batch_get(crud: DynamoCrud) -> None:
    for i in range(3):
        crud.put(new_item("item", f"id{i}"))
    results = crud.batch_get([("ITEM#id0", "ITEM#id0"), ("ITEM#id1", "ITEM#id1")])
    assert len(results) == 2


def test_nested_attributes_round_trip(crud: DynamoCrud) -> None:
    details = {"enabled": True, "amount_minor": 1250, "tags": ["one", None, {"count": 2}]}
    crud.put(new_item("item", "nested", details=details))
    fetched = crud.get("ITEM#nested", "ITEM#nested")
    assert fetched is not None
    assert fetched["details"] == details
    assert "gsi1_pk" not in fetched


def test_transaction_item_and_key_shapes(crud: DynamoCrud) -> None:
    crud.put(new_item("item", "updated", name="before"))
    crud.put(new_item("item", "deleted"))
    crud.transact_write(
        [
            {"kind": "put", "item": new_item("item", "created", name="new")},
            {
                "kind": "update",
                "pk": "ITEM#updated",
                "sk": "ITEM#updated",
                "updates": {"name": "after"},
                "expected_version": 0,
            },
            {"kind": "delete", "pk": "ITEM#deleted", "sk": "ITEM#deleted"},
        ]
    )
    created = crud.get("ITEM#created", "ITEM#created")
    updated = crud.get("ITEM#updated", "ITEM#updated")
    assert created is not None and created["name"] == "new"
    assert updated is not None and updated["name"] == "after" and updated["version"] == 1
    assert crud.get("ITEM#deleted", "ITEM#deleted") is None
