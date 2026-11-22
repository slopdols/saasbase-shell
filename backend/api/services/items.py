"""Item service - business logic for the generic item entity.

Routers are thin; ALL logic lives here. This service demonstrates the
CRUD layer: create (put), read (get), list (gsi1 query), update (optimistic
lock), delete (soft delete).
"""
from __future__ import annotations

import uuid
from typing import Any

from api.core.errors import ForbiddenError, NotFoundError
from api.core.time import now_utc_iso
from api.crud import crud
from api.crud.models import new_item, primary_key


def _key(item_id: str) -> tuple[str, str]:
    return primary_key("item", item_id)


def create_item(caller_sub: str, name: str) -> dict[str, Any]:
    item_id = uuid.uuid4().hex
    now = now_utc_iso()
    item = new_item(
        "item",
        item_id,
        name=name,
        owner_sub=caller_sub,
        gsi1_pk=f"OWNER#{caller_sub}",
        gsi1_sk=f"ITEM#{now}#{item_id}",
    )
    return crud.put_resource(item)


def get_item(item_id: str, caller_sub: str) -> dict[str, Any]:
    pk, sk = _key(item_id)
    item = crud.get_resource(pk, sk)
    if not item or item["status"] == "deleted":
        raise NotFoundError("item not found")
    _ensure_owner(item, caller_sub)
    return item


def list_items(
    caller_sub: str, cursor: str | None = None, limit: int = 100
) -> tuple[list[dict[str, Any]], str | None]:
    items, next_cursor = crud.query_index(
        "gsi1", f"OWNER#{caller_sub}", sk_prefix="ITEM#", limit=limit, cursor=cursor
    )
    # Soft-deleted items still exist in the GSI; never surface them.
    active = [i for i in items if i.get("status") != "deleted"]
    return active, next_cursor


def update_item(
    item_id: str, caller_sub: str, updates: dict[str, Any], expected_version: int
) -> dict[str, Any]:
    pk, sk = _key(item_id)
    existing = crud.get_resource(pk, sk)
    if not existing or existing["status"] == "deleted":
        raise NotFoundError("item not found")
    _ensure_owner(existing, caller_sub)
    return crud.update_resource(pk, sk, updates, expected_version=expected_version)


def delete_item(item_id: str, caller_sub: str) -> dict[str, Any]:
    pk, sk = _key(item_id)
    existing = crud.get_resource(pk, sk)
    if not existing or existing["status"] == "deleted":
        raise NotFoundError("item not found")
    _ensure_owner(existing, caller_sub)
    return crud.delete_resource(pk, sk)


def _ensure_owner(item: dict[str, Any], caller_sub: str) -> None:
    if item.get("owner_sub") and item["owner_sub"] != caller_sub:
        raise ForbiddenError("item belongs to another user")
