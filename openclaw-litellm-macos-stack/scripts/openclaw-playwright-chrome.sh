#!/bin/sh
set -eu

for candidate in /home/node/.cache/ms-playwright/chromium-*/chrome-linux/chrome; do
  if [ -x "$candidate" ]; then
    exec "$candidate" "$@"
  fi
done

echo "No Playwright Chromium binary found under /home/node/.cache/ms-playwright." >&2
echo "Install one with: docker compose run --rm --entrypoint node openclaw-cli /app/node_modules/playwright-core/cli.js install chromium" >&2
exit 1
