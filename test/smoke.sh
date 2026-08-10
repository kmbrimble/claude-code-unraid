#!/usr/bin/env bash
# Container smoke-test harness. Builds the image, runs it, and checks that
# expected tooling is present and the container stops promptly on SIGTERM.
set -uo pipefail

TAG="claude-code-smoketest:local"
NAME="cc-smoketest"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker rmi "$TAG" >/dev/null 2>&1
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
if ! docker run -d --name "$NAME" "$TAG" >/dev/null; then
  echo "FAIL"
  exit 1
fi

sleep 3

check "gh present" docker exec "$NAME" gh --version
check "node present" docker exec "$NAME" node -v
check "git present" docker exec "$NAME" git --version
check "tmux present" docker exec "$NAME" tmux -V

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
