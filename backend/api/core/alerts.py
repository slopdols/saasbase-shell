"""Alerts to Telegram (or SNS in production).

Used from the error boundary and any critical business event.
Telegram is a best-effort channel - failures are swallowed, never raised.
"""

from __future__ import annotations

import asyncio
from typing import Any

import httpx

from api.config import get_settings
from api.core.logging import get_logger

logger = get_logger("alerts")


async def alert(message: str, level: str = "error", **attrs: Any) -> None:
    """Send an alert. Fire-and-forget - never raises."""
    settings = get_settings()
    token = settings.alert_telegram_bot_token
    chat_id = settings.alert_telegram_chat_id
    if not token or not chat_id:
        logger.warning("alert not sent (telegram not configured): %s", message)
        return

    text = f"[{level.upper()}] {message}"
    if attrs:
        text += "\n" + "\n".join(f"{k}={v}" for k, v in attrs.items())

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            await client.post(url, json={"chat_id": chat_id, "text": text[:4000]})
    except Exception as exc:  # noqa: BLE001 - alerts must never raise
        logger.warning("alert delivery failed: %s", exc)


def alert_async(message: str, level: str = "error", **attrs: Any) -> None:
    """Schedule an alert without blocking the request path."""
    try:
        asyncio.get_running_loop().create_task(alert(message, level, **attrs))
    except RuntimeError:
        asyncio.run(alert(message, level, **attrs))
