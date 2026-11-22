"""Public CRUD API.

The rest of the codebase never knows which database backend is active.
Call these functions - they dispatch to the active backend via backend_flag.
"""
from __future__ import annotations

from typing import Any

from api.crud.backend_flag import get_crud


def get_resource(pk: str, sk: str) -> dict[str, Any] | None:
    return get_crud().get(pk, sk)


def put_resource(item: dict[str, Any]) -> dict[str, Any]:
    return get_crud().put(item)


def update_resource(
    pk: str,
    sk: str,
    updates: dict[str, Any],
    expected_version: int,
) -> dict[str, Any]:
    """Atomic update with optimistic locking. Fails with ConflictError if version mismatches."""
    return get_crud().update(pk, sk, updates, expected_version=expected_version)


def delete_resource(pk: str, sk: str) -> dict[str, Any]:
    """Soft delete: set status='deleted'. Rows are never physically removed."""
    return get_crud().soft_delete(pk, sk)


def query_resources(
    pk: str,
    sk_prefix: str = "",
    limit: int = 100,
    cursor: str | None = None,
) -> tuple[list[dict[str, Any]], str | None]:
    """Collect all DynamoDB pages; limit is per request, cursor is an optional start key."""
    return get_crud().query(pk, sk_prefix=sk_prefix, limit=limit, cursor=cursor)


def query_index(
    index_name: str,
    pk: str,
    sk_prefix: str = "",
    limit: int = 100,
    cursor: str | None = None,
) -> tuple[list[dict[str, Any]], str | None]:
    """Collect all sparse GSI pages. Limit controls each request, not total results."""
    return get_crud().query_index(index_name, pk, sk_prefix=sk_prefix, limit=limit, cursor=cursor)


def batch_get_resources(keys: list[tuple[str, str]]) -> list[dict[str, Any]]:
    return get_crud().batch_get(keys)


def transact_write(operations: list[dict[str, Any]]) -> None:
    """Atomic multi-item write (all-or-nothing)."""
    get_crud().transact_write(operations)


def touch_resource(pk: str, sk: str, updates: dict[str, Any]) -> dict[str, Any]:
    """Update WITHOUT optimistic locking. For non-critical fields only."""
    return get_crud().update(pk, sk, updates, expected_version=None)
