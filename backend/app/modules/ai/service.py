# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for AI-assisted generation and suggestion features."""

import re
from collections import Counter


_STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "if", "in",
    "into", "is", "it", "its", "of", "on", "or", "that", "the", "their", "then",
    "there", "this", "to", "was", "were", "with", "while", "after", "before",
    "during", "have", "has", "had", "can", "could", "should", "would", "will",
    "we", "you", "your", "they", "our", "not", "no", "do", "does", "did",
}

_KEYWORD_BOOST = {
    "api", "backup", "incident", "latency", "release", "refund", "gateway",
    "support", "store", "inventory", "pos", "snapshot", "timeout", "deploy",
    "queue", "auth", "login", "database", "search", "analytics",
}


def _clip(text: str, n: int) -> str:
    raw = " ".join(text.split())
    if len(raw) <= n:
        return raw
    return raw[: max(0, n - 1)].rstrip() + "…"


def _strip_markdown(text: str) -> str:
    t = text.replace("\r\n", "\n")
    t = _strip_html_blocks(t, tags=("script", "style"))
    t = _strip_html_tags(t)
    t = t.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    t = _strip_fenced_code_blocks(t)
    t = _strip_inline_backticks(t)
    t = _strip_markdown_links_and_images(t)
    return "\n".join(_strip_leading_markdown_prefix(line) for line in t.split("\n"))


def _first_heading(text: str) -> str | None:
    for line in text.replace("\r\n", "\n").split("\n"):
        s = line.strip()
        if not s:
            continue
        if s.startswith("#"):
            return s.lstrip("#").strip()
    return None


def _sentences(text: str) -> list[str]:
    cleaned = _strip_markdown(text)
    parts = re.split(r"(?<=[\.\!\?])\s+|\n+", cleaned)
    return [p.strip() for p in parts if p.strip()]


def summarize_text(text: str, limit: int = 320) -> str:
    parts = _sentences(text)
    if not parts:
        return ""
    out: list[str] = []
    total = 0
    for part in parts:
        if not out and len(part) > limit:
            return _clip(part, limit)
        add_len = len(part) + (1 if out else 0)
        if total + add_len > limit:
            break
        out.append(part)
        total += add_len
        if len(out) >= 3:
            break
    return _clip(" ".join(out) if out else parts[0], limit)


def _title_case_phrase(words: list[str]) -> str:
    return " ".join(w.upper() if len(w) <= 3 else w.capitalize() for w in words)


def suggest_title(text: str, existing_title: str | None = None) -> str:
    existing = (existing_title or "").strip()
    if existing:
        return _clip(existing, 120)

    heading = _first_heading(text)
    if heading:
        return _clip(heading, 120)

    parts = _sentences(text)
    if not parts:
        return "Untitled Draft"

    first = _trim_trailing_title_punctuation(parts[0]).strip()
    if 10 <= len(first) <= 120:
        return first

    tokens = _keyword_tokens(text)
    if tokens:
        return _clip(_title_case_phrase(tokens[:6]), 120)
    return _clip(first or "Untitled Draft", 120)


def _keyword_tokens(text: str) -> list[str]:
    cleaned = _strip_markdown(text).lower()
    raw = _extract_word_tokens(cleaned)
    if not raw:
        return []
    freq: Counter[str] = Counter()
    for token in raw:
        if token in _STOPWORDS:
            continue
        if token.isdigit():
            continue
        if len(token) <= 2 and token not in {"db", "ui", "qa", "qa"}:
            continue
        score = 2 if token in _KEYWORD_BOOST else 1
        freq[token] += score
    ranked = sorted(freq.items(), key=lambda kv: (-kv[1], kv[0]))
    return [t for t, _ in ranked]


def _trim_trailing_title_punctuation(text: str) -> str:
    end = len(text)
    while end > 0 and text[end - 1] in {":", "-", "–"}:
        end -= 1
    return text[:end]


def _strip_html_blocks(text: str, *, tags: tuple[str, ...]) -> str:
    lower = text.lower()
    parts: list[str] = []
    index = 0
    while index < len(text):
        matched_tag: str | None = None
        for tag in tags:
            opener = f"<{tag}"
            if lower.startswith(opener, index):
                matched_tag = tag
                break
        if matched_tag is None:
            parts.append(text[index])
            index += 1
            continue
        closer = f"</{matched_tag}>"
        end = lower.find(closer, index + len(matched_tag) + 1)
        if end == -1:
            parts.append(" ")
            break
        parts.append(" ")
        index = end + len(closer)
    return "".join(parts)


def _strip_html_tags(text: str) -> str:
    parts: list[str] = []
    in_tag = False
    for char in text:
        if char == "<":
            in_tag = True
            parts.append(" ")
            continue
        if char == ">" and in_tag:
            in_tag = False
            continue
        if not in_tag:
            parts.append(char)
    return "".join(parts)


def _strip_fenced_code_blocks(text: str) -> str:
    parts: list[str] = []
    index = 0
    while index < len(text):
        fence = text.find("```", index)
        if fence == -1:
            parts.append(text[index:])
            break
        parts.append(text[index:fence])
        end = text.find("```", fence + 3)
        if end == -1:
            parts.append(" ")
            break
        parts.append(" ")
        index = end + 3
    return "".join(parts)


