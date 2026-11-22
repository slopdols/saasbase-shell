"""Domain error types.

All domain errors extend AppError. They are translated to a consistent
`{"error": {"code": ..., "message": ...}}` envelope at the single error
boundary in api/main.py. Never catch-and-swallow outside this boundary.
"""
from __future__ import annotations

from typing import Any


class AppError(Exception):
    """Base class for all expected, domain-level errors."""

    status_code: int = 400
    code: str = "app_error"

    def __init__(self, message: str, *, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.details = details or {}

    def to_dict(self) -> dict[str, Any]:
        body: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details:
            body["details"] = self.details
        return body


class NotFoundError(AppError):
    status_code = 404
    code = "not_found"


class ConflictError(AppError):
    status_code = 409
    code = "conflict"


class UnauthorizedError(AppError):
    status_code = 401
    code = "unauthorized"


class ForbiddenError(AppError):
    status_code = 403
    code = "forbidden"


class ValidationError(AppError):
    status_code = 422
    code = "validation_error"


class PaymentRequiredError(AppError):
    status_code = 402
    code = "payment_required"
