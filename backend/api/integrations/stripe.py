"""Stripe integration - skeleton.

Stripe is the source of truth for money. Only Stripe webhooks may set
`payment_status=paid`. Fill in checkout/Connect flows once defined.
"""
from __future__ import annotations

import stripe

from api.config import get_settings
from api.core.logging import get_logger

logger = get_logger("stripe")


def get_stripe() -> stripe.StripeClient | None:
    """Return a configured Stripe client, or None if not configured."""
    settings = get_settings()
    if not settings.stripe_secret_key:
        return None
    return stripe.StripeClient(settings.stripe_secret_key)
