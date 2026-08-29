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

launch_remote_control_sessions() {
  local projects_dir="$1"
  local log_dir="$2"
  mkdir -p "$log_dir"

  local dir project
  for dir in "$projects_dir"/*/; do
    [ -f "${dir}CLAUDE.md" ] || continue
    project="$(basename "$dir")"
    (cd "$dir" && nohup claude remote-control >>"${log_dir}/${project}.log" 2>&1 &)
  done
}
