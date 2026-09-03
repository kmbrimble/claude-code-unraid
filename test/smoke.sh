#!/usr/bin/env bash
# Container smoke-test harness. Builds the image, runs it, and checks that
# expected tooling is present and the container stops promptly on SIGTERM.
set -uo pipefail

TAG="claude-code-smoketest:local"
NAME="cc-smoketest"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="$(mktemp -d)"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker rmi "$TAG" >/dev/null 2>&1
  rm -rf "$HOME_DIR"
}
trap cleanup EXIT

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Structural checks on the CI workflow and Dockerfile — static, no build
# needed, so run them first and cheaply. These guard the registry-backed
# Docker layer cache (the default `docker` driver silently ignores registry
# cache without buildx) and the npm layer's position (unpinned, so it's the
# layer most likely to need deliberate invalidation; keeping it after the
# ~130MB Android cmdline-tools RUN means busting it doesn't drag that layer
# down too).
WORKFLOW="$REPO_ROOT/.github/workflows/build.yml"
check "workflow sets up buildx" bash -c "grep -q 'docker/setup-buildx-action' '$WORKFLOW'"
check "workflow reads layer cache from buildcache tag" bash -c \
  "grep -q 'cache-from' '$WORKFLOW' && grep -q 'buildcache' '$WORKFLOW'"
check "workflow writes layer cache to buildcache tag" bash -c \
  "grep -q 'cache-to' '$WORKFLOW' && grep -q 'buildcache' '$WORKFLOW'"
