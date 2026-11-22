"""Entity types and the standard item builder.

Single-table design: every item carries a standard set of columns.
`new_item()` fills them all so callers can't forget one.
"""
from __future__ import annotations

from typing import Any

from api.core.time import now_utc_iso

# Register every entity here. Add new entities to this set.
ENTITY_TYPES: frozenset[str] = frozenset({"item"})

STANDARD_COLUMNS: tuple[str, ...] = (
    "pk",
    "sk",
    "entity_type",
    "id",
    "created_at",
    "updated_at",
    "status",
    "version",
    "gsi1_pk",
    "gsi1_sk",
    "gsi2_pk",
    "gsi2_sk",
    "gsi3_pk",
    "gsi3_sk",
)


def primary_key(entity_type: str, entity_id: str) -> tuple[str, str]:
    """Top-level item key: pk = sk = ENTITY#<id>."""
    if entity_type not in ENTITY_TYPES:
        raise ValueError(f"unknown entity type: {entity_type}")
    key = f"{entity_type.upper()}#{entity_id}"
    return key, key


def new_item(entity_type: str, entity_id: str, **fields: Any) -> dict[str, Any]:
    """Build an item with all standard columns pre-filled."""
    if entity_type not in ENTITY_TYPES:
        raise ValueError(f"unknown entity type: {entity_type}")
    pk, sk = primary_key(entity_type, entity_id)
    now = now_utc_iso()
    item: dict[str, Any] = {
        "pk": pk,
        "sk": sk,
        "entity_type": entity_type,
        "id": entity_id,
        "created_at": now,
        "updated_at": now,
        "status": "active",
        "version": 0,
        "gsi1_pk": None,
        "gsi1_sk": None,
        "gsi2_pk": None,
        "gsi2_sk": None,
        "gsi3_pk": None,
        "gsi3_sk": None,
    }
    item.update(fields)
    return item
