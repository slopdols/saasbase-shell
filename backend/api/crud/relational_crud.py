"""Relational CRUD - future SQL implementation.

Placeholder only. Every method raises NotImplementedError so a misconfigured
backend fails loudly instead of silently corrupting data.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any, NoReturn


def _not_implemented(name: str) -> NoReturn:
    raise NotImplementedError(
        f"RelationalCrud.{name} is not implemented yet. "
        "Set SAASBASE_DB_BACKEND=dynamo to use the active backend."
    )


class RelationalCrud:
    def get(self, pk: str, sk: str) -> dict[str, Any] | None:
        _not_implemented("get")

    def query(
        self,
        pk: str,
        sk_prefix: str = "",
        limit: int = 100,
        cursor: str | None = None,
    ) -> tuple[list[dict[str, Any]], str | None]:
        _not_implemented("query")

    def batch_get(self, keys: Sequence[tuple[str, str]]) -> list[dict[str, Any]]:
        _not_implemented("batch_get")

    def query_index(
        self,
        index_name: str,
        pk: str,
        sk_prefix: str = "",
        limit: int = 100,
        cursor: str | None = None,
    ) -> tuple[list[dict[str, Any]], str | None]:
        _not_implemented("query_index")

    def put(self, item: dict[str, Any]) -> dict[str, Any]:
        _not_implemented("put")

    def update(
        self,
        pk: str,
        sk: str,
        updates: dict[str, Any],
        expected_version: int | None,
    ) -> dict[str, Any]:
        _not_implemented("update")

    def soft_delete(self, pk: str, sk: str) -> dict[str, Any]:
        _not_implemented("soft_delete")

    def transact_write(self, operations: Sequence[dict[str, Any]]) -> None:
        _not_implemented("transact_write")
