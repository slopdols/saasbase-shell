"""Pluggable backend factory.

Reads settings.db_backend and returns the active CRUD implementation.
The rest of the codebase imports from crud.py, never from here directly.
"""
from __future__ import annotations

from functools import lru_cache
from typing import Any

from api.config import get_settings
from api.crud.dynamo_crud import DynamoCrud
from api.crud.relational_crud import RelationalCrud


@lru_cache
def get_crud() -> Any:
    settings = get_settings()
    if settings.db_backend == "relational":
        return RelationalCrud()
    return DynamoCrud(table_name=settings.table_main, region=settings.region)
