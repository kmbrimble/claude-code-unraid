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

# claude-auto-retry's monitor only forks when $TMUX_PANE is set (see
# src/tmux.js's getCurrentPane()). Its own createTmuxSession() path normally
# guarantees that, but since we create the session ourselves above, set it
# explicitly so any shell attaching later (ttyd's `-A`, or a manual `tmux
# attach`) inherits a correct value regardless of how it attaches.
tmux set-environment -t claude TMUX_PANE "$(tmux list-panes -t claude -F '#{pane_id}')"

# Ensure ~/.bashrc sources the version-controlled wrapper (scripts/claude-wrapper.sh,
# copied into the image at build time). Runs on every start so a fresh
# persisted home-mount volume picks it up automatically.
if ! grep -q "claude-wrapper.sh" "${HOME}/.bashrc" 2>/dev/null; then
  echo '[ -f /usr/local/lib/claude-wrapper.sh ] && source /usr/local/lib/claude-wrapper.sh' >> "${HOME}/.bashrc"
fi

# Optionally start the browser-based terminal (ttyd), for LAN use.
# SAFETY: ttyd is started ONLY if TTYD_CREDENTIAL (format user:password) is
# set, so there is never an unauthenticated web shell. ttyd serves a real
# shell into a container that has the Docker socket (effectively host root),
# so this must stay on the trusted LAN and always be password protected.
if [ -n "${TTYD_CREDENTIAL:-}" ]; then
  ttyd --writable --port 7681 --credential "${TTYD_CREDENTIAL}" \
    tmux new-session -A -s claude -c /projects &
  echo "ttyd web terminal started on port 7681 (password protected)."
else
  echo "No TTYD_CREDENTIAL set; browser terminal disabled."
fi

echo "Container ready. Attach with: docker exec -it claude-code tmux attach -t claude"

# Block here to keep the container alive. Use a backgrounded sleep-loop with
# `wait` (rather than a synchronous `tail -f`) so the trap above can run and
# exit promptly when a signal arrives.
while true; do
  sleep 1 &
  wait $!
done
