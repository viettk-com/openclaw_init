# OpenClaw Model Flow

This reference explains how the current macOS Docker stack decides which model actually handles a request, and why changing one file is not enough.

## Stack Root

- `/Users/macos/Downloads/openclaw-litellm-macos-stack`

## Current Data Plane

1. OpenClaw chooses a default model from `agents.defaults.model.primary`.
2. If that model starts with `litellm/`, OpenClaw sends an OpenAI-style request to the LiteLLM provider defined in:
   - `/Users/macos/Downloads/openclaw-litellm-macos-stack/config/openclaw.json`
   - `/Users/macos/Downloads/openclaw-litellm-macos-stack/data/openclaw/config/openclaw.json`
3. LiteLLM resolves the alias from:
   - `/Users/macos/Downloads/openclaw-litellm-macos-stack/config/litellm-config.yaml`
4. LiteLLM forwards the request to the real upstream provider chosen by that alias.
5. If the model starts with `claude-cli/`, the request does not go through LiteLLM.

## Current Route Matrix

| OpenClaw target | Path after OpenClaw | Real upstream today |
| --- | --- | --- |
| `litellm/gpt-5.4` | LiteLLM alias `gpt-5.4` | CLIProxyAPI -> Codex OAuth -> OpenAI-compatible GPT-5.4 |
| `litellm/gpt-5.3-codex` | LiteLLM alias `gpt-5.3-codex` | CLIProxyAPI -> Codex OAuth |
| `litellm/MiniMax-M2.5` | LiteLLM alias `MiniMax-M2.5` | MiniMax direct |
| `litellm/MiniMax-M2.1` | LiteLLM alias `MiniMax-M2.1` | MiniMax direct |
| `litellm/dlg-*` | LiteLLM alias family | DangLamGiau marketplace |
| `litellm/claudible-*` | LiteLLM alias family | Claudible marketplace |
| `claude-cli/sonnet` | Claude CLI provider | Claude CLI runtime, bypasses LiteLLM |
| `claude-cli/opus` | Claude CLI provider | Claude CLI runtime, bypasses LiteLLM |

## Important Hidden Detail

LiteLLM currently also contains direct OpenAI deployments named `openai-gpt-5-4`, built from `OPENAI_API_KEY`, `OPENAI_API_KEY_2`, and any extra numbered keys. Those deployments exist in LiteLLM, but OpenClaw does not currently expose them in its own model catalog, so OpenClaw cannot switch to them until the catalog is updated too.

The generated LiteLLM config also exposes `codex-oauth-gpt-5-4` and `codex-oauth-gpt-5-3-codex`, but OpenClaw currently uses the shorter aliases `gpt-5.4` and `gpt-5.3-codex`.

## Files And State Stores

These layers look similar but do different jobs:

- `.env`
  - Holds provider toggles, API bases, and secrets.
  - Controls whether DangLamGiau, Claudible, CLIProxyAPI, MiniMax, or extra OpenAI keys are even available to the generator.
- `scripts/render-litellm-config.py`
  - Converts `.env` into the generated alias map in `config/litellm-config.yaml`.
  - This is the real source of truth for LiteLLM alias wiring.
- `config/litellm-config.yaml`
  - Generated runtime alias map that LiteLLM actually serves.
  - Tells you where `gpt-5.4`, `MiniMax-M2.5`, `dlg-*`, and `claudible-*` really go.
- `config/openclaw.json`
  - Template model catalog and default for the repo.
  - Should stay aligned with runtime so future rebuilds do not drift back.
- `data/openclaw/config/openclaw.json`
  - Runtime OpenClaw config mounted into the gateway and CLI container.
  - This is the live catalog/default file that the running stack sees.
- `docker compose run --rm -T openclaw-cli models status --json`
  - The most reliable quick check for the current selected default and allowed model IDs.
  - If this disagrees with the JSON files, trust this command first and investigate why.
- `data/openclaw/config/agents/main/agent/models.json`
  - Provider catalog and auth cache for the main agent.
  - Important for metadata and credentials, but not the authoritative selected default.
- `data/openclaw/config/agents/main/sessions/sessions.json`
  - Active session mapping store.
  - Can keep `agent:main:main` attached to an old model even after the default changed.
- `oc-openclaw-gateway` process memory
  - The gateway can keep stale state in memory until it is force-recreated.

## Why Switching The JSON File Alone Fails

Changing `openclaw.json` only updates one layer:

- OpenClaw may still have a different selected model state reported by `openclaw-cli models status`.
- The gateway may keep the old state in memory.
- The active DM session in `sessions.json` may keep reusing the old session bootstrap.

This is how the stack can show `gpt-5.4` in config while a fresh DM still starts on `MiniMax-M2.5`.

## Current Known Failure Signature

The recent `500` problem was not a broken `gpt-5.4` route. The stale DM session was still booting `MiniMax-M2.5`, and LiteLLM was failing mid-stream on that path. That means:

- A `500` after a model switch can be a stale session problem, not a bad new model.
- Verifying with a separate non-delivered CLI session is useful, but it does not guarantee the Telegram DM mapping has been reset.

## Switching Rules

### Case 1: Switch between models that already exist in `allowed`

Use the skill script:

- `bash scripts/switch_openclaw_model.sh litellm/gpt-5.4`

What it should do:

1. Confirm the target exists in `models status --json`.
2. Sync both OpenClaw JSON files so template and runtime stay aligned.
3. Run `openclaw-cli models set`.
4. Force-recreate `openclaw-gateway`.
5. Back up and optionally reset `agent:main:main` in `sessions.json`.
6. Verify with a real `agent --json` request.

### Case 2: Target model is missing from `allowed`

Do not switch yet. First update the wiring:

1. Adjust provider env in `.env`.
2. Update alias generation in `scripts/render-litellm-config.py` if needed.
3. Re-render or run `scripts/apply-provider-config.sh`.
4. If a new alias family needs LiteLLM access scope, rotate the app key with `scripts/generate-litellm-virtual-key.sh`.
5. Update both OpenClaw JSON files so the target is visible to OpenClaw.
6. Then run the normal switch workflow.

## Provider Notes

- `gpt-5.4` and `gpt-5.3-codex` currently depend on CLIProxyAPI, not direct OpenAI.
- `MiniMax-*` are direct LiteLLM -> MiniMax routes.
- `dlg-*` and `claudible-*` are OpenAI-compatible marketplace routes that depend on both enable flags and their own API base/key pairs.
- `claude-cli/*` do not use LiteLLM, so changing them is more about OpenClaw model selection and local Claude auth than LiteLLM alias wiring.

## LiteLLM Key Scope

Even when the alias exists, the OpenClaw-side `LITELLM_API_KEY` must still be allowed to use that model family. If you add a new family and the model is visible in config but requests still fail with auth or allowlist style errors, regenerate the virtual key.

## What To Report After A Switch

- Selected model in `models status --json`
- Effective route for that model
- Whether the gateway was recreated
- Whether `agent:main:main` was reset
- Whether the next Telegram DM will continue the old context or start fresh
