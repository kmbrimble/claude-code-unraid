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

# tmux starts a pane's shell as a LOGIN shell (`-bash`), and login shells read
# ~/.bash_profile/~/.bash_login/~/.profile, never ~/.bashrc — so the ensure
# above is not enough on its own. The persisted home mount is an external
# host directory with none of those files, so without this, ~/.bashrc (and
# the claude-auto-retry wrapper it sources) is never actually read in the
# real pane and every `claude` invocation silently bypasses auto-retry.
# Standard idiom: make the login shell source ~/.bashrc too.
if ! grep -q '\.bashrc' "${HOME}/.bash_profile" 2>/dev/null; then
  echo '[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"' >> "${HOME}/.bash_profile"
fi

# Auto-launch a detached `claude remote-control` (no tmux) for every project
# directory that has been onboarded (signalled by a CLAUDE.md at its root) —
# the deliberate signal that a project is ready to be worked on autonomously.
# Runs once at container start; spawn mode is a one-time interactive choice
# the CLI persists per project on its actual first launch, so this never
# passes --spawn or waits on the process.
source /usr/local/lib/remote-control-launch.sh
launch_remote_control_sessions /projects "${HOME}/claude-remote-logs"

# Create ANDROID_SDK_ROOT/GRADLE_USER_HOME on the persisted home mount up
# front (fast, synchronous) so they exist and are writable immediately, even
# before the SDK download below finishes. Self-heals an empty/fresh mount.
mkdir -p "${ANDROID_SDK_ROOT}" "${GRADLE_USER_HOME}"

# Install/verify the Android SDK platform + build-tools into ANDROID_SDK_ROOT.
# Backgrounded because a first-run download is ~1GB and would otherwise delay
# "Container ready" by minutes; the script is idempotent so subsequent starts
# just verify and exit quickly. test/smoke.sh runs the same script
# synchronously instead of racing this background job.
/usr/local/lib/android-sdk-bootstrap.sh >"${HOME}/android-sdk-bootstrap.log" 2>&1 &

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

# Optionally start claude-code-connector (MCP over HTTP on port 8765) so
# Claude Cowork can drive the `claude` CLI in this container.
# SAFETY: started ONLY if CONNECTOR_TOKEN is set. Its run_command tool is an
# arbitrary shell in a container holding the Docker socket, so the bearer
# token is the entire security boundary; never run it unauthenticated.
# Runs as root, same as the tmux session, so it sees the same ~/.claude.
# SKIP_PERMISSIONS=1 because headless `claude -p` cannot answer permission
# prompts; the deny list in ~/.claude/settings.json still applies. The CLI
# refuses --dangerously-skip-permissions as root unless IS_SANDBOX=1, which
# is true here (a container) and is scoped to this process only. Job state
# is in-memory, so an image update/restart drops running jobs.
if [ -n "${CONNECTOR_TOKEN:-}" ]; then
  PORT=8765 HOST=0.0.0.0 PROJECTS_ROOT=/projects SKIP_PERMISSIONS=1 IS_SANDBOX=1 \
    node /opt/claude-code-connector/dist/index.js >"${HOME}/claude-code-connector.log" 2>&1 &
  echo "claude-code-connector started on port 8765 (bearer token required)."
else
  echo "No CONNECTOR_TOKEN set; claude-code-connector disabled."
fi

echo "Container ready. Attach with: docker exec -it claude-code tmux attach -t claude"

# Block here to keep the container alive. Use a backgrounded sleep-loop with
# `wait` (rather than a synchronous `tail -f`) so the trap above can run and
# exit promptly when a signal arrives.
while true; do
  sleep 1 &
  wait $!
done
