#!/usr/bin/env bash
# Keeps the Claude Code CLI on npm's `latest` dist-tag, always, with no
# version pin anywhere.
#
# Why this exists: the Dockerfile's `npm install -g @anthropic-ai/claude-code`
# only captures whatever was `latest` when that layer was last built, and the
# registry layer cache means a rebuild usually reuses it — so the image froze on
# 2.1.273 for a week while 2.1.280 (Opus 5.5) shipped. Claude Code's own
# background auto-updater did not cover the gap either: it runs inside claude
# processes, and this container's `claude -p` runs never advanced it (`claude
# doctor` still showed its last attempt as 2026-09-12 on 2026-09-24).
#
# So the container does it itself: once at start (entrypoint.sh, before the
# connector and Remote Control sessions launch, so they start on the newest
# release even from a stale image), then on an interval. Running `claude`
# processes are never touched — a new install only affects processes started
# afterwards, same as Claude Code's own updater.
#
# Extracted into its own script (like remote-log-cap.sh) so test/smoke.sh can
# drive update_claude_code_once against stub `npm`/`claude` binaries.
#
# Knobs (plain env, all optional):
#   CLAUDE_CODE_AUTO_UPDATE=0            skip updating entirely (debug escape hatch)
#   CLAUDE_UPDATE_INTERVAL_SECONDS=3600  loop interval

CLAUDE_UPDATE_PKG="@anthropic-ai/claude-code"

_claude_update_log() { echo "$(date -Is) claude-update: $*"; }

claude_code_installed_version() {
  claude --version 2>/dev/null | awk 'NR==1{print $1}'
}

# Always returns 0: a failed check or install must never stop container start
# or kill the loop. Silent when already current, so the log only records changes
# and failures.
update_claude_code_once() {
  if [ "${CLAUDE_CODE_AUTO_UPDATE:-1}" = "0" ]; then
    return 0
  fi
  local latest installed
  latest=$(timeout 30 npm view "${CLAUDE_UPDATE_PKG}@latest" version 2>/dev/null) || latest=""
  if ! printf '%s' "$latest" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then
    _claude_update_log "could not read the latest version from npm; staying on $(claude_code_installed_version)"
    return 0
  fi
  installed=$(claude_code_installed_version)
  [ "$installed" = "$latest" ] && return 0
  _claude_update_log "updating ${installed:-<none>} -> ${latest}"
  if timeout 300 npm install -g "${CLAUDE_UPDATE_PKG}@${latest}" >/dev/null 2>&1; then
    _claude_update_log "now on $(claude_code_installed_version)"
  else
    _claude_update_log "npm install of ${latest} failed; staying on $(claude_code_installed_version)"
  fi
  return 0
}

# Backgrounded from entrypoint.sh. Sleeps first: entrypoint.sh has just run
# update_claude_code_once synchronously.
update_claude_code_loop() {
  local interval="${1:-${CLAUDE_UPDATE_INTERVAL_SECONDS:-3600}}"
  while true; do
    sleep "$interval"
    update_claude_code_once
  done
}
