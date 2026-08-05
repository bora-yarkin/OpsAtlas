# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from app.core.rich_html import sanitize_rich_html


def test_sanitize_rich_html_strips_scripts_handlers_and_unsafe_protocols() -> None:
    raw = (
        '<div onclick="alert(1)">'
        '<script>alert(1)</script>'
        '<a href="javascript:alert(2)">bad</a>'
        '<a href="https://example.com" target="_blank" rel="noopener">ok</a>'
        "</div>"
    )

    sanitized = sanitize_rich_html(raw)

    lowered = sanitized.lower()
    assert "<script" not in lowered
    assert "onclick=" not in lowered
    assert "javascript:" not in lowered
    assert 'href="https://example.com"' in sanitized


def test_sanitize_rich_html_keeps_allowed_tags_and_removes_disallowed_tags() -> None:
    raw = "<p>Hello <strong>Ops</strong> <iframe src='x'></iframe></p>"

    sanitized = sanitize_rich_html(raw)

    assert "<strong>Ops</strong>" in sanitized
    assert "<iframe" not in sanitized.lower()


def test_sanitize_rich_html_returns_empty_for_none_or_whitespace() -> None:
    assert sanitize_rich_html(None) == ""
    assert sanitize_rich_html("   \n  ") == ""


def test_sanitize_rich_html_removes_null_bytes() -> None:
    sanitized = sanitize_rich_html("<p>A\x00B</p>")

    assert "\x00" not in sanitized
