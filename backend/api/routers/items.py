"""Generic item CRUD endpoints.

Thin handlers: validate with Pydantic, call the service, return a shaped view.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Query

from api.auth.caller import Caller
from api.auth.deps import require_caller
from api.schemas.items import ItemCreate, ItemUpdate, ItemView
from api.services import items as items_service

router = APIRouter(prefix="/v1/items", tags=["items"])


@router.post("", status_code=201, response_model=ItemView)
def create_item(body: ItemCreate, caller: Caller = Depends(require_caller)) -> dict[str, Any]:
    return items_service.create_item(caller.sub, body.name)


@router.get("", response_model=list[ItemView])
def list_items(
    caller: Caller = Depends(require_caller),
    cursor: str | None = None,
    limit: int = Query(
        default=100, ge=1, le=500, description="DynamoDB batch size; all pages are returned."
    ),
) -> list[dict[str, Any]]:
    items, _ = items_service.list_items(caller.sub, cursor=cursor, limit=limit)
    return items


@router.get("/{item_id}", response_model=ItemView)
def get_item(item_id: str, caller: Caller = Depends(require_caller)) -> dict[str, Any]:
    return items_service.get_item(item_id, caller.sub)


@router.put("/{item_id}", response_model=ItemView)
def update_item(
    item_id: str,
    body: ItemUpdate,
    caller: Caller = Depends(require_caller),
) -> dict[str, Any]:
    updates = {k: v for k, v in body.model_dump().items() if k != "version" and v is not None}
    return items_service.update_item(item_id, caller.sub, updates, expected_version=body.version)


@router.delete("/{item_id}", response_model=ItemView)
def delete_item(item_id: str, caller: Caller = Depends(require_caller)) -> dict[str, Any]:
    return items_service.delete_item(item_id, caller.sub)
