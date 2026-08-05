# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Shared FastAPI dependencies and HTTP error helper utilities."""

from collections.abc import Generator

from fastapi import HTTPException
from sqlalchemy.orm import Session

from .db import SessionLocal


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def forbidden(msg: str = "Forbidden") -> HTTPException:
    return HTTPException(status_code=403, detail=msg)

def unauthorized(msg: str = "Unauthorized") -> HTTPException:
    return HTTPException(status_code=401, detail=msg)

def not_found(msg: str = "Not found") -> HTTPException:
    return HTTPException(status_code=404, detail=msg)

def bad_request(msg: str = "Bad request") -> HTTPException:
    return HTTPException(status_code=400, detail=msg)


def too_many_requests(msg: str = "Too many requests") -> HTTPException:
    return HTTPException(status_code=429, detail=msg)
