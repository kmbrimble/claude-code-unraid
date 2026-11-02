#!/bin/sh
# /usr/local/bin/gh: runs the forge guard (home mount) and then execs the real gh at /usr/bin/gh.
# /usr/local/bin precedes /usr/bin on PATH, so nothing is moved or diverted and apt can still
# upgrade gh. GUIDANCE, NOT A SECURITY BOUNDARY: /usr/bin/gh called by absolute path, or a script
# that talks to api.github.com itself, bypasses it. Kill switch: FORGE_GUARD=off.
#
# Fail-open by design: a missing guard, a guard crash or any exit status other than 3 runs gh
# unchanged. Only 3 ("wrong forge" in deny mode) blocks. `gh auth ...` is never inspected: git's
# github.com credential helper is `gh auth git-credential`, which must stay instant and silent.
real=/usr/bin/gh
guard="${HOME:-/root}/.claude/hooks/forge-guard.sh"
case "${1:-}" in
  auth|"") ;;
  *)
    if [ "${FORGE_GUARD:-}" != off ] && [ -x "$guard" ]; then
      "$guard" --shim -- "$@"
      [ $? -eq 3 ] && exit 1
    fi ;;
esac
exec "$real" "$@"
