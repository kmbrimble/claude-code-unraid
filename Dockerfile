FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Docker CLI: this container only ever needs the CLIENT (it talks to the
# unRAID host's much newer daemon over the mounted /var/run/docker.sock and
# must never run its own daemon). Debian bookworm's `docker.io` ships a stale
# 20.10 client that predates `docker compose`/`docker buildx` v2 plugin
# syntax, so pull the client + plugins from Docker's own apt repo instead —
# deliberately NOT `docker-ce`/`containerd.io`/`docker-ce-rootless-extras`,
# which are the daemon.
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux git curl ca-certificates python3 openssh-client jq procps \
      openjdk-17-jdk-headless adb fastboot unzip \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce-cli docker-compose-plugin docker-buildx-plugin \
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

# Android cmdline-tools (sdkmanager), pinned version. Baked at /opt, NOT under
# /root, because /root is bind-mounted from the persisted appdata home at
# runtime and would shadow anything the image put there (see issue #9). The
# actual SDK platform/build-tools packages are NOT downloaded here (multi-GB)
# — scripts/android-sdk-bootstrap.sh installs those into the persisted
# ANDROID_SDK_ROOT on container start, so they survive image rebuilds instead
# of re-downloading every time.
RUN mkdir -p /opt/android-cmdline-tools \
    && curl -fsSL -o /tmp/cmdline-tools.zip \
         https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
    && unzip -q /tmp/cmdline-tools.zip -d /opt/android-cmdline-tools \
    && mv /opt/android-cmdline-tools/cmdline-tools /opt/android-cmdline-tools/latest \
    && rm /tmp/cmdline-tools.zip

# PAL MCP server: a non-Claude code-review advisor (consensus, codereview,
# precommit, challenge) wired to AWS Bedrock ap-southeast-2 as an
# OpenAI-compatible custom provider. Baked at /opt, NOT /root — same
# reasoning as the Android cmdline-tools above: /root is bind-mounted from
# the persisted appdata home at runtime and would shadow anything the image
# wrote there. SHA-pinned clone (not a tag/branch — a tag can be force-moved
# upstream and a branch drifts by definition) of the upstream
# BeehiveInnovations/pal-mcp-server repo (renamed from zen-mcp-server; the
# old URL redirects). Git only — NEVER PyPI: the `pal-mcp-server` PyPI
# project is a separate, apparently name-squatted release line (10.5.0, no
# author, no project_urls, no continuity with GitHub's 9.x line). Upstream's
# `mcp>=1.0.0` is unpinned and resolves to `mcp==2.1.1`, which removes
# `Server.list_tools` and crashes PAL at import, so deps are installed
# --no-deps from the committed pal-requirements.lock.txt (which pins
# mcp==1.29.1 explicitly) rather than resolved fresh, and the SHA-pinned
# clone is installed separately, also --no-deps, since it's already exactly
# what the lock file was generated against.
RUN apt-get update && apt-get install -y --no-install-recommends python3.11-venv \
    && rm -rf /var/lib/apt/lists/*
COPY pal-requirements.lock.txt /opt/pal-mcp/pal-requirements.lock.txt
RUN git clone https://github.com/BeehiveInnovations/pal-mcp-server.git /opt/pal-mcp/src \
    && cd /opt/pal-mcp/src \
    && git checkout fa78edca0b6bc04ab00ddf5694d855f1b946b87d \
    && python3 -m venv /opt/pal-mcp/venv \
    && /opt/pal-mcp/venv/bin/pip install --no-cache-dir --no-deps \
         -r /opt/pal-mcp/pal-requirements.lock.txt \
    && /opt/pal-mcp/venv/bin/pip install --no-cache-dir --no-deps /opt/pal-mcp/src

# custom_models.default.json is the image-baked seed for the roster PAL
# reads at /root/.claude/pal/custom_models.json on the persisted home mount
# — entrypoint.sh copies it there only if that file is absent, so Kieren can
# edit the roster without a rebuild and it survives one.
COPY pal/custom_models.default.json /opt/pal-mcp/custom_models.default.json

# Non-secret PAL config. CUSTOM_API_KEY is deliberately NOT set here — it
# comes only from the CA template at runtime (templates/claude-code.xml) so
# it is never baked into the image, and PAL reads it straight from the
# process environment. CUSTOM_MODELS_CONFIG_PATH must be an absolute path: a
# relative default would resolve against the stdio server's CWD, which is
# not /opt/pal-mcp. DISABLED_TOOLS trims PAL's 18 tools down to the ones
# worth exposing as a second opinion; `version`/`listmodels` are hardcoded
# ESSENTIAL_TOOLS in PAL's server.py and cannot be disabled, so 6 tools stay
# live regardless of this list.
ENV CUSTOM_API_URL=https://bedrock-runtime.ap-southeast-2.amazonaws.com/openai/v1
ENV CUSTOM_MODEL_NAME=zai.glm-5
ENV CUSTOM_MODELS_CONFIG_PATH=/root/.claude/pal/custom_models.json
ENV DEFAULT_MODEL=auto
ENV DISABLED_TOOLS=chat,clink,thinkdeep,planner,debug,secaudit,docgen,analyze,refactor,tracer,testgen,apilookup
ENV LOG_LEVEL=INFO

# Security scanners for the `code-security-audit` skill. GitHub's own scanning
# only covers repos that build through Actions, and not all of these do, so the
# scanners have to run locally in this container or those repos are silently
# unscanned. All four are pinned; the three static binaries are SHA256-verified
# on download, because an unverified curl-to-/usr/local/bin is exactly the
# supply-chain shape this repo already got bitten by once (the name-squatted
# `pal-mcp-server` PyPI project).
#
# Chosen 4 Sep 2026 after measuring the alternatives:
#   * osv-scanner over trivy/grype — covers npm, PyPI, Maven/Gradle and Composer
#     in one binary, and its offline DB is 212 MB against trivy's 1.28 GB and
#     grype's 2.03 GB. That DB is NOT baked: it lives on the persisted home
#     mount, because baking it guarantees it is stale the day after the build.
#   * trufflehog over gitleaks — on a clean corpus gitleaks produced 6 findings
#     and all 6 were false positives from its `generic-api-key` rule, every one
#     a SECRET_KEY example in documentation; trufflehog returned 0 on the same
#     bytes. Run it with `--no-verification` to keep it fully offline.
#   * semgrep CE over opengrep — opengrep is 45 MB against semgrep's 348 MB, but
#     opengrep's own rules repo was archived in Nov 2025 with no successor, so it
#     ends up vendoring semgrep-rules and depending on the same licence anyway.
#     NOTE: Semgrep's maintained rules left open source on 13 Dec 2024 (Semgrep
#     Rules License v1.0). Internal scanning of our own repos is the explicitly
#     permitted case; offering the rules as a service is not.
#   * checkov deliberately NOT installed — 258 MB to run 47 Dockerfile checks,
#     of which 2 fired on a realistic Dockerfile, and it missed a hardcoded
#     `ENV API_KEY` that hadolint caught. Revisit if Terraform or K8s appears.
#
# Baked at /opt, never under /root — /root is bind-mounted from the persisted
# appdata home at runtime and would shadow anything the image wrote there (same
# reasoning as PAL and the Android cmdline-tools above).
RUN set -eux; \
    curl -fsSL -o /tmp/osv-scanner \
      https://github.com/google/osv-scanner/releases/download/v2.5.1/osv-scanner_linux_amd64; \
    echo "f9f25499a2c8cc367b3af45df2ea7eeca7fbccceab9c35079968f4b3652194be  /tmp/osv-scanner" | sha256sum -c -; \
    install -m 0755 /tmp/osv-scanner /usr/local/bin/osv-scanner; \
    curl -fsSL -o /tmp/trufflehog.tar.gz \
      https://github.com/trufflesecurity/trufflehog/releases/download/v3.97.4/trufflehog_3.97.4_linux_amd64.tar.gz; \
    echo "dc24007c2f233bd61c05beabeb44aa27ea9b43288166279209abe0458c5ce76b  /tmp/trufflehog.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/trufflehog.tar.gz -C /tmp trufflehog; \
    install -m 0755 /tmp/trufflehog /usr/local/bin/trufflehog; \
    curl -fsSL -o /tmp/hadolint \
      https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-Linux-x86_64; \
    echo "c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507  /tmp/hadolint" | sha256sum -c -; \
    install -m 0755 /tmp/hadolint /usr/local/bin/hadolint; \
    rm -f /tmp/osv-scanner /tmp/trufflehog /tmp/trufflehog.tar.gz /tmp/hadolint

# semgrep CE in its own venv at /opt, exposed via a symlink rather than by
# putting the venv's bin on PATH (which would shadow python3/pip for every
# session in this container).
RUN python3 -m venv /opt/semgrep/venv \
    && /opt/semgrep/venv/bin/pip install --no-cache-dir semgrep==1.176.0 \
    && ln -s /opt/semgrep/venv/bin/semgrep /usr/local/bin/semgrep

# semgrep phones home by default and this container should not. --metrics=off is
# also passed explicitly by the skill; this is the belt to that braces.
ENV SEMGREP_SEND_METRICS=off

# Unpinned, so it's the layer most likely to need deliberate invalidation
# when a new Claude Code release should be picked up. Kept below the larger
# baked layers (apt, ttyd, Playwright deps, cmdline-tools, PAL) so busting it
# only costs re-running this one small layer, not dragging any of those down
# too.
RUN npm install -g @anthropic-ai/claude-code claude-auto-retry

# claude-code-connector: MCP server (Streamable HTTP) that lets Claude Cowork
# drive the `claude` CLI in this container. Source is vendored at connector/;
# built here into /opt (NOT under /root, which is shadowed by the persisted
# home bind-mount at runtime). Lockfile-pinned, so this layer is stable.
# Started by entrypoint.sh, and only when CONNECTOR_TOKEN is set.
WORKDIR /opt/claude-code-connector
COPY connector/package.json connector/package-lock.json connector/tsconfig.json ./
COPY connector/src ./src
RUN npm ci --no-audit --no-fund && npm run build && npm prune --omit=dev
EXPOSE 8765

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
# ANDROID_SDK_ROOT/GRADLE_USER_HOME live on the persisted home mount (/root)
# so the downloaded SDK components and Gradle's dependency cache survive
# container rebuilds. platform-tools is put ahead of apt's adb on PATH so the
# SDK's adb wins once bootstrapped (apt's adb is only the cold-start
# fallback) — mismatched adb client/server versions refuse to talk to each
# other.
ENV ANDROID_SDK_ROOT=/root/.android-sdk
ENV ANDROID_HOME=${ANDROID_SDK_ROOT}
ENV GRADLE_USER_HOME=/root/.gradle
ENV PATH="${ANDROID_SDK_ROOT}/platform-tools:/opt/android-cmdline-tools/latest/bin:${JAVA_HOME}/bin:${PATH}"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

COPY scripts/claude-wrapper.sh /usr/local/lib/claude-wrapper.sh
COPY scripts/remote-control-launch.sh /usr/local/lib/remote-control-launch.sh
COPY scripts/remote-log-cap.sh /usr/local/lib/remote-log-cap.sh
COPY scripts/android-sdk-bootstrap.sh /usr/local/lib/android-sdk-bootstrap.sh
RUN chmod +x /usr/local/lib/android-sdk-bootstrap.sh

WORKDIR /projects

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
