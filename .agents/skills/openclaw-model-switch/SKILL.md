---
name: openclaw-model-switch
description: Use when changing the live OpenClaw default model or model routing in the macOS Docker stack at /Users/macos/Downloads/openclaw-litellm-macos-stack. Covers LiteLLM alias exposure, provider wiring, selected-model state, gateway/session reset, and live verification. Do not use for generic debugging unrelated to model selection.
---

# OpenClaw Model Switch

Use this skill for the live stack at `/Users/macos/Downloads/openclaw-litellm-macos-stack`.

## Start Here
- Read `references/model-flow.md` before changing anything. It explains the current route matrix and the state files that can drift apart.
- For ordinary switches between models that are already exposed in OpenClaw, prefer:
  - `bash scripts/switch_openclaw_model.sh litellm/gpt-5.4`
- The script is the default path because it syncs both OpenClaw config files, sets the selected model through the CLI, recreates the gateway, optionally resets the active Telegram DM session after backup, and runs a live verification request.

## Common Cases
- Switch the default among already-exposed LiteLLM aliases:
  - `bash scripts/switch_openclaw_model.sh litellm/gpt-5.4`
- Keep the current Telegram DM session even if that risks the old model staying attached to the chat:
  - `bash scripts/switch_openclaw_model.sh litellm/gpt-5.4 --keep-main-session`
- Preview the workflow without changing files or containers:
  - `bash scripts/switch_openclaw_model.sh litellm/gpt-5.4 --dry-run`

## When To Stop And Rewire First
- If `docker compose run --rm -T openclaw-cli models status --json` does not list the target in `allowed`, do not force the switch.
- Rewire the stack first by checking:
  - `.env`
  - `scripts/render-litellm-config.py`
  - `config/litellm-config.yaml`
  - `config/openclaw.json`
  - `data/openclaw/config/openclaw.json`
  - `scripts/apply-provider-config.sh`
  - `scripts/generate-litellm-virtual-key.sh`
  - `scripts/apply-cliproxyapi.sh` when the GPT route depends on CLIProxyAPI

## Always Verify
- `docker compose ps`
- `curl -fsS http://127.0.0.1:18789/readyz`
- `docker compose run --rm -T openclaw-cli models status --json`
- A real `openclaw-cli agent --json` bootstrap, not only `/v1/models`

## Report Back
- Final selected model
- Effective provider route
- Whether `agent:main:main` was reset and whether DM context was lost
- Whether a fresh DM message is enough or the user should explicitly start a new chat session
- Any remaining risk such as missing alias wiring, stale session intentionally kept, or LiteLLM key scope mismatch
