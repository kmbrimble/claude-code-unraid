FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux git curl ca-certificates python3 openssh-client jq \
      docker.io \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (for autonomous push and build-watching)
RUN apt-get update && apt-get install -y --no-install-recommends wget \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# ttyd static binary (browser-based terminal). Pinned version for reproducibility.
RUN wget -qO /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 \
    && chmod +x /usr/local/bin/ttyd

# Chromium's OS-level shared libraries (glib, nss, atk, ...), so Playwright
# can launch Chromium without a per-session `apt-get`/`install-deps`. Only
# the OS deps are installed here — the Playwright npm package and browser
# binary are NOT baked in, so each project's own package.json/npx pins the
# Playwright version it actually wants; only its browser download at test
# time lands in ~/.cache/ms-playwright (on the persisted home mount).
RUN npx --yes playwright install-deps chromium \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code claude-auto-retry

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

COPY scripts/claude-wrapper.sh /usr/local/lib/claude-wrapper.sh
COPY scripts/remote-control-launch.sh /usr/local/lib/remote-control-launch.sh

WORKDIR /projects

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
