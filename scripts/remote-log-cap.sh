#!/usr/bin/env bash
# Bounds the size of `claude remote-control`'s per-project stdout+stderr
# logs (see scripts/remote-control-launch.sh). Remote Control repaints its
# status banner roughly once a second via cursor-up escapes, which only
# overwrite in a real TTY — against a log file every repaint just appends,
# so left alone these grow unbounded (791MB observed after 7 days across 10
# sessions, ~100% repeated banner/QR/link lines).
#
# The session process holds an open O_APPEND fd on the log, so shrinking
# MUST happen in place on the same inode: `>` truncates the existing inode
# without unlinking it, so the running process's next write still lands in
# the visible file. A mv/rm-based approach would leave it appending to a
# detached, now-invisible inode forever.
#
# Extracted into its own script (like remote-control-launch.sh) so
# test/smoke.sh can exercise cap_log_file directly against a fixture file,
# without needing a real remote-control session.

cap_log_file() {
  local log="$1" max_bytes="$2" head_bytes="$3" tail_bytes="$4"
  [ -f "$log" ] || return 0
  local size
  size=$(stat -c %s "$log" 2>/dev/null) || return 0
  [ "$size" -gt "$max_bytes" ] || return 0
  # head_bytes + marker + tail_bytes must land STRICTLY under max_bytes, or
  # the next pass sees the file still over the cap and rewrites it again
  # forever. Clamp here rather than trust callers, so every caller gets a
  # size that reaches a stable fixed point after one pass.
  local marker=$'\n... [log truncated by container log cap] ...\n'
  local budget=$((max_bytes - ${#marker} - 1))
  [ "$budget" -lt 0 ] && budget=0
  [ "$head_bytes" -gt "$budget" ] && head_bytes=$budget
  local remaining=$((budget - head_bytes))
  [ "$tail_bytes" -gt "$remaining" ] && tail_bytes=$remaining
  local tmp
  tmp=$(mktemp) || return 0
  { head -c "$head_bytes" "$log"
    printf '%s' "$marker"
    tail -c "$tail_bytes" "$log"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  cat "$tmp" >"$log" 2>/dev/null
  rm -f "$tmp"
}

cap_remote_control_logs() {
  local log_dir="$1"
  local max_bytes="${REMOTE_CONTROL_LOG_MAX_BYTES:-20971520}"
  # The head only needs to cover the launch/auth/connection lines and any
  # startup error, which is a few hundred KB at most; the rest of the budget
  # goes to the tail, which is what you actually read when diagnosing a live
  # problem. cap_log_file clamps this down further for small max_bytes.
  local head_bytes=262144
  local f
  for f in "$log_dir"/*.log; do
    [ -e "$f" ] || continue
    cap_log_file "$f" "$max_bytes" "$head_bytes" "$max_bytes" || true
  done
}

# Backgrounded from entrypoint.sh; never signals or otherwise touches the
# remote-control processes themselves, only their log files.
cap_remote_control_logs_loop() {
  local log_dir="$1"
  local interval="${2:-300}"
  while true; do
    cap_remote_control_logs "$log_dir"
    sleep "$interval"
  done
}
