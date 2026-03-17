# Code Review Checklist

Use this checklist for changes in the OpenClaw Docker stack and its runtime workspace.

## Priorities
- Runtime correctness and startup safety
- Secret handling and token exposure
- Config drift between runtime and template files
- Model routing regressions
- Missing verification after behavior changes

## Review for bugs
- Does the change point OpenClaw to a model alias that the current `LITELLM_API_KEY` cannot access?
- If a provider alias changed, were both catalog and inference tested?
- If a script changed generated config, was the generated file re-rendered and checked?
- If Telegram or browser behavior changed, is the user told whether a restart or `/new` is required?

## Review for regressions
- Are `config/openclaw.json` and `data/openclaw/config/openclaw.json` still aligned where they should be?
- Are `.env.example`, `README.md`, and smoke-test defaults still accurate?
- Did any old aliases remain in docs or runtime after a migration?

## Review for missing tests
- Health checks: `docker compose ps`, `readyz`, LiteLLM readiness
- Targeted inference for the changed model/provider path
- `./scripts/test-model.sh` with skips only where justified

## Output style
- Findings first, ordered by severity
- Include exact file references
- Call out residual risks or skipped checks explicitly
