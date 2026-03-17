---
name: openclaw-model-switch
description: Use when changing OpenClaw default models, LiteLLM aliases, provider routing, CLIProxyAPI model exposure, or any task that touches `.env`, `render-litellm-config.py`, `openclaw.json`, or LiteLLM app-key rotation. Do not use for generic debugging that does not alter model/provider wiring.
---

# OpenClaw Model Switch

Follow this workflow when changing model or provider routing for the live stack.

## Inputs
- Desired target model or alias
- Whether this is a direct provider path, a LiteLLM alias change, or a CLIProxyAPI routing change

## Workflow
1. Work in `/Users/macos/Downloads/openclaw-litellm-macos-stack`.
2. Inspect current state before editing:
   - `docker compose ps`
   - `curl -fsS http://127.0.0.1:18789/readyz`
   - `curl -fsS http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_API_KEY"` if the current app key is valid
3. Change the real source of truth first:
   - `.env` for provider variables and default model env choices
   - `scripts/render-litellm-config.py` for alias generation logic
   - `config/openclaw.json` and `data/openclaw/config/openclaw.json` for OpenClaw model catalog/defaults
4. If LiteLLM config generation changed, run `python3 scripts/render-litellm-config.py` or `./scripts/apply-provider-config.sh`.
5. If a new alias family or access scope is needed, run `./scripts/generate-litellm-virtual-key.sh`, update `.env` with the new `LITELLM_API_KEY`, then recreate `openclaw-gateway` and `openclaw-cli`.
6. Verify both layers:
   - Catalog visibility in LiteLLM
   - A real inference request against the new target model
7. Re-check health:
   - `docker compose ps`
   - `readyz`
   - LiteLLM readiness
8. If Telegram or session bootstrap behavior changed, update today's memory note and tell the user whether `/new` is required.

## Do not
- Do not rely on `/v1/models` alone.
- Do not leave runtime and template `openclaw.json` out of sync.
- Do not claim success before health and inference both pass.

## Output
- State the final default model
- State whether a new LiteLLM app key was generated
- State whether Telegram needs `/new`
- State exactly what passed and what remains risky
