#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Minimal DAST-oriented smoke checks for the running backend in CI."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from email.message import Message
from http.cookiejar import CookieJar


@dataclass(frozen=True)
class HttpResponse:
    status_code: int
    headers: Message
    body: bytes

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    def json(self) -> dict[str, object]:
        return json.loads(self.text)

    def header(self, name: str) -> str:
        return self.headers.get(name, "")


def _request(
    opener: urllib.request.OpenerDirector,
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    data: bytes | None = None,
    timeout: float = 10,
) -> HttpResponse:
    request = urllib.request.Request(
        url,
        data=data,
        headers=headers or {},
        method=method,
    )
    try:
        with opener.open(request, timeout=timeout) as response:
            return HttpResponse(
                status_code=response.status,
                headers=response.headers,
                body=response.read(),
            )
    except urllib.error.HTTPError as exc:
        return HttpResponse(
            status_code=exc.code,
            headers=exc.headers,
            body=exc.read(),
        )


def _encode_json(payload: dict[str, object]) -> tuple[dict[str, str], bytes]:
    return (
        {"Content-Type": "application/json"},
        json.dumps(payload).encode("utf-8"),
    )


def _encode_multipart(
    fields: dict[str, str],
    *,
    file_field: str,
    filename: str,
    content_type: str,
    content: bytes,
) -> tuple[dict[str, str], bytes]:
    boundary = f"opsatlas-{uuid.uuid4().hex}"
    chunks: list[bytes] = []

    for key, value in fields.items():
        chunks.extend(
            [
                f"--{boundary}\r\n".encode("ascii"),
                f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("utf-8"),
                value.encode("utf-8"),
                b"\r\n",
            ]
        )

    chunks.extend(
        [
            f"--{boundary}\r\n".encode("ascii"),
            (
                f'Content-Disposition: form-data; name="{file_field}"; '
                f'filename="{filename}"\r\n'
            ).encode("utf-8"),
            f"Content-Type: {content_type}\r\n\r\n".encode("ascii"),
            content,
            b"\r\n",
            f"--{boundary}--\r\n".encode("ascii"),
        ]
    )
    body = b"".join(chunks)
    return (
        {"Content-Type": f"multipart/form-data; boundary={boundary}"},
        body,
    )


def main() -> None:
    base = "http://127.0.0.1:8000"
    failures: list[str] = []
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))

    for _ in range(60):
        try:
            health_probe = _request(opener, "GET", f"{base}/health", timeout=2)
            if health_probe.status_code == 200:
                break
        except urllib.error.URLError:
            pass
        time.sleep(1)
    else:
        failures.append("Backend failed to start for DAST smoke checks")

    health = _request(opener, "GET", f"{base}/health", timeout=10)
    if health.status_code != 200:
        failures.append(f"/health returned {health.status_code}: {health.text}")

    for header in (
        "content-security-policy",
        "x-content-type-options",
        "x-frame-options",
        "referrer-policy",
    ):
        if not health.header(header):
            failures.append(f"Missing security header: {header}")

    credentials = [
        ("admin@admin.com", "password"),
        ("moderator@moderator.com", "password"),
        ("member@member.com", "password"),
        ("viewer@viewer.com", "password"),
        ("admin@admin.com", "admin"),
        ("moderator@moderator.com", "moderator"),
        ("member@member.com", "member"),
        ("viewer@viewer.com", "viewer"),
    ]
    login: HttpResponse | None = None
    for email, password in credentials:
        headers, payload = _encode_json({"email": email, "password": password})
        response = _request(
            opener,
            "POST",
            f"{base}/auth/login",
            headers=headers,
            data=payload,
            timeout=15,
        )
        if response.status_code != 200:
            continue
        content_type = response.header("content-type")
        payload_json = response.json() if content_type.startswith("application/json") else {}
        if payload_json.get("onboarding_required") is True:
            continue
        login = response
        break

    if login is None:
        failures.append("Login failed for all seeded test users")
    else:
        set_cookie = login.header("set-cookie").lower()
        if "httponly" not in set_cookie:
            failures.append("Auth cookies must be HttpOnly")

        me = _request(opener, "GET", f"{base}/auth/me", timeout=10)
        if me.status_code != 200:
            failures.append(f"/auth/me returned {me.status_code}: {me.text}")

        upload_headers, upload_body = _encode_multipart(
            {"usage": "general"},
            file_field="file",
            filename="xss.html",
            content_type="text/html",
            content=b"<html><script>alert('xss')</script></html>",
        )
        upload = _request(
            opener,
            "POST",
            f"{base}/media/upload",
            headers=upload_headers,
            data=upload_body,
            timeout=15,
        )
        if upload.status_code not in {400, 422}:
            failures.append(f"Upload block test returned {upload.status_code}: {upload.text}")
        else:
            detail = upload.text.lower()
            if "blocked" not in detail and "not allowed" not in detail:
                failures.append(f"Upload block response missing expected detail: {upload.text}")

    if failures:
        print("DAST failures:")
        for failure in failures:
            print(f"- {failure}")
        raise SystemExit(1)

    print("DAST checks passed.")


if __name__ == "__main__":
    main()
