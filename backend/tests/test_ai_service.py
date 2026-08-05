# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from app.modules.ai import service as ai_service


def test_strip_markdown_removes_html_blocks_and_preserves_link_labels() -> None:
    raw = """
    # Incident Guide

    <script>alert("xss")</script>
    A [refund checklist](https://example.com) should stay visible.
    ![diagram](https://example.com/diagram.png)
    ```
    noisy fenced block
    ```
    """

    cleaned = ai_service._strip_markdown(raw)

    assert "alert" not in cleaned
    assert "refund checklist" in cleaned
    assert "diagram" not in cleaned
    assert "noisy fenced block" not in cleaned


def test_keyword_extraction_handles_hyphen_heavy_input_without_empty_tokens() -> None:
    raw = ("-" * 4000) + " incident-latency refund timeout "

    tokens = ai_service._keyword_tokens(raw)

    assert "incident-latency" in tokens
    assert "refund" in tokens
    assert "timeout" in tokens
    assert all(token for token in tokens)


def test_suggest_title_trims_trailing_heading_punctuation_without_regex() -> None:
    title = ai_service.suggest_title(("Incident rollback" + ("-" * 4000)) + "\nbody")

    assert title == "Incident rollback"
