#!/usr/bin/env python3
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import pathlib
import re


ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_PATH = pathlib.Path.home() / ".codex" / "auth.json"
AUTH_DIR = ROOT / "data" / "cliproxyapi" / "auths"
MARKER = "openclaw-cliproxy-sync"


def decode_jwt_payload(token: str) -> dict:
    try:
        payload = token.split(".", 2)[1]
    except IndexError as exc:
        raise SystemExit(f"Invalid Codex id_token format: {exc}") from exc

    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def normalize_component(raw: str) -> str:
    value = raw.strip().lower()
    value = re.sub(r"[^a-z0-9._-]+", "-", value)
    value = re.sub(r"-{2,}", "-", value).strip("-.")
    return value or "unknown"


def build_filename(email: str, plan_type: str, account_id: str) -> str:
    digest = hashlib.sha256(account_id.encode()).hexdigest()[:8] if account_id else "unknown"
    return f"codex-{normalize_component(email)}-{normalize_component(plan_type)}-{digest}.json"


if not SOURCE_PATH.exists():
    raise SystemExit(f"Missing source Codex auth file: {SOURCE_PATH}")

source = json.loads(SOURCE_PATH.read_text())
tokens = source.get("tokens") or {}
access_token = (tokens.get("access_token") or "").strip()
refresh_token = (tokens.get("refresh_token") or "").strip()
id_token = (tokens.get("id_token") or "").strip()
account_id = (tokens.get("account_id") or "").strip()
last_refresh = (source.get("last_refresh") or "").strip()

if not access_token or not refresh_token or not id_token:
    raise SystemExit("Source Codex auth file is missing access_token / refresh_token / id_token")

claims = decode_jwt_payload(id_token)
auth_claims = claims.get("https://api.openai.com/auth") or {}
email = (claims.get("email") or "").strip()
plan_type = (auth_claims.get("chatgpt_plan_type") or "unknown").strip() or "unknown"
account_id = (auth_claims.get("chatgpt_account_id") or account_id).strip()

if not email:
    raise SystemExit("Unable to read email from Codex id_token")

exp = claims.get("exp")
expired = ""
if isinstance(exp, (int, float)) and exp > 0:
    expired = dt.datetime.fromtimestamp(exp, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")

payload = {
    "id_token": id_token,
    "access_token": access_token,
    "refresh_token": refresh_token,
    "account_id": account_id,
    "last_refresh": last_refresh or dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "email": email,
    "type": "codex",
    "expired": expired,
    "generated_by": MARKER,
    "source_path": str(SOURCE_PATH),
}

AUTH_DIR.mkdir(parents=True, exist_ok=True)
for candidate in AUTH_DIR.glob("codex-*.json"):
    try:
        existing = json.loads(candidate.read_text())
    except Exception:
        continue
    if existing.get("generated_by") == MARKER:
        candidate.unlink()

output_path = AUTH_DIR / build_filename(email, plan_type, account_id)
output_path.write_text(json.dumps(payload, indent=2) + "\n")
output_path.chmod(0o600)

print(f"Wrote {output_path}")
print(f"Email: {email}")
print(f"Plan: {plan_type}")
