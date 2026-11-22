"""DynamoDB CRUD implementation.

Single-table design. Handles Decimal<->int/float normalization, optimistic
locking via condition expressions, soft delete, server-side pagination, batch
gets, and transactional writes.
"""
from __future__ import annotations

import base64
import json
from decimal import Decimal
from typing import Any, Sequence

import boto3
from botocore.exceptions import ClientError

from api.config import get_settings
from api.core.errors import ConflictError
from api.core.time import now_utc_iso

# Keys the CRUD owns; callers cannot overwrite them through update()
_RESERVED = frozenset({"pk", "sk", "entity_type", "id", "version"})

_INDEX_COLUMNS = {
    "gsi1": ("gsi1_pk", "gsi1_sk"),
    "gsi2": ("gsi2_pk", "gsi2_sk"),
    "gsi3": ("gsi3_pk", "gsi3_sk"),
}
_SPARSE_INDEX_COLUMNS = frozenset(column for columns in _INDEX_COLUMNS.values() for column in columns)


def _to_ddb(value: Any) -> dict[str, Any]:
    if value is None:
        return {"NULL": True}
    if isinstance(value, bool):
        return {"BOOL": value}
    if isinstance(value, int):
        return {"N": str(value)}
    if isinstance(value, float):
        return {"N": repr(value)}
    if isinstance(value, str):
        return {"S": value}
    if isinstance(value, dict):
        return {"M": {k: _to_ddb(v) for k, v in value.items()}}
    if isinstance(value, (list, tuple)):
        return {"L": [_to_ddb(v) for v in value]}
    raise TypeError(f"unsupported DynamoDB value type: {type(value)}")


def _from_ddb(value: dict[str, Any]) -> Any:
    (key, val), = value.items()
    if key == "NULL":
        return None
    if key == "BOOL":
        return val
    if key == "N":
        dec = Decimal(val)
        return int(dec) if dec == dec.to_integral_value() else float(dec)
    if key == "S":
        return val
    if key == "M":
        return {k: _from_ddb(v) for k, v in val.items()}
    if key == "L":
        return [_from_ddb(v) for v in val]
    raise TypeError(f"unsupported DynamoDB type: {key}")


def _to_item(item: dict[str, Any]) -> dict[str, Any]:
    # Sparse index keys must be absent, not DynamoDB NULL attributes.
    return {
        key: _to_ddb(value)
        for key, value in item.items()
        if value is not None or key not in _SPARSE_INDEX_COLUMNS
    }


def _from_item(item: dict[str, Any]) -> dict[str, Any]:
    return {key: _from_ddb(value) for key, value in item.items()}


def _decode_cursor(cursor: str) -> dict[str, Any]:
    return json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())


def _build_update(
    updates: dict[str, Any], expected_version: int | None
) -> tuple[str, dict[str, str], dict[str, dict[str, Any]], str | None]:
    set_parts: list[str] = []
    names: dict[str, str] = {}
    values: dict[str, dict[str, Any]] = {}
    for i, (key, val) in enumerate(updates.items()):
        names[f"#f{i}"] = key
        values[f":v{i}"] = _to_ddb(val)
        set_parts.append(f"#f{i} = :v{i}")
    names["#updated_at"] = "updated_at"
    values[":now"] = {"S": now_utc_iso()}
    names["#version"] = "version"
    values[":inc"] = {"N": "1"}
    set_parts.append("#updated_at = :now")
    set_parts.append("#version = #version + :inc")

    condition: str | None = None
    if expected_version is not None:
        names["#version_cond"] = "version"
        values[":expected"] = {"N": str(expected_version)}
        condition = "#version_cond = :expected"
    return "SET " + ", ".join(set_parts), names, values, condition


