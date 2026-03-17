#!/bin/sh
set -eu

find /home/node/.openclaw/browser -type l \
  \( -name 'SingletonLock' -o -name 'SingletonSocket' -o -name 'SingletonCookie' \) \
  -delete 2>/dev/null || true

find /home/node/.openclaw/browser -type f \
  \( -name 'SingletonLock' -o -name 'SingletonSocket' -o -name 'SingletonCookie' \) \
  -delete 2>/dev/null || true

exec node dist/index.js gateway --bind "${OPENCLAW_GATEWAY_BIND:-lan}" --port 18789
