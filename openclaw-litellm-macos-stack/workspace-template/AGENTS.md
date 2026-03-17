# AGENTS.md

## Session startup
1. Read `SOUL.md`.
2. Read `USER.md`.
3. Read `memory/YYYY-MM-DD.md` for today and yesterday if they exist.
4. Read `MEMORY.md` only in the main private session with ông chủ.

## Project map
- Active Docker stack root: `/Users/macos/Downloads/openclaw-litellm-macos-stack`
- Runtime OpenClaw config: `/Users/macos/Downloads/openclaw-litellm-macos-stack/data/openclaw/config/openclaw.json`
- Template OpenClaw config: `/Users/macos/Downloads/openclaw-litellm-macos-stack/config/openclaw.json`
- LiteLLM generated config: `/Users/macos/Downloads/openclaw-litellm-macos-stack/config/litellm-config.yaml`
- Provider render logic: `/Users/macos/Downloads/openclaw-litellm-macos-stack/scripts/render-litellm-config.py`
- Primary workspace docs live here under `data/openclaw/workspace`
- Repo-local Codex skills live in `.agents/skills`
- Repo-local Codex config lives in `.codex/config.toml`

## Commands
- Stack status: `cd /Users/macos/Downloads/openclaw-litellm-macos-stack && docker compose ps`
- OpenClaw readiness: `curl -fsS http://127.0.0.1:18789/readyz`
- LiteLLM readiness: `curl -fsS http://127.0.0.1:8001/health/readiness`
- Re-render and apply provider config: `./scripts/apply-provider-config.sh`
- Rebuild CLIProxyAPI bridge path: `./scripts/apply-cliproxyapi.sh`
- Rotate LiteLLM app key: `./scripts/generate-litellm-virtual-key.sh`
- Smoke test stack: `./scripts/test-model.sh`

## Working rules
- Durable facts and stable preferences go to `MEMORY.md`.
- Daily context, progress, and temporary notes go to `memory/YYYY-MM-DD.md`.
- Prefer this response shape: diagnosis -> recommendation -> action.
- After any important write to workspace files, read the file back before claiming success.
- Keep core files short; link out to focused docs or skills instead of turning this file into a prompt dump.
- If a workflow repeats 3 or more times, turn it into a repo skill or SOP file.
- Prefer minimal diffs; preserve existing behavior unless the task explicitly changes it.
- When editing stack behavior, keep runtime config, template config, scripts, and docs aligned to avoid stale alias drift.
- Never hardcode or echo real secrets, tokens, or provider keys into tracked docs.

## Conventions
- Edit bind-mounted files on disk, not inside a running container.
- Treat `config/litellm-config.yaml` as generated output; prefer changing `.env` or `scripts/render-litellm-config.py`, then re-render.
- If a new model family or alias family is added, regenerate the LiteLLM virtual key before expecting OpenClaw to use it.
- When switching default model or provider routing, verify both catalog visibility and a real inference response.
- If a change affects Telegram behavior or session bootstrap state, tell ông chủ whether `/new` is required.

## Review expectations
- Prioritize correctness, runtime regressions, secret leakage, and stale config drift.
- Check for mismatches between:
  - runtime vs template `openclaw.json`
  - `.env` vs rendered LiteLLM config
  - allowed LiteLLM app key models vs intended OpenClaw primary model
- Use `code_review.md` when asked to review or self-review a change.

## Done means
- The requested config or behavior change is implemented in the right source of truth.
- Relevant services are healthy again.
- The affected provider/model path is tested with real requests when possible.
- Any limitations, skips, or upstream failures are stated explicitly.
- If the user-facing session needs reset, say so plainly.

## Safety / do-not
- Do not commit `.env`, auth stores, database files, or runtime device/session secrets.
- Do not switch primary model to a new alias family without checking whether `LITELLM_API_KEY` can access it.
- Do not trust `/v1/models` alone; a model showing in catalog is not enough without inference verification.
- High-risk, destructive, or outbound actions need confirmation or a dry run first.

## Reusable docs
- Review checklist: `code_review.md`
- Provider/model switching workflow: use `$openclaw-model-switch`
- Runtime smoke testing workflow: use `$openclaw-smoke-test`

## Channel rules
- DM: proactive, concise, practical.
- Group chats: protect private context, answer only when mentioned or clearly useful.
- Heartbeats: surface only blockers, deadlines, anomalies, or urgent follow-ups. Otherwise reply `HEARTBEAT_OK`.
