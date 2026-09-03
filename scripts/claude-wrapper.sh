# >>> claude-auto-retry >>>
# Drop any pre-existing `claude` alias (Claude Code's own installer adds one)
# before defining the wrapper functions below. Without this, the shell expands
# the alias while parsing `claude() {` further down, producing "syntax error
# near unexpected token '('" when the rc file is sourced.
unalias claude 2>/dev/null || true
_claude_auto_retry() {
  # Degrade to plain claude if already inside a wrapped session, or if the launcher
  # is gone (package removed via `npm uninstall -g` without `claude-auto-retry
  # uninstall` first) — an orphaned wrapper must never break the claude command.
  if [ "${CLAUDE_AUTO_RETRY_ACTIVE}" = "1" ] || [ ! -e "/usr/local/lib/node_modules/claude-auto-retry/src/launcher.js" ]; then
    command claude "$@"
    return $?
  fi
  # launcher.js's non-print modes always spawn a *new* nested tmux session and
  # attach to it (chooseLaunchMode/createTmuxSession) — that attach needs a real
  # terminal and fails outright without one ("open terminal failed: not a
  # terminal"), regardless of this wrapper. Its print mode (-p/--print) has no
  # such requirement (it buffers stdin and spawns claude directly), so only
  # degrade to plain claude for the non-print, no-TTY case — headless `claude -p`
  # calls keep the retry benefit, and interactive/tmux usage is untouched.
  if [ ! -t 0 ]; then
    local _car_print=0 _car_arg
    for _car_arg in "$@"; do
      if [ "$_car_arg" = "-p" ] || [ "$_car_arg" = "--print" ]; then
        _car_print=1
        break
      fi
    done
    if [ "$_car_print" -eq 0 ]; then
      command claude "$@"
      return $?
    fi
  fi
  export CLAUDE_AUTO_RETRY_ACTIVE=1
  local _car_exit
  if [ -n "${ZSH_VERSION:-}" ]; then
    # zsh: localtraps restores the user's INT/TERM traps automatically on function
    # return. Capture/restore is NOT portable here — `trap -p` is a bashism (zsh
    # treats it as setting a handler), and $(trap) runs in a subshell where zsh
    # lists nothing — so the bash-style path silently wiped the user's traps.
    setopt localoptions localtraps
    trap 'unset CLAUDE_AUTO_RETRY_ACTIVE' INT TERM
    node "/usr/local/lib/node_modules/claude-auto-retry/src/launcher.js" "$@"
    _car_exit=$?
  else
    # bash: function traps are global, so capture and restore around ours.
    local _car_old_int_trap _car_old_term_trap
    _car_old_int_trap=$(trap -p INT 2>/dev/null)
    _car_old_term_trap=$(trap -p TERM 2>/dev/null)
    trap 'unset CLAUDE_AUTO_RETRY_ACTIVE' INT TERM
    node "/usr/local/lib/node_modules/claude-auto-retry/src/launcher.js" "$@"
    _car_exit=$?
    # Restore previous traps instead of clobbering them
    eval "${_car_old_int_trap:-trap - INT}"
    eval "${_car_old_term_trap:-trap - TERM}"
  fi
  unset CLAUDE_AUTO_RETRY_ACTIVE
  return $_car_exit
}
export -f _claude_auto_retry
# <<< claude-auto-retry <<<


# Auto-log every claude session (wraps the auto-retry function above, so both apply)
claude() {
    # `script -c` runs its command via $SHELL, falling back to /bin/sh (dash
    # in this image) when unset — and dash can't see the exported bash
    # function _claude_auto_retry, so it failed silently with exit 0 and no
    # output. That only worked in a tmux pane because tmux sets SHELL=bash.
    # A typescript of a non-interactive run has no value anyway, so skip the
    # script(1) wrapper entirely when stdin isn't a TTY and call the retry
    # function directly, letting its real exit status propagate untouched.
    if [ ! -t 0 ]; then
        _claude_auto_retry "$@"
        return $?
    fi
    local logdir="$HOME/claude-logs"
    mkdir -p "$logdir"
    local ts=$(date +%Y%m%d-%H%M%S)
    local rawlog="$logdir/session-$ts.raw.log"
    local cleanlog="$logdir/session-$ts.log"
    # printf %q quotes each argument for safe reinsertion into the -c string,
    # so arguments containing spaces survive; -e makes script return the
    # wrapped command's exit status instead of its own; SHELL=/bin/bash is
    # forced so this still works if ever invoked from a non-tmux TTY.
    local cmd
    cmd=$(printf '%q ' _claude_auto_retry "$@")
    local exit_code
    SHELL=/bin/bash script -e -f -q -c "$cmd" "$rawlog"
    exit_code=$?
    # Strip ANSI escape codes and carriage-return redraw noise for a readable copy
    sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g; s/\r//g' "$rawlog" > "$cleanlog"
    return $exit_code
}
