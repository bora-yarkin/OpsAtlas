# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Sanitization and normalization helpers for rich HTML content."""

from __future__ import annotations

import bleach

_ALLOWED_TAGS = [
    "a",
    "abbr",
    "b",
    "blockquote",
    "br",
    "code",
    "del",
    "div",
    "em",
    "h1",
    "h2",
    "h3",
    "h4",
    "hr",
    "i",
    "img",
    "li",
    "ol",
    "p",
    "pre",
    "s",
    "span",
    "strong",
    "sub",
    "sup",
    "table",
    "tbody",
    "td",
    "th",
    "thead",
    "tr",
    "u",
    "ul",
]

_ALLOWED_ATTRIBUTES: dict[str, list[str]] = {
    "a": ["href", "title", "target", "rel"],
    "img": ["src", "alt", "title", "width", "height"],
    "th": ["colspan", "rowspan"],
    "td": ["colspan", "rowspan"],
}

_ALLOWED_PROTOCOLS = ["http", "https", "mailto", "tel", "data"]


def sanitize_rich_html(value: str | None) -> str:
    raw = (value or "").strip()
    if not raw:
        return ""
    sanitized = bleach.clean(
        raw,
        tags=_ALLOWED_TAGS,
        attributes=_ALLOWED_ATTRIBUTES,
        protocols=_ALLOWED_PROTOCOLS,
        strip=True,
        strip_comments=True,
    )
    return sanitized.replace("\x00", "").strip()
