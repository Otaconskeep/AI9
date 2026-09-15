#!/usr/bin/env python3
"""Ensure a unique per-install TLS cert/key exist under backend/ssl/.

Idempotent: if a usable server.crt + server.key already exist, leave them alone.
Never logs private key material.
"""

from __future__ import annotations

import datetime as _dt
import ipaddress
import os
import subprocess
import sys
from pathlib import Path


def _ssl_dir(explicit: Path | None = None) -> Path:
    if explicit is not None:
        return explicit
    return Path(__file__).resolve().parent / "ssl"


def has_usable_pair(ssl_dir: Path) -> bool:
    crt = ssl_dir / "server.crt"
    key = ssl_dir / "server.key"
    if not crt.is_file() or not key.is_file():
        return False
    if crt.stat().st_size < 100 or key.stat().st_size < 100:
        return False
    # Reject empty / placeholder files
    key_head = key.read_bytes()[:32]
    if b"BEGIN" not in key_head and b"PRIVATE" not in key_head:
        # Still accept binary/DER-ish keys if non-trivial size; OpenSSL PEM is normal.
        if len(key_head) < 16:
            return False
    return True


def _try_restrict_acl(path: Path) -> None:
    """Best-effort private-key ACL lock on Windows; no-op elsewhere."""
    if os.name != "nt":
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return
    try:
        user = os.environ.get("USERNAME") or os.environ.get("USER") or ""
        if not user:
            return
        # Remove inherited grants; allow only current user full control.
        subprocess.run(
            ["icacls", str(path), "/inheritance:r", f"/grant:r", f"{user}:F"],
            check=False,
            capture_output=True,
            text=True,
        )
    except Exception:
        pass


def generate_self_signed(ssl_dir: Path) -> None:
    ssl_dir.mkdir(parents=True, exist_ok=True)
    crt = ssl_dir / "server.crt"
    key = ssl_dir / "server.key"

    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
    except ImportError:
        # Fallback: openssl CLI if present
        openssl = "openssl"
        cmd = [
            openssl, "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "825",
            "-nodes",
            "-keyout", str(key),
            "-out", str(crt),
            "-subj", "/CN=AI9-Manga-Colorizer/O=Otaconskeep/C=US",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ]
        subprocess.run(cmd, check=True, capture_output=True)
        _try_restrict_acl(key)
        return

    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "AI9-Manga-Colorizer"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Otaconskeep"),
        x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
    ])
    now = _dt.datetime.now(tz=_dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - _dt.timedelta(minutes=1))
        .not_valid_after(now + _dt.timedelta(days=825))
        .add_extension(
            x509.SubjectAlternativeName([
                x509.DNSName("localhost"),
                x509.IPAddress(ipaddress.IPv4Address("127.0.0.1")),
            ]),
            critical=False,
        )
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(private_key, hashes.SHA256())
    )

    key.write_bytes(
        private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    crt.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    _try_restrict_acl(key)
    try:
        os.chmod(crt, 0o644)
    except OSError:
        pass


def ensure_ssl(ssl_dir: Path | None = None) -> tuple[Path, Path]:
    directory = _ssl_dir(ssl_dir)
    if not has_usable_pair(directory):
        generate_self_signed(directory)
    if not has_usable_pair(directory):
        raise RuntimeError(f"Failed to create TLS materials under {directory}")
    return directory / "server.crt", directory / "server.key"


def main() -> int:
    ssl_dir = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
    crt, key = ensure_ssl(ssl_dir)
    # Do not print key path contents — only confirm filenames.
    print(f"[OK] TLS ready: {crt.name} + {key.name} under {crt.parent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