def _strip_inline_backticks(text: str) -> str:
    parts: list[str] = []
    in_code = False
    for char in text:
        if char == "`":
            in_code = not in_code
            continue
        parts.append(char)
    return "".join(parts)


def _strip_markdown_links_and_images(text: str) -> str:
    parts: list[str] = []
    index = 0
    while index < len(text):
        image = text.startswith("![", index)
        link = text.startswith("[", index)
        if not image and not link:
            parts.append(text[index])
            index += 1
            continue

        label_start = index + (2 if image else 1)
        label_end = text.find("]", label_start)
        if label_end == -1 or label_end + 1 >= len(text) or text[label_end + 1] != "(":
            parts.append(text[index])
            index += 1
            continue
        target_end = text.find(")", label_end + 2)
        if target_end == -1:
            parts.append(text[index])
            index += 1
            continue

        if image:
            parts.append(" ")
        else:
            parts.append(text[label_start:label_end])
        index = target_end + 1
    return "".join(parts)


def _strip_leading_markdown_prefix(line: str) -> str:
    index = 0
    while index < len(line) and line[index] in "#>-*+.) 0123456789":
        index += 1
    return line[index:]


def _extract_word_tokens(text: str) -> list[str]:
    tokens: list[str] = []
    current: list[str] = []
    for char in text:
        if char.isalnum() or char in {"_", "-"}:
            if not current and not char.isalnum():
                continue
            current.append(char)
            if len(current) >= 31:
                tokens.append("".join(current[:31]))
                current = []
            continue
        if len(current) >= 2:
            tokens.append("".join(current))
        current = []
    if len(current) >= 2:
        tokens.append("".join(current))
    return tokens


def suggest_tags(text: str, max_tags: int = 5) -> list[str]:
    tags: list[str] = []
    for token in _keyword_tokens(text):
        normalized = token.replace("_", "-")
        if normalized in tags:
            continue
        tags.append(normalized)
        if len(tags) >= max_tags:
            break
    return tags


def suggest_doc_metadata(text: str, existing_title: str | None = None, max_tags: int = 5) -> dict[str, object]:
    title = suggest_title(text, existing_title)
    summary = summarize_text(text, limit=320)
    tags = suggest_tags(text, max_tags=max_tags)
    return {
        "title": title,
        "summary": summary,
        "tags": tags,
    }


def draft_incident_postmortem(incident_title: str, summary_md: str, timeline_items: list[str]) -> dict[str, object]:
    clean_title = _clip(incident_title.strip(), 200)
    clean_summary = summarize_text(summary_md or incident_title, limit=380)
    timeline_lines = [f"- {item.strip()}" for item in timeline_items if item and item.strip()]
    if not timeline_lines:
        timeline_lines = [
            "- Detection: Document how the issue was first observed (alerts, customer report, manual check).",
            "- Mitigation: Record the first mitigation step and why it was chosen.",
            "- Resolution: Document the corrective change and validation steps.",
        ]

    lower = f"{incident_title} {summary_md}".lower()
    suggested_actions: list[str] = []
    if "timeout" in lower or "latency" in lower:
        suggested_actions.append("Add latency/timeout SLO alert thresholds with escalation routing.")
        suggested_actions.append("Capture p95/p99 latency dashboards in release verification checklist.")
    if "release" in lower or "deploy" in lower:
        suggested_actions.append("Add canary rollback criteria to the release SOP and require sign-off.")
    if "backup" in lower or "snapshot" in lower:
        suggested_actions.append("Load-test snapshot browsing on larger trees before promoting changes.")
    if "refund" in lower or "payment" in lower or "gateway" in lower:
        suggested_actions.append("Add retry/backoff visibility and gateway timeout alerting for refund jobs.")
    if not suggested_actions:
        suggested_actions = [
            "Add a measurable detection alert for this failure mode.",
            "Update the relevant SOP with validation and rollback criteria.",
            "Schedule a follow-up review to verify the fix under production-like load.",
        ]

    md = "\n".join(
        [
            f"# Postmortem: {clean_title}",
            "",
            "## Executive Summary",
            clean_summary or "Summarize what happened, who was affected, and the current status.",
            "",
            "## Impact",
            "- Affected users/services:",
            "- Start time (UTC):",
            "- End time (UTC):",
            "- User-visible symptoms:",
            "",
            "## Timeline (UTC)",
            *timeline_lines,
            "",
            "## Root Cause",
            "Describe the primary technical cause and contributing factors.",
            "",
            "## Detection",
            "Explain how the incident was detected and where detection lag occurred.",
            "",
            "## Mitigation and Resolution",
            "Document mitigation steps, final fix, and validation performed.",
            "",
            "## What Went Well",
            "-",
            "",
            "## What Didn't Go Well",
            "-",
            "",
            "## Action Items",
            *[f"- [ ] {item}" for item in suggested_actions],
            "",
            "## Follow-Up Verification",
            "- Owner:",
            "- Due date:",
            "- Success metric:",
        ]
    )
    return {
        "title": clean_title,
        "executive_summary": clean_summary,
        "postmortem_md": md,
        "suggested_action_items": suggested_actions,
    }
