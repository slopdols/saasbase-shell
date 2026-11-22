"""Metrics middleware.

Emits one CloudWatch EMF JSON line per request. CloudWatch Logs parses
EMF lines into metrics automatically. The route template is used, never
the raw path (keeps metric cardinality bounded).
"""

from __future__ import annotations

import json
import time
from collections.abc import Awaitable, Callable
from typing import Any

from starlette.requests import Request
from starlette.responses import Response

from api.core.logging import get_logger

logger = get_logger("metrics")

METRIC_NAMESPACE = "Saasbase"
SERVICE_NAME = "saasbase-api"


async def metrics_middleware(
    request: Request, call_next: Callable[[Request], Awaitable[Response]]
) -> Response:
    start = time.perf_counter()
    response = await call_next(request)
    duration_ms = round((time.perf_counter() - start) * 1000, 2)

    route = request.scope.get("route")
    route_template = getattr(route, "path", None) if route else None
    if route_template is None:
        route_template = request.url.path

    emf: dict[str, Any] = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": METRIC_NAMESPACE,
                    "Dimensions": [["method", "route"]],
                    "Metrics": [{"Name": "Latency", "Unit": "Milliseconds"}],
                }
            ],
        },
        "method": request.method,
        "route": route_template,
        "status": response.status_code,
        "Latency": duration_ms,
    }
    logger.info(json.dumps(emf))
    return response
