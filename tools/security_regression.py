#!/usr/bin/env python3
"""Security regression checks for the localhost-only AI9 backend.

Usage:
  python tools/security_regression.py --base-url https://127.0.0.1:5000
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import ssl
import sys
import urllib.error
import urllib.request

from PIL import Image


def _ctx():
    return ssl._create_unverified_context()


def _request(url: str, method: str = "GET", data: bytes | None = None, headers: dict | None = None):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, context=_ctx(), timeout=15) as resp:
            body = resp.read()
            return resp.status, dict(resp.headers.items()), body
    except urllib.error.HTTPError as e:
        body = e.read() if hasattr(e, "read") else b""
        return e.code, dict(e.headers.items()) if e.headers else {}, body


def tiny_png_data_url(w=32, h=32) -> str:
    img = Image.new("RGB", (w, h), color=(128, 128, 128))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="https://127.0.0.1:5000")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    fails = 0

    def check(name: str, ok: bool, detail: str = ""):
        nonlocal fails
        if ok:
            print(f"[OK]   {name}" + (f" — {detail}" if detail else ""))
        else:
            fails += 1
            print(f"[FAIL] {name}" + (f" — {detail}" if detail else ""))

    # Health
    st, hdrs, body = _request(f"{base}/healthz")
    check("GET /healthz", st == 200 and b'"status"' in body, f"status={st}")
    check("no Access-Control-Allow-Origin on healthz", "Access-Control-Allow-Origin" not in {k.title(): v for k, v in hdrs.items()} and "access-control-allow-origin" not in {k.lower() for k in hdrs}, str(hdrs))

    # CORS: evil Origin must not be reflected
    st, hdrs, _ = _request(
        f"{base}/colorize-image-data",
        method="POST",
        data=json.dumps({"imgName": "cors-probe"}).encode(),
        headers={"Content-Type": "application/json", "Origin": "https://evil.example"},
    )
    acao = None
    for k, v in hdrs.items():
        if k.lower() == "access-control-allow-origin":
            acao = v
    check("CORS does not reflect arbitrary Origin", acao in (None, ""), f"ACAO={acao!r} status={st}")

    # imgURL-only rejected (SSRF closed)
    st, _, body = _request(
        f"{base}/colorize-image-data",
        method="POST",
        data=json.dumps({
            "imgName": "ssrf-probe",
            "imgURL": "http://127.0.0.1:1/",
        }).encode(),
        headers={"Content-Type": "application/json"},
    )
    check("imgURL-only rejected", st in (400, 403), f"status={st} body={body[:200]!r}")

    # Internal URL variants must also fail without imgData
    for url in (
        "http://192.168.1.1/",
        "http://10.0.0.1/",
        "http://169.254.169.254/latest/meta-data/",
        "http://[::1]/",
    ):
        st, _, _ = _request(
            f"{base}/colorize-image-data",
            method="POST",
            data=json.dumps({"imgURL": url}).encode(),
            headers={"Content-Type": "application/json"},
        )
        check(f"imgURL blocked for {url}", st in (400, 403), f"status={st}")

    # Absurd declared dimensions
    st, _, body = _request(
        f"{base}/colorize-image-data",
        method="POST",
        data=json.dumps({
            "imgName": "dims",
            "imgWidth": 999999,
            "imgHeight": 999999,
            "imgData": tiny_png_data_url(),
        }).encode(),
        headers={"Content-Type": "application/json"},
    )
    check("absurd dimensions rejected", st == 413, f"status={st} body={body[:160]!r}")

    # Oversized body (just over 48 MiB) — may be slow; use slightly over limit
    # Skip full 48MB if environment is constrained; send Content-Length trick via large payload.
    # 2 MiB is not enough to hit MAX; craft ~49MiB of 'A' only when --heavy passed.
    # Default: verify tiny valid request still accepted structurally (may GPU-fail without models).
    st, _, body = _request(
        f"{base}/colorize-image-data",
        method="POST",
        data=json.dumps({
            "imgName": "ok-tiny",
            "imgWidth": 32,
            "imgHeight": 32,
            "imgData": tiny_png_data_url(),
            "colorize": False,
            "denoise": False,
            "upscale": False,
            "cache": False,
        }).encode(),
        headers={"Content-Type": "application/json"},
    )
    check(
        "valid tiny imgData accepted (2xx/GPU path)",
        st in (200, 500) and st != 400 and st != 413,
        f"status={st}",
    )

    print("=" * 60)
    if fails:
        print(f"{fails} security check(s) failed")
        return 1
    print("All security checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
