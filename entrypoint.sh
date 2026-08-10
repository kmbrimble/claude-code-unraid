#!/usr/bin/env bash
set -euo pipefail

# As PID 1, the kernel won't apply default signal dispositions unless we
# install explicit handlers, so without this SIGTERM/SIGINT would be
# ignored and the container would hang until the runtime's kill timeout.
trap 'exit 0' SIGTERM SIGINT

# Configure GitHub auth from GH_TOKEN (supplied via CA template variable).
if [ -n "${GH_TOKEN:-}" ]; then
  git config --global user.name "${GIT_USER_NAME:-Butler Bot}"
  git config --global user.email "${GIT_USER_EMAIL:-butler-bot@users.noreply.github.com}"
  git config --global --add safe.directory '*'
  gh auth setup-git 2>/dev/null && echo "GitHub auth configured from GH_TOKEN." || echo "WARN: gh auth setup-git failed."
else
  echo "No GH_TOKEN set; autonomous push disabled."
fi

# Keep a long lived tmux server running for the agent session.
tmux new-session -d -s claude -c /projects || true

echo "Container ready. Attach with: docker exec -it claude-code tmux attach -t claude"

# Block here to keep the container alive. Use a backgrounded sleep-loop
# with `wait` (rather than a synchronous `tail -f`) so the trap above can
# actually run and exit promptly when a signal arrives.
while true; do
  sleep 1 &
  wait $!
done
