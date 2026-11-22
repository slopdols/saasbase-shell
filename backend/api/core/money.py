"""Money helpers.

Rule: money is ALWAYS an integer in minor units (cents/centavos), paired
with an ISO-4217 currency code. Never floats. Convert for display ONLY.
"""
from __future__ import annotations


def to_minor(amount: int, currency: str) -> int:
    """Ensure an amount is an integer in minor units. Rejects floats."""
    if not isinstance(amount, int):
        raise TypeError(f"money must be an integer in minor units, got {type(amount)}")
    return amount


def format_minor(minor: int, currency: str = "USD") -> str:
    """Format minor units for display. Division by 100 happens ONLY here."""
    if not isinstance(minor, int):
        raise TypeError("money must be an integer in minor units")
    units = minor // 100
    cents = abs(minor) % 100
    return f"{currency} {units}.{cents:02d}"
