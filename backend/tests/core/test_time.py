"""Time invariants: ISO-8601 UTC strings that sort lexicographically."""
from __future__ import annotations

from api.core.time import now_utc_iso


def test_now_utc_iso_is_iso8601_utc() -> None:
    ts = now_utc_iso()
    assert ts.endswith("+00:00")
    assert "T" in ts


def test_now_utc_iso_sorts_lexicographically() -> None:
    first = now_utc_iso()
    second = now_utc_iso()
    assert first <= second
