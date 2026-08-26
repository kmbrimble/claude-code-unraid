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
