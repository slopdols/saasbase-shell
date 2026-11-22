"""Pydantic request/response models for the generic item entity."""
from __future__ import annotations

from pydantic import BaseModel, Field


class ItemCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)


class ItemUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    # Expected version for optimistic locking. Client must send the version
    # it last saw; mismatches produce a 409 Conflict.
    version: int = Field(ge=0)


class ItemView(BaseModel):
    id: str
    name: str
    status: str
    owner_sub: str
    created_at: str
    updated_at: str
    version: int