class DynamoCrud:
    def __init__(self, table_name: str | None = None, region: str | None = None) -> None:
        settings = get_settings()
        self.table_name = table_name or settings.table_main
        self.region = region or settings.region
        self._client = boto3.client("dynamodb", region_name=self.region)

    # --- reads ---

    def get(self, pk: str, sk: str) -> dict[str, Any] | None:
        resp = self._client.get_item(
            TableName=self.table_name, Key=_to_item({"pk": pk, "sk": sk})
        )
        item = resp.get("Item")
        return _from_item(item) if item else None

    def query(
        self,
        pk: str,
        sk_prefix: str = "",
        limit: int = 100,
        cursor: str | None = None,
    ) -> tuple[list[dict[str, Any]], str | None]:
        kwargs: dict[str, Any] = {
            "TableName": self.table_name,
            "KeyConditionExpression": "pk = :pk",
            "ExpressionAttributeValues": {":pk": _to_ddb(pk)},
            "Limit": limit,
        }
        if sk_prefix:
            kwargs["KeyConditionExpression"] += " AND begins_with(sk, :prefix)"
            kwargs["ExpressionAttributeValues"][":prefix"] = _to_ddb(sk_prefix)
        if cursor:
            kwargs["ExclusiveStartKey"] = _decode_cursor(cursor)
        return self._query_all(kwargs), None

    def _query_all(self, kwargs: dict[str, Any]) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        while True:
            response = self._client.query(**kwargs)
            items.extend(_from_item(item) for item in response.get("Items", []))
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                return items
            kwargs["ExclusiveStartKey"] = last_key

    def batch_get(self, keys: Sequence[tuple[str, str]]) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        ddb_keys = [_to_item({"pk": pk, "sk": sk}) for pk, sk in keys]
        for i in range(0, len(ddb_keys), 100):
            resp = self._client.batch_get_item(
                RequestItems={self.table_name: {"Keys": ddb_keys[i : i + 100]}}
            )
            results.extend(_from_item(it) for it in resp["Responses"].get(self.table_name, []))
        return results

    def query_index(
        self,
        index_name: str,
        pk: str,
        sk_prefix: str = "",
        limit: int = 100,
        cursor: str | None = None,
    ) -> tuple[list[dict[str, Any]], str | None]:
        if index_name not in _INDEX_COLUMNS:
            raise ValueError(f"unknown index: {index_name}")
        pk_col, sk_col = _INDEX_COLUMNS[index_name]
        kwargs: dict[str, Any] = {
            "TableName": self.table_name,
            "IndexName": index_name,
            "KeyConditionExpression": "#pk = :pk",
            "ExpressionAttributeNames": {"#pk": pk_col},
            "ExpressionAttributeValues": {":pk": _to_ddb(pk)},
            "Limit": limit,
        }
        if sk_prefix:
            kwargs["KeyConditionExpression"] += " AND begins_with(#sk, :prefix)"
            kwargs["ExpressionAttributeNames"]["#sk"] = sk_col
            kwargs["ExpressionAttributeValues"][":prefix"] = _to_ddb(sk_prefix)
        if cursor:
            kwargs["ExclusiveStartKey"] = _decode_cursor(cursor)
        return self._query_all(kwargs), None

    # --- writes ---

    def put(self, item: dict[str, Any]) -> dict[str, Any]:
        now = now_utc_iso()
        full = {**item, "created_at": item.get("created_at", now), "updated_at": now, "version": 0}
        try:
            self._client.put_item(
                TableName=self.table_name,
                Item=_to_item(full),
                ConditionExpression="attribute_not_exists(pk) AND attribute_not_exists(sk)",
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ConflictError(f"resource already exists: {full.get('pk')}") from exc
            raise
        return full

    def update(
        self,
        pk: str,
        sk: str,
        updates: dict[str, Any],
        expected_version: int | None,
    ) -> dict[str, Any]:
        clean = {k: v for k, v in updates.items() if k not in _RESERVED}
        expr, names, values, condition = _build_update(clean, expected_version)
        kwargs: dict[str, Any] = {
            "TableName": self.table_name,
            "Key": _to_item({"pk": pk, "sk": sk}),
            "UpdateExpression": expr,
            "ExpressionAttributeNames": names,
            "ExpressionAttributeValues": values,
            "ReturnValues": "ALL_NEW",
        }
        if condition:
            kwargs["ConditionExpression"] = condition
        try:
            resp = self._client.update_item(**kwargs)
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ConflictError("version conflict or resource missing") from exc
            raise
        return _from_item(resp["Attributes"])

    def soft_delete(self, pk: str, sk: str) -> dict[str, Any]:
        return self.update(pk, sk, {"status": "deleted"}, expected_version=None)

    def transact_write(self, operations: Sequence[dict[str, Any]]) -> None:
        transact_items: list[dict[str, Any]] = []
        for op in operations:
            kind = op["kind"]
            if kind == "put":
                transact_items.append(
                    {
                        "Put": {
                            "TableName": self.table_name,
                            "Item": _to_item(op["item"]),
                            "ConditionExpression": "attribute_not_exists(pk)",
                        }
                    }
                )
            elif kind == "update":
                clean = {k: v for k, v in op["updates"].items() if k not in _RESERVED}
                expr, names, values, condition = _build_update(clean, op.get("expected_version"))
                transact: dict[str, Any] = {
                    "TableName": self.table_name,
                    "Key": _to_item({"pk": op["pk"], "sk": op["sk"]}),
                    "UpdateExpression": expr,
                    "ExpressionAttributeNames": names,
                    "ExpressionAttributeValues": values,
                }
                if condition:
                    transact["ConditionExpression"] = condition
                transact_items.append({"Update": transact})
            elif kind == "delete":
                transact_items.append(
                    {
                        "Delete": {
                            "TableName": self.table_name,
                            "Key": _to_item({"pk": op["pk"], "sk": op["sk"]}),
                        }
                    }
                )
            else:
                raise ValueError(f"unknown transact op kind: {kind}")
        self._client.transact_write_items(TransactItems=transact_items)
