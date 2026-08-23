# Changelog

Versions here are assigned in commit order: minor is a plain integer
counter (0.1 for the first commit, 0.2 for the second, and so on); major
is only ever advanced manually. Newest at top.

## [Unreleased]

### Plan (2026-08-23): fix claude-auto-retry monitor not starting; version-control the retry wrapper

- Root cause: `claude-auto-retry`'s `getCurrentPane()` (`src/tmux.js`) reads only
  `$TMUX_PANE` from the environment, with no fallback. `entrypoint.sh` creates the
  long-lived tmux session directly (`tmux new-session -d -s claude`), bypassing
  claude-auto-retry's own `createTmuxSession()` path that normally sets
  `$TMUX_PANE`. Any shell attaching later (ttyd's `-A`, or a manual `tmux attach`)
  can therefore start with `$TMUX_PANE` unset, so `launchInteractive()` silently
  skips forking `monitor.js` — no error, no log entry, `claude` runs normally
  otherwise. Confirmed via `~/.claude-auto-retry/logs/`: no monitor log at all for
  a real 22 Aug 2026 rate-limit incident.
- Fix: in `entrypoint.sh`, immediately after creating the `claude` tmux session,
  explicitly set `TMUX_PANE` in that session's environment via
  `tmux set-environment -t claude TMUX_PANE "$(tmux list-panes -t claude -F '#{pane_id}')"`,
  so any later shell attaching to it inherits a correct value regardless of
  attach method. Does not touch `node_modules/claude-auto-retry` (third-party,
  wiped on reinstall).
- Relocation: move the two wrapper shell functions (`_claude_auto_retry`,
  `claude`) that currently live only in the untracked `~/.bashrc` (persisted home
  mount) into a new tracked `scripts/claude-wrapper.sh`, copied into the image and
  sourced from `~/.bashrc` (entrypoint.sh ensures the sourcing line exists on
  every start, so a fresh home-mount volume picks it up automatically). Behaviour
  preserved exactly — this is a relocation, not a logic change.
- Tests: extend `test/smoke.sh` with a check that `tmux show-environment -t claude
  TMUX_PANE` inside the running test container returns a real pane id (not
  "variable not found"), plus checks that `scripts/claude-wrapper.sh` is present
  in the built image and that `~/.bashrc` sources it.

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