check "npm install -g line sits after the Android cmdline-tools RUN block" bash -c "
  NPM_LINE=\$(grep -n 'npm install -g @anthropic-ai/claude-code' '$REPO_ROOT/Dockerfile' | head -1 | cut -d: -f1)
  CMDLINE_LINE=\$(grep -n 'Android cmdline-tools' '$REPO_ROOT/Dockerfile' | head -1 | cut -d: -f1)
  [ -n \"\$NPM_LINE\" ] && [ -n \"\$CMDLINE_LINE\" ] && [ \"\$NPM_LINE\" -gt \"\$CMDLINE_LINE\" ]
"

echo "Building image $TAG from $REPO_ROOT..."
if ! docker build -t "$TAG" "$REPO_ROOT"; then
  echo "FAIL"
  exit 1
fi

echo "Starting container $NAME..."
# /root is bind-mounted from an empty host directory, matching a fresh unRAID
# appdata home directory on first run: the real deployment's /root is a bind
# mount from /mnt/user/appdata/claude-code/home, which shadows every dotfile
# the image bakes into /root (including the base image's own ~/.profile) —
# a bind mount shows exactly what's on the host, unlike a named Docker volume
# (which Docker pre-populates from the image on first use, masking this).
# Without this, the smoke test's /root falls back to the image's baked
# filesystem, which masks bugs that only show up against an empty persisted
# home (issue #9).
CONNECTOR_TOKEN="smoketest-token"
if ! docker run -d --name "$NAME" -v "$HOME_DIR:/root" -e CONNECTOR_TOKEN="$CONNECTOR_TOKEN" "$TAG" >/dev/null; then
  echo "FAIL"
  exit 1
fi

sleep 3

check "gh present" docker exec "$NAME" gh --version
check "node present" docker exec "$NAME" node -v
check "git present" docker exec "$NAME" git --version
check "tmux present" docker exec "$NAME" tmux -V
check "ttyd present" docker exec "$NAME" ttyd --version

# This container only ever needs a Docker CLIENT (it talks to the unRAID
# host's daemon over the mounted socket) but Debian bookworm's `docker.io`
# ships a 20.10 client that predates the `docker compose`/`docker buildx` v2
# plugin syntax — confirmed to break a Cowork session driving this container.
# Must be the official Docker CE apt repo's client + plugins instead.
DOCKER_VERSION_OUTPUT=$(docker exec "$NAME" docker --version 2>&1)
DOCKER_MAJOR=$(echo "$DOCKER_VERSION_OUTPUT" | grep -oP 'Docker version \K[0-9]+' | head -1)
if [ -n "$DOCKER_MAJOR" ] && [ "$DOCKER_MAJOR" -ge 27 ]; then
  echo "PASS: docker CLI major version >= 27 ($DOCKER_VERSION_OUTPUT)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: docker CLI major version >= 27 (got: $DOCKER_VERSION_OUTPUT)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
check "docker compose plugin present" docker exec "$NAME" docker compose version
check "docker buildx plugin present" docker exec "$NAME" docker buildx version

# claude-auto-retry's monitor.js only forks when its getCurrentPane() finds a
# non-empty $TMUX_PANE. Because entrypoint.sh creates the `claude` tmux session
# directly (not via claude-auto-retry's own createTmuxSession()), that variable
# is not set for free — entrypoint.sh must explicitly export it into the
# session's environment. If this regresses, `tmux show-environment` reports
# "variable not found" instead of a pane id like "%0", so check for that
# distinction rather than just a non-empty match.
TMUX_PANE_VALUE=$(docker exec "$NAME" tmux show-environment -t claude TMUX_PANE 2>&1)
if [[ "$TMUX_PANE_VALUE" == TMUX_PANE=%* ]]; then
  echo "PASS: TMUX_PANE set in claude tmux session ($TMUX_PANE_VALUE)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: TMUX_PANE not set in claude tmux session (got: $TMUX_PANE_VALUE)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

check "claude-wrapper.sh present in image" docker exec "$NAME" test -f /usr/local/lib/claude-wrapper.sh
check "~/.bashrc sources claude-wrapper.sh" docker exec "$NAME" grep -q "claude-wrapper.sh" /root/.bashrc

# tmux starts a pane's shell as a LOGIN shell (`-bash`), which reads
# ~/.bash_profile / ~/.profile, never ~/.bashrc — so the ~/.bashrc checks
# above are necessary but not sufficient: they'd still pass even if the
# wrapper function never actually loads in the real pane (issue #9). This is
# the behavioural check that catches that: it runs a real login shell and
# confirms the `claude` wrapper function is actually defined in it.
check "claude wrapper function loads in a login shell" \
  docker exec "$NAME" bash -lc 'declare -f claude >/dev/null'

# `declare -f` only proves the function is defined, not that it actually
# runs. The real bug (issue: claude() silently no-ops under non-interactive
# stdin) only shows up when it's invoked: `script -c` runs its command via
# $SHELL, which falls back to dash outside a tmux pane, where the exported
# bash function _claude_auto_retry isn't visible — so it failed with no
# output and exit 0. `docker exec` without `-t` gives non-TTY stdin, matching
# how this wrapper is actually driven non-interactively (headless jobs,
# scripts). Assert real output, real success, and the absence of the dash
# error string.
check "claude wrapper: claude --version runs non-interactively and succeeds" \
  docker exec "$NAME" bash -c '
    out=$(bash -lc "claude --version" 2>&1)
    code=$?
    [ "$code" -eq 0 ] &&
    echo "$out" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+" &&
    ! echo "$out" | grep -q "_claude_auto_retry: not found"
  '

# `script` without `-e` returns its own exit status, not the wrapped
# command's, so failures were invisible to any caller. Override
# _claude_auto_retry (the function claude() delegates to) to return a known
# non-zero code and confirm it survives all the way back out through the
# wrapper.
check "claude wrapper: non-zero exit status propagates" \
  docker exec "$NAME" bash -c '
    bash -lc "_claude_auto_retry() { return 7; }; claude foo; exit \$?"
    [ $? -eq 7 ]
  '

# procps (ps/free/top/pgrep) was missing from the image, forcing triage to
# parse /proc by hand.
check "ps, free and top are present and runnable" docker exec "$NAME" bash -c \
  'ps --version >/dev/null && free -m >/dev/null && top -bn1 >/dev/null'

# Remote Control auto-launch: entrypoint.sh scans /projects subdirectories
# and starts a detached `claude remote-control` for each one containing a
# CLAUDE.md, skipping the rest. A real `claude remote-control` needs auth and
# opens a live connection, so this exercises the discovery/launch logic in
# isolation (scripts/remote-control-launch.sh) against a stub `claude` on
# $PATH, rather than a real session.
check "remote-control auto-launch targets only CLAUDE.md dirs" \
  docker exec "$NAME" bash -c '
    set -e
    tmp=$(mktemp -d)
    mkdir -p "$tmp/projects/withmd" "$tmp/projects/withoutmd" "$tmp/stubbin" "$tmp/logs"
    echo "# test project" > "$tmp/projects/withmd/CLAUDE.md"
    cat > "$tmp/stubbin/claude" <<STUB
#!/bin/sh
echo "\$PWD \$*" >> "$tmp/stub-calls.log"
STUB
    chmod +x "$tmp/stubbin/claude"
    export PATH="$tmp/stubbin:$PATH"
    source /usr/local/lib/remote-control-launch.sh
    launch_remote_control_sessions "$tmp/projects" "$tmp/logs"
    sleep 1
    grep -q "withmd remote-control" "$tmp/stub-calls.log" &&
    ! grep -q "withoutmd" "$tmp/stub-calls.log" 2>/dev/null
  '

# Remote Control repaints its status banner to stdout roughly once a second
# via cursor-up escapes, which only overwrite in a real TTY — against a log
# file every repaint just appends, so left alone these grow unbounded
# (791MB/7 days observed live). scripts/remote-log-cap.sh's cap_remote_control_logs
# must shrink an oversized log in place: this tests the real entry point (its
# actual head/tail split, not hand-picked proportions) against a fixture
# directory, honouring REMOTE_CONTROL_LOG_MAX_BYTES so a 20MB file needn't be
# generated. It asserts the shrink happens on the SAME inode (`stat -c %i`
# unchanged) since the session process holds an open O_APPEND fd on the log —
# an mv/rm-based approach would leave it writing to a detached, now-invisible
# inode — and that a second pass over an already-capped log is a no-op: if
# head+marker+tail could still land over the cap, every 300s cycle would
# rewrite every oversized log in full forever (see commit 13dc655's bug).
check "remote-log-cap caps a real log via cap_remote_control_logs, keeps head, same inode, idempotent" \
  docker exec "$NAME" bash -c '
    set -e
    source /usr/local/lib/remote-log-cap.sh
    export REMOTE_CONTROL_LOG_MAX_BYTES=$((1024*1024))
    dir="/tmp/fixture-remote-dir"
    rm -rf "$dir" && mkdir -p "$dir"
    tmp="$dir/proj.log"
    { echo "HEAD-MARKER-LAUNCH-LINE"
      for i in $(seq 1 200000); do echo "repeated status banner line $i"; done
    } > "$tmp"
    before_inode=$(stat -c %i "$tmp")
    before_size=$(stat -c %s "$tmp")
    cap_remote_control_logs "$dir"
    after_inode=$(stat -c %i "$tmp")
    after_size=$(stat -c %s "$tmp")
    after_content=$(cat "$tmp")
    cap_remote_control_logs "$dir"
    after2_inode=$(stat -c %i "$tmp")
    after2_size=$(stat -c %s "$tmp")
    after2_content=$(cat "$tmp")
    [ "$before_size" -gt "$REMOTE_CONTROL_LOG_MAX_BYTES" ] &&
    [ "$after_size" -lt "$before_size" ] &&
    [ "$after_size" -lt "$REMOTE_CONTROL_LOG_MAX_BYTES" ] &&
    [ "$after_inode" -eq "$before_inode" ] &&
    head -1 "$tmp" | grep -q "HEAD-MARKER-LAUNCH-LINE" &&
    [ "$after2_size" -eq "$after_size" ] &&
    [ "$after2_inode" -eq "$after_inode" ] &&
    [ "$after2_content" = "$after_content" ]
  '

# Chromium's OS-level shared libraries must be baked into the image so
# Playwright/Chromium runs without a per-session `apt-get`/`install-deps`.
# This downloads the Chromium *browser binary* via npx (not baked into the
# image — see Dockerfile comment) and launches it headless; on an image
# missing the OS deps this fails with an "error while loading shared
# libraries" / "cannot open shared object file" error from the dynamic linker.
PLAYWRIGHT_VERSION="1.62.1"
check "playwright chromium OS deps" docker exec "$NAME" bash -c \
  "npx --yes playwright@${PLAYWRIGHT_VERSION} install chromium >/tmp/pw-install.log 2>&1 && \
   npx --yes playwright@${PLAYWRIGHT_VERSION} screenshot about:blank /tmp/pw-smoke.png >/tmp/pw-screenshot.log 2>&1"

# Android toolchain: JDK, adb and sdkmanager must be present and report sane
# versions. These are baked into the image (apt for JDK/adb, a cmdline-tools
# launcher outside the /root bind mount for sdkmanager), so they must survive
# even against the empty persisted-home mount this test uses.
check "java present" docker exec "$NAME" java -version
check "adb present" docker exec "$NAME" adb --version
# sdkmanager (this cmdline-tools version) requires --sdk_root explicitly on
# every invocation, including --version — it does not read ANDROID_SDK_ROOT.
check "sdkmanager present" docker exec "$NAME" bash -c \
  'sdkmanager --version --sdk_root="$ANDROID_SDK_ROOT"'

# ANDROID_SDK_ROOT and GRADLE_USER_HOME must be set and point at existing,
# writable paths under the persisted home mount (/root), so the SDK/Gradle
# caches survive a container rebuild instead of re-downloading every time.
check "ANDROID_SDK_ROOT set and writable" docker exec "$NAME" bash -c \
  '[ -n "$ANDROID_SDK_ROOT" ] && [ -d "$ANDROID_SDK_ROOT" ] && [ -w "$ANDROID_SDK_ROOT" ]'
check "GRADLE_USER_HOME set and writable" docker exec "$NAME" bash -c \
  '[ -n "$GRADLE_USER_HOME" ] && [ -d "$GRADLE_USER_HOME" ] && [ -w "$GRADLE_USER_HOME" ]'

# The SDK components themselves (platform 34, build-tools) are NOT baked into
# the image (multi-GB) — they're installed into the persisted home mount by
# an idempotent bootstrap script on first run. Run it synchronously here
# (rather than relying on entrypoint's backgrounded launch) so the test does
# not race the install, and assert the packages are actually installed
# (not merely downloadable) via `sdkmanager --list_installed`, with licences
# already accepted non-interactively.
check "Android SDK platform 34 + build-tools installed" docker exec "$NAME" bash -c \
  '/usr/local/lib/android-sdk-bootstrap.sh >/tmp/android-bootstrap.log 2>&1 && \
   INSTALLED=$(sdkmanager --list_installed --sdk_root="$ANDROID_SDK_ROOT" 2>/dev/null) && \
   echo "$INSTALLED" | grep -q "platforms;android-34" && \
   echo "$INSTALLED" | grep -q "build-tools;"'

# claude-code-connector: the MCP server that lets Claude Cowork drive the CLI
# in this container. Built into /opt/claude-code-connector and started by
# entrypoint.sh on port 8765. Checked from inside the container so the test
# doesn't depend on host port publishing. `run_command` is arbitrary shell in
# a container holding the Docker socket, so the bearer token is the whole
# security story: 401 without it, and no listener at all when CONNECTOR_TOKEN
# is unset (same rule as ttyd).
MCP_INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'
check "connector /healthz responds" docker exec "$NAME" bash -c \
  'curl -sf http://127.0.0.1:8765/healthz | grep -q "\"ok\":true"'
check "connector MCP initialize returns 200 + mcp-session-id" docker exec "$NAME" bash -c \
  "curl -s -i http://127.0.0.1:8765/mcp -H 'content-type: application/json' \
     -H 'accept: application/json, text/event-stream' \
     -H 'authorization: Bearer $CONNECTOR_TOKEN' -d '$MCP_INIT' \
   | tee /tmp/mcp-init.txt | grep -q '^HTTP/1.1 200' && grep -qi '^mcp-session-id:' /tmp/mcp-init.txt"
check "connector rejects missing bearer token with 401" docker exec "$NAME" bash -c \
  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/mcp \
     -H 'content-type: application/json' -d '$MCP_INIT')\" = 401 ]"
