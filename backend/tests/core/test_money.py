"""Money invariants: integer minor units, NEVER floats."""
from __future__ import annotations

import pytest

from api.core.money import format_minor, to_minor


def test_to_minor_accepts_int() -> None:
    assert to_minor(100, "USD") == 100


def test_to_minor_rejects_float() -> None:
    with pytest.raises(TypeError):
        to_minor(10.5, "USD")  # type: ignore[arg-type]


def test_format_minor_divides_by_100_for_display_only() -> None:
    assert format_minor(1234, "USD") == "USD 12.34"
    assert format_minor(5, "USD") == "USD 0.05"


def test_format_minor_rejects_float() -> None:
    with pytest.raises(TypeError):
        format_minor(1.5)  # type: ignore[arg-type]
