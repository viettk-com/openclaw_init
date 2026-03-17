---
name: openclaw-smoke-test
description: Use when validating the live OpenClaw Docker stack after config changes, provider changes, health issues, or when the user asks to test models, Telegram, readiness, or end-to-end runtime behavior. Do not use for purely static file edits with no runtime verification.
---

# OpenClaw Smoke Test

Use this skill to verify the live stack, not just the files.

## Workflow
1. Work in `/Users/macos/Downloads/openclaw-litellm-macos-stack`.
2. Start with the fast health checks:
   - `docker compose ps`
   - `curl -fsS http://127.0.0.1:18789/readyz`
   - `curl -fsS http://127.0.0.1:8001/health/readiness`
3. Use `./scripts/test-model.sh` with the narrowest useful scope:
   - full run for broad validation
   - skip unrelated providers to reduce noise
4. For any model/provider involved in the user request, run a direct targeted inference check and report the real HTTP status.
5. Distinguish clearly between:
   - model present in catalog
   - model usable with the current app key
   - model returning a successful response
6. If Telegram is in scope, note whether the current chat session may still be pinned to an older model snapshot and whether `/new` is needed.

## Reporting
- Findings should be binary where possible: `PASS`, `FAIL`, `SKIP`
- Include the exact model alias tested
- Surface upstream failures separately from local config failures
- If a check was skipped, say why
