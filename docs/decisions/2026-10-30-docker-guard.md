<!-- Moved from claude.ai Project "Claude", doc claude/docker-guard-outcome.md, on 2026-11-04. -->
<!-- Known stale at move: none reported at audit. -->

# docker rm / rmi guard — outcome (30 Oct 2026)

Decision record. Persisted mount only (`~/.claude/hooks/`, `~/.claude/CLAUDE.md`); no image change, no force-update.
Pre-change copies: `~/.claude/backups/docker-guard-20261030/`.

## What was wrong
- `docker rmi` was **not** in `settings.json` `permissions.deny` (that list holds kill, restart, compose down, system prune, volume rm, network rm). The block was the PreToolUse hook `docker-cleanup-guard.sh`, which answers `ask` for any rm/stop/rmi target Claude did not create. `ask` cannot be answered in a headless or connector session, so it shows up as a rejection.
- The hook split arguments naively, so `docker rmi img 2>&1 | tail -1` made `2>&1`, `|` and `tail` look like image names and asked even for images Claude had built. Chained forms (`cd x && docker rm ...`) were not gated at all.
- Tracking was unreliable: `docker run -t X` recorded the image `X` as Claude-created (`-t` is TTY there), and unexpanded `$NAME` was recorded literally, so any `docker rm $VAR` was auto-allowed (including `claude-code`). The old self-test also failed on a stale comment saying rmi was settings-denied.

## What it does now
`docker-cleanup-guard.sh` is a thin wrapper around `docker-cleanup-guard.py` (shlex tokenising; stdlib only; fails closed to `ask` on an internal error for anything that looks like a removal).
- **Owned, allowed:** names from `docker run|create --name` and `docker build -t` (any segment of a chained command), `smoketest-*`.
- **Cleared by the user, allowed:** a line `docker-remove-ok: <name> [<name>...]` at the start of a line in a **user-role** message of the session's transcript. Tool results, sub-agent prompts, `<system-reminder>` blocks and mid-line mentions do not count.
- **Never owned:** `claude-code`, names with `$`, backticks, `*`, `(`, hex-only names (could be an id prefix). Same-command `VAR=value` is resolved first.
- `allow` is emitted only when the command is just the removals plus harmless filters/redirects (`tail`, `grep`, `>/dev/null`, `2>&1`, `cd`, `echo` ...). An owned removal inside a bigger command stays silent and goes to the normal permission system.
- Legacy junk in the state file (`$NAME`, `15`, `/dev/null`) is ignored on read; the file itself was not rewritten.

## Verified
- `docker-cleanup-guard.test.sh`: 52 checks pass.
- Live headless Haiku sessions (`--permission-mode default --allowed-tools Bash`), real docker state checked afterwards: no marker → refused; marker → removed; marker naming a different container → refused; session-built image and session-created container → removed with no marker.

## Notes and limits
- State is global, not per session: anything any Claude session ever created stays removable by any later session. Making it strictly per session is possible (store session ids) but was not asked for.
- `unraid-ops-docker-socket-proxy` is a live container and is in the owned list (a session created it), so it is removable without a marker.
- A base image only pulled (e.g. `python:3.12-slim` in CLAUDE.md "Throwaway containers" step 2) is not "created", so its `docker rmi` needs the marker. Pull-tracking (record images that were absent before `docker pull`) is the obvious extension.
- This is a guard against accidents, not a boundary against a hostile agent: the state file, hook and transcript are all writable by the same user.
- Headless callers: put the `docker-remove-ok:` line in the prompt passed to `start_session` / `continue_session`.
