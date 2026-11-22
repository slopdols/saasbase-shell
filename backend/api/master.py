"""Business-critical defaults.

These are DEFAULTS ONLY - every value is overridable via config/env/Secrets.
Placeholder values for a generic shell; replace with real business rules
when the product is defined.
"""

from __future__ import annotations

# Pricing (integer minor units - NEVER floats)
DEFAULT_PRICE_MINOR: int = 0
DEFAULT_CURRENCY: str = "USD"

# Revenue split in basis points (e.g. 500 = 5%)
DEFAULT_SPLIT_BPS: int = 0

# Per-user limits
DEFAULT_MAX_ITEMS_PER_USER: int = 1000
