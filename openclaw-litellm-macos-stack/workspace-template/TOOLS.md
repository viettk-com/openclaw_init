# TOOLS.md

## Local operating notes
- Active OpenClaw runtime is the Docker stack at `/Users/macos/Downloads/openclaw-litellm-macos-stack`.
- Runtime config lives at `data/openclaw/config/openclaw.json`.
- Runtime workspace lives at `data/openclaw/workspace`.
- Edit bind-mounted files on disk, then restart `oc-openclaw-gateway` to reload config.
- After major workspace edits, start a fresh chat or ask ông chủ to send `/new` so bootstrap cache cannot stay stale.
- Repo-local Codex skills live under `.agents/skills`.
- Repo-local Codex config defaults live under `.codex/config.toml`.
- Review guidance for `/review` lives in `code_review.md`.
