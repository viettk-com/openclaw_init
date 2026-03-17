ARG OPENCLAW_BASE_IMAGE=ghcr.io/openclaw/openclaw:latest
FROM ${OPENCLAW_BASE_IMAGE}

ARG CLAUDE_CODE_TARGET=stable

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      libnspr4 \
      libnss3 \
      libatk1.0-0 \
      libatk-bridge2.0-0 \
      libdbus-1-3 \
      libcups2 \
      libxkbcommon0 \
      libatspi2.0-0 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxrandr2 \
      libgbm1 \
      libasound2 \
    && rm -rf /var/lib/apt/lists/*

USER node

ENV PATH="/home/node/.local/bin:${PATH}"

RUN mkdir -p /home/node/.local/bin /home/node/.claude \
    && curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_TARGET}" \
    && test -x /home/node/.local/bin/claude \
    && /home/node/.local/bin/claude --version

USER root

RUN ln -sf /home/node/.local/bin/claude /usr/local/bin/claude

USER node
