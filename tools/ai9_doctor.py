#!/usr/bin/env python3
"""AI9 install doctor — quick post-install / troubleshooting checks.

Usage (from the install root, or pass --root):
  python tools/ai9_doctor.py
  python tools/ai9_doctor.py --root C:\\opt\\manga-colorizer
"""

from __future__ import annotations

import argparse
import hashlib
import json
import socket
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path


PLACEHOLDER_HASHES = {"", "PENDING", "pending", "TODO", "todo"}


def _ok(msg: str) -> None:
    print(f"[OK]   {msg}")


def _warn(msg: str) -> None:
    print(f"[WARN] {msg}")


def _fail(msg: str) -> None:
    print(f"[FAIL] {msg}")


def resolve_root(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser().resolve()
    here = Path(__file__).resolve()
    # tools/ai9_doctor.py inside an install tree -> parent is install root
    # or repo checkout when run from source (parent of tools/).
    return here.parent.parent


def load_checksums(backend: Path) -> dict:
    path = backend / "checksums.json"
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        _warn(f"checksums.json unreadable: {exc}")
        return {}


def expected_sha256(checksums: dict, key: str) -> str:
    files = checksums.get("files") or {}
    entry = files.get(key) or {}
    return str(entry.get("sha256") or "").strip()


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def check_gpu() -> bool:
    try:
        import torch
    except Exception as exc:
        _fail(f"torch not importable: {exc}")
        return False
    if not torch.cuda.is_available():
        _fail("torch.cuda.is_available() is False")
        return False
    try:
        name = torch.cuda.get_device_name(0)
        x = torch.zeros(64, device="cuda")
        y = x + 1
        _ = float(y.sum().item())
        _ok(f"GPU usable via CUDA ({name})")
        return True
    except Exception as exc:
        _fail(f"GPU probe failed: {exc}")
        return False


def check_models(backend: Path, checksums: dict) -> bool:
    assets = [
        ("generator.zip", backend / "networks" / "generator.zip"),
        ("RealESRGAN_x4plus_anime_6B.pt", backend / "networks" / "RealESRGAN_x4plus_anime_6B.pt"),
        ("denoising/models/net_rgb.pth", backend / "denoising" / "models" / "net_rgb.pth"),
    ]
    all_ok = True
    for key, path in assets:
        if not path.is_file():
            _fail(f"missing model asset: {path}")
            all_ok = False
            continue
        expected = expected_sha256(checksums, key)
        if expected in PLACEHOLDER_HASHES:
            _ok(f"{key}: present (sha256 not published yet)")
            continue
        digest = file_sha256(path)
        if digest.lower() != expected.lower():
            _fail(f"{key}: sha256 mismatch (got {digest}, expected {expected})")
            all_ok = False
        else:
            _ok(f"{key}: present and sha256 matches")
    return all_ok


def check_port(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=2.0):
            _ok(f"port {port} accepts TCP connections on {host}")
            return True
    except OSError as exc:
        _fail(f"port {port} on {host} not accepting connections: {exc}")
        return False


def check_healthz(base_url: str) -> bool:
    ctx = ssl._create_unverified_context()
    url = base_url.rstrip("/") + "/healthz"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, context=ctx, timeout=5) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            data = json.loads(body)
            if data.get("status") == "up":
                _ok(f"/healthz OK (gpuLoaded={data.get('gpuLoaded')}, device={data.get('device')})")
                return True
            _fail(f"/healthz unexpected payload: {data}")
            return False
    except Exception as exc:
        _fail(f"/healthz failed: {exc}")
        return False


def check_extension_note(root: Path) -> None:
    manifest = root / "extension" / "manifest.json"
    if manifest.is_file():
        _warn(
            "Firefox extension cannot be auto-installed; load Temporary Add-on "
            f"from: {manifest}"
        )
        _warn(
            "Browser integration status: not_ready (unsigned temporary extension; "
            "must be reloaded after each Firefox restart)."
        )
    else:
        _fail(f"extension manifest missing: {manifest}")


def main() -> int:
    parser = argparse.ArgumentParser(description="AI9 install doctor")
    parser.add_argument("--root", default=None, help="Install root (default: parent of tools/)")
    parser.add_argument("--host", default="127.0.0.1", help="Backend host to probe")
    parser.add_argument("--port", type=int, default=5000, help="Backend port")
    parser.add_argument(
        "--base-url",
        default=None,
        help="Override health base URL (default https://HOST:PORT)",
    )
    args = parser.parse_args()

    root = resolve_root(args.root)
    backend = root / "backend"
    checksums = load_checksums(backend)
    base_url = args.base_url or f"https://{args.host}:{args.port}"

    print(f"AI9 doctor — root={root}")
    print("=" * 60)

    results = []
    results.append(check_gpu())
    results.append(check_models(backend, checksums))
    results.append(check_port(args.host, args.port))
    results.append(check_healthz(base_url))
    check_extension_note(root)

    print("=" * 60)
    if all(results):
        print("Doctor summary: core checks passed (browser integration still not_ready).")
        return 0
    print("Doctor summary: one or more core checks failed.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
