"""Time helpers.

All timestamps are ISO-8601 UTC strings. They sort lexicographically,
which is what DynamoDB and most storage engines rely on.
"""

from __future__ import annotations

from datetime import UTC, datetime


def now_utc_iso() -> str:
    """Current UTC time as an ISO-8601 string, e.g. 2026-08-17T12:00:00.123456+00:00."""
    return datetime.now(UTC).isoformat()
