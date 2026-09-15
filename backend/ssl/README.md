# Per-install TLS materials live here at runtime.

`ensure_ssl.py` (and the Windows installer) generate a unique
`server.crt` / `server.key` for this machine on first run.

- Never commit private keys.
- Rerunning the installer reuses an existing valid pair.
- Private key ACLs are restricted on Windows when possible.
