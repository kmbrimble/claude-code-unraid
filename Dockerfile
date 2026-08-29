FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux git curl ca-certificates python3 openssh-client jq \
      docker.io \
      openjdk-17-jdk-headless adb fastboot unzip \
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

# Unpinned, so it's the layer most likely to need deliberate invalidation
# when a new Claude Code release should be picked up. Kept below the larger
# baked layers (apt, ttyd, Playwright deps, cmdline-tools) so busting it only
# costs re-running this one small layer, not dragging any of those down too.
RUN npm install -g @anthropic-ai/claude-code claude-auto-retry

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
COPY scripts/android-sdk-bootstrap.sh /usr/local/lib/android-sdk-bootstrap.sh
RUN chmod +x /usr/local/lib/android-sdk-bootstrap.sh

WORKDIR /projects

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
