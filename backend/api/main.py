"""FastAPI application entry point.

- Local:  `uvicorn api.main:app --reload`
- Lambda: the `handler` callable is invoked by the Lambda runtime.

One codebase, two runtimes. The same `app` object runs both ways.
"""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from mangum import Mangum

from api.config import get_settings
from api.core.alerts import alert_async
from api.core.errors import AppError
from api.core.logging import get_logger, setup_logging
from api.core.metrics import metrics_middleware
from api.routers import auth, health, items

setup_logging()
settings = get_settings()
logger = get_logger("api")

app = FastAPI(
    title="Saasbase API",
    version="0.1.0",
    docs_url=None if settings.environment == "prod" else "/docs",
)

# --- CORS (outermost) ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# --- Metrics middleware ---
@app.middleware("http")
async def metrics(request: Request, call_next):  # type: ignore[no-untyped-def]
    return await metrics_middleware(request, call_next)


# --- Error boundary: single place where all exceptions become HTTP responses ---
@app.exception_handler(AppError)
async def app_error_handler(request: Request, exc: AppError):  # type: ignore[no-untyped-def]
    return JSONResponse(status_code=exc.status_code, content={"error": exc.to_dict()})


@app.exception_handler(RequestValidationError)
async def validation_error_handler(  # type: ignore[no-untyped-def]
    request: Request, exc: RequestValidationError
):
    return JSONResponse(
        status_code=422,
        content={
            "error": {
                "code": "validation_error",
                "message": "request validation failed",
                "details": exc.errors(),
            }
        },
    )


@app.exception_handler(Exception)
async def unhandled_error_handler(request: Request, exc: Exception):  # type: ignore[no-untyped-def]
    logger.exception("unhandled error on %s %s", request.method, request.url.path, exc_info=exc)
    alert_async(f"Unhandled error on {request.method} {request.url.path}", level="error")
    return JSONResponse(
        status_code=500,
        content={"error": {"code": "internal_error", "message": "internal error"}},
    )


# --- Routers ---
app.include_router(health.router)
app.include_router(auth.router)
app.include_router(items.router)

# ASGI -> Lambda adapter (only used on AWS)
handler = Mangum(app)
