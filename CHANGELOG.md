# Changelog

Versions here are assigned in commit order: minor is a plain integer
counter (0.1 for the first commit, 0.2 for the second, and so on); major
is only ever advanced manually. Newest at top.

## [Unreleased]

- Plan: add Remote Control auto-launch. `entrypoint.sh` will, after tmux
  session setup, scan immediate subdirectories of `/projects` and start a
  detached `claude remote-control` (no tmux, stdout/stderr to
  `~/claude-remote-logs/<project>.log`) for each one containing a
  `CLAUDE.md`, skipping others silently. The discovery/launch logic is
  extracted into `scripts/remote-control-launch.sh` so `test/smoke.sh` can
  source it and exercise it against a stub `claude` binary without real
  auth/network. (Parts 1 and 2 of the originating request — the `TMUX_PANE`
  fix and the wrapper migration to `scripts/claude-wrapper.sh` — were
  already completed in 0.13/0.14.)

## 0.14 (2026-08-27)

- Fixed the real cause of issue #9 (auto-retry wrapper never runs), reopened
  after 0.13 didn't actually fix it. 0.13's fix (explicit `TMUX_PANE` via
  `tmux set-environment`) was addressing a symptom that was never actually
  broken — tmux already sets `TMUX_PANE` correctly in the pane's real process
  environment on its own; confirmed live via `/proc/<pane_pid>/environ`. The
  actual root cause: `tmux new-session` starts the pane's shell as a *login*
  shell (`-bash`), and login shells read `~/.bash_profile`/`~/.profile`,
  never `~/.bashrc`. The base image bakes a `~/.profile` that sources
  `~/.bashrc` (masking the bug in a plain `docker run`), but the real
  deployment's `/root` is bind-mounted from an external, empty unRAID
  appdata directory that shadows it entirely — so `~/.bashrc` (where
  `entrypoint.sh` sources `scripts/claude-wrapper.sh`) was never read, the
  `claude` wrapper function was never defined, and every `claude` invocation
  ran the raw binary directly, silently bypassing `claude-auto-retry`'s
  `launcher.js`/`monitor.js`. Confirmed via process ancestry in the live
  container: `claude --continue` was a direct child of the pane's `-bash`,
  not of `node launcher.js`.
  `entrypoint.sh` now also ensures `~/.bash_profile` sources `~/.bashrc`
  (the standard idiom), mirroring the existing idempotent `~/.bashrc`-ensure
  block. `test/smoke.sh` now bind-mounts `/root` from an empty host
  directory (a named Docker volume would be pre-populated from the image,
  masking this) to match the real deployment, and adds a behavioural check —
  `bash -lc 'declare -f claude'` in a real login shell — replacing reliance
  on the circular `TMUX_PANE` check alone. Confirmed the new check fails
  against pre-fix `entrypoint.sh` and passes after.

## 0.13 (2026-08-23)

- Fixed `claude-auto-retry`'s monitor never starting: its `getCurrentPane()`
  (`src/tmux.js`) reads only `$TMUX_PANE`, with no fallback, and that variable
  was never set because `entrypoint.sh` creates the long-lived `claude` tmux
  session directly rather than via claude-auto-retry's own
  `createTmuxSession()` path. `entrypoint.sh` now explicitly runs
  `tmux set-environment -t claude TMUX_PANE "$(tmux list-panes -t claude -F
  '#{pane_id}')"` right after creating the session, so any shell attaching
  later (ttyd's `-A`, or a manual `tmux attach`) inherits a correct value.
  Confirmed via `~/.claude-auto-retry/logs/`: no monitor log at all was
  produced during a real rate-limit incident on 22 Aug 2026.
- Moved the `claude`/`_claude_auto_retry` wrapper functions out of the
  untracked `~/.bashrc` (persisted home mount, invisible to this repo) into a
  new tracked `scripts/claude-wrapper.sh`, unchanged in behaviour. It's copied
  into the image at `/usr/local/lib/claude-wrapper.sh`; `entrypoint.sh` ensures
  `~/.bashrc` sources it on every start, so a fresh home-mount volume picks it
  up automatically.
- Extended `test/smoke.sh` with checks that `tmux show-environment -t claude
  TMUX_PANE` returns a real pane id (not "variable not found"),
  `scripts/claude-wrapper.sh` is present in the built image, and `~/.bashrc`
  sources it. Confirmed all three fail against the pre-change image/entrypoint
  and pass after the fix.

## 0.12 (2026-08-18)

- Baked Chromium's OS-level shared libraries (glib, nss, atk, ...) into the
  image via `RUN npx --yes playwright install-deps chromium`, so
  Playwright/Chromium can launch inside the container without a per-session
  `apt-get`/`install-deps` step. Only the OS packages are installed — the
  Playwright npm package and browser binary are not baked in, so each
  downstream project's own `package.json`/`npx` still controls which
  Playwright version and browser binary it uses (the binary lands in
  `~/.cache/ms-playwright` on the persisted home mount at test time, same as
  before).
- Added a `test/smoke.sh` check that downloads Chromium via `npx
  playwright@1.62.1 install chromium` (the version pinned in
  terriblebutler's `package.json`) and runs `npx playwright@1.62.1
  screenshot about:blank`. Confirmed this fails against the pre-change image
  with `chrome-headless-shell: error while loading shared libraries:
  libglib-2.0.so.0: cannot open shared object file`, and passes after the
  Dockerfile change.
- Image size grew from 1.11 GB to 1.48 GB (+~372 MB) — the cost of baking in
  Chromium's dependency tree (glib, nss, atk, cups, mesa/DRM libs, X11
  utilities, fonts, etc.).

## 0.11

- Populated `README.md` (resolves #4): what the image contains, how to
  build/run it locally, the smoke test, the four non-negotiable unRAID
  mounts, the env vars read from `templates/claude-code.xml`
  (`GH_TOKEN`, `TTYD_CREDENTIAL`, `GIT_USER_NAME`/`EMAIL`, `HA_BASE_URL`),
  how to attach to the agent's `tmux` session, and the push → watch build →
  force-update → reattach deploy flow from `CLAUDE.md`. Documentation-only;
  `test/smoke.sh` doesn't apply, verified by manual cross-check against
  `Dockerfile`, `entrypoint.sh`, and `templates/claude-code.xml`.

## 0.10

- Add ttyd browser-based terminal to the image (LAN-only, password-gated via TTYD_CREDENTIAL; starts only if a credential is set).
- Add ttyd presence check to the container smoke test.

## 0.9

- Fixed graceful shutdown: `entrypoint.sh` previously ended with a
  synchronous `tail -f /dev/null` as PID 1, which does not receive a
  handler for SIGTERM/SIGINT, so `docker stop` took the full kill timeout
  (~10s). Replaced it with an explicit trap plus a backgrounded
  sleep-loop/`wait`, so the container now stops in well under a second
  while preserving all existing startup behaviour (GH_TOKEN/git/gh setup,
  tmux session creation, ready message).

## 0.8

- Configure GitHub auth in entrypoint.sh

## 0.7

- Add GitHub CLI installation to Dockerfile

## 0.6

- Refactor Dockerfile for &NBSP errors

## 0.5

- Add GitHub Actions workflow for building Docker image

## 0.4

- Initialize tmux session for agent in entrypoint.sh

## 0.3

- Add shebang and set options in entrypoint.sh

## 0.2

- Add Dockerfile for Node.js environment setup

## 0.1

- Initial commit