check "connector rejects wrong bearer token with 401" docker exec "$NAME" bash -c \
  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/mcp \
     -H 'content-type: application/json' -H 'authorization: Bearer wrong' -d '$MCP_INIT')\" = 401 ]"

# Spec compliance (MCP Streamable HTTP, session management): an unknown session
# id (e.g. from before a connector restart wiped its in-memory session map)
# must get 404, not 400, so a compliant client re-initialises automatically
# instead of treating it as a fatal protocol error and getting stuck forever.
BOGUS_SID="$(cat /proc/sys/kernel/random/uuid)"
TOOLS_LIST='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
check "connector POST /mcp with unknown session id returns 404" docker exec "$NAME" bash -c \
  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/mcp \
     -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
     -H 'authorization: Bearer $CONNECTOR_TOKEN' -H 'mcp-session-id: $BOGUS_SID' -d '$TOOLS_LIST')\" = 404 ]"
check "connector GET /mcp with unknown session id returns 404" docker exec "$NAME" bash -c \
  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/mcp \
     -H 'accept: text/event-stream' \
     -H 'authorization: Bearer $CONNECTOR_TOKEN' -H 'mcp-session-id: $BOGUS_SID')\" = 404 ]"
check "connector POST /mcp with no session id on non-initialize request still returns 400" docker exec "$NAME" bash -c \
  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/mcp \
     -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
     -H 'authorization: Bearer $CONNECTOR_TOKEN' -d '$TOOLS_LIST')\" = 400 ]"

NOTOKEN_NAME="${NAME}-notoken"
NOTOKEN_HOME="$(mktemp -d)"
docker run -d --name "$NOTOKEN_NAME" -v "$NOTOKEN_HOME:/root" "$TAG" >/dev/null 2>&1
sleep 3
check "connector does not listen when CONNECTOR_TOKEN is unset" docker exec "$NOTOKEN_NAME" bash -c \
  '! curl -sf http://127.0.0.1:8765/healthz >/dev/null'
docker rm -f "$NOTOKEN_NAME" >/dev/null 2>&1
rm -rf "$NOTOKEN_HOME"

# SIGTERM stop time: PASS if docker stop completes in under 3 seconds.
START_NS=$(date +%s%N)
if docker stop "$NAME" >/dev/null 2>&1; then
  END_NS=$(date +%s%N)
  ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
  if [ "$ELAPSED_MS" -lt 3000 ]; then
    echo "PASS: SIGTERM stop time (${ELAPSED_MS}ms)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: SIGTERM stop time (${ELAPSED_MS}ms)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  echo "FAIL: SIGTERM stop time (docker stop errored)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo ""
echo "${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
