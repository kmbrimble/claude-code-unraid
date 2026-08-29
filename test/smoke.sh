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
if ! docker run -d --name "$NAME" -v "$HOME_DIR:/root" "$TAG" >/dev/null; then
  echo "FAIL"
  exit 1
fi

sleep 3

check "gh present" docker exec "$NAME" gh --version
check "node present" docker exec "$NAME" node -v
check "git present" docker exec "$NAME" git --version
check "tmux present" docker exec "$NAME" tmux -V
check "ttyd present" docker exec "$NAME" ttyd --version

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
