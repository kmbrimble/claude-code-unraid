#!/usr/bin/env bash
# Discovers immediate subdirectories of a projects directory that contain a
# CLAUDE.md and starts a detached `claude remote-control` in each — no tmux
# pane/window, stdout+stderr redirected to a per-project log file. Extracted
# from entrypoint.sh so test/smoke.sh can source it and exercise the
# discovery/launch logic against a stub `claude` binary, without needing real
# auth or a network connection.
#
# Spawn mode ("same-dir" etc.) is a one-time interactive choice persisted per
# project by the CLI on its actual first `remote-control` launch — this
# script never passes --spawn and never guesses at it.
#
# REMOTE_CONTROL_PROJECTS (read from the environment, not a function
# argument, so callers need no signature change):
#   unset/empty — launch for every CLAUDE.md project (unchanged default).
#   "none"      — launch nothing.
#   otherwise   — space-separated list of project basenames; only those,
#                 only if the directory exists and has a CLAUDE.md.

launch_remote_control_sessions() {
  local projects_dir="$1"
  local log_dir="$2"
  mkdir -p "$log_dir"

  if [ "${REMOTE_CONTROL_PROJECTS:-}" = "none" ]; then
    return 0
  fi

  local dir project
  if [ -z "${REMOTE_CONTROL_PROJECTS:-}" ]; then
    for dir in "$projects_dir"/*/; do
      [ -f "${dir}CLAUDE.md" ] || continue
      project="$(basename "$dir")"
      (cd "$dir" && nohup claude remote-control >>"${log_dir}/${project}.log" 2>&1 &)
    done
  else
    for project in $REMOTE_CONTROL_PROJECTS; do
      dir="$projects_dir/$project"
      if [ ! -f "$dir/CLAUDE.md" ]; then
        echo "REMOTE_CONTROL_PROJECTS: skipping '$project' (no CLAUDE.md at $dir)"
        continue
      fi
      (cd "$dir" && nohup claude remote-control >>"${log_dir}/${project}.log" 2>&1 &)
    done
  fi
}
