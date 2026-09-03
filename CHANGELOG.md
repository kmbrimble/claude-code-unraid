# Changelog

Versions here are assigned in commit order: minor is a plain integer
counter (0.1 for the first commit, 0.2 for the second, and so on); major
is only ever advanced manually. Newest at top.

## [Unreleased]

- (2026-09-03) Plan: container hygiene, three fixes.
  1. `scripts/claude-wrapper.sh`'s `claude()` silently no-ops under non-TTY
     stdin (`script -c` runs its command via `$SHELL`, which falls back to
     dash outside tmux, where the exported bash function isn't visible) —
     skip the `script` typescript wrapper entirely when stdin isn't a TTY and
     call `_claude_auto_retry "$@"` directly instead; for the interactive
     path, force `SHELL=/bin/bash` and add `script -e` so the real exit
     status propagates, and build the `-c` command string with `printf %q` so
     arguments containing spaces survive.
  2. `Dockerfile`: add `procps` to the first `apt-get install` block (`ps`,
     `free`, `top`, `pgrep` are currently missing).
  3. New `scripts/remote-log-cap.sh`, sourced and backgrounded from
     `entrypoint.sh` in a sleep loop alongside the existing remote-control
     launch: caps each `~/claude-remote-logs/*.log` at
     `REMOTE_CONTROL_LOG_MAX_BYTES` (default 20MB) by writing a head+tail
     excerpt back into the same file via `>` (truncates the existing inode in
     place; never `mv`/`rm`, since the session process holds an open
     `O_APPEND` fd). Per-file failures are swallowed so one bad log can't
     abort the loop or the entrypoint.
  - Tests: `test/smoke.sh` gets a real invocation check for the `claude`
    wrapper (exit 0, version-shaped output, no `_claude_auto_retry: not
    found`), a non-zero exit propagation check (override
    `_claude_auto_retry` to `return 7` and assert it surfaces), a
    `ps`/`free`/`top` presence check, and a direct test of
    `cap_log_file` against an oversized fixture (size drops below cap, first
    line preserved, inode unchanged).

## 0.18 (2026-09-02)

- (2026-09-02) Replaced Debian bookworm's `docker.io` (ships Docker CLI
  20.10.24+dfsg1, predates `docker compose`/`docker buildx` v2 plugin syntax —
  broke a Cowork session driving this container via `claude-code-connector`)
  with the official Docker CE apt repo's `docker-ce-cli` +
  `docker-compose-plugin` + `docker-buildx-plugin`, client only — deliberately
  NOT `docker-ce`/`containerd.io`/`docker-ce-rootless-extras` (the daemon),
  since this container only ever talks to the unRAID host's daemon over the
  mounted `/var/run/docker.sock`. `Dockerfile`: swapped `docker.io` out of the
  first `RUN apt-get install` block for the Docker apt-repo keyring
  (`/etc/apt/keyrings/docker.asc`, `signed-by`) + source list + package
  install, kept in the same layer as before (apt lists still removed once at
  the end). Now: `docker --version` → 29.7.2 (was 20.10.24), `docker compose
  version`/`docker buildx version` both exit 0. `test/smoke.sh`: three new
  checks (docker CLI major >= 27 parsed and asserted with a clear failure
  message, `docker compose version`, `docker buildx version`). Confirmed all
  three fail against the pre-change image (27/30 passed, `docker.io`'s 20.10
  client); full smoke run green after the change, 30/30.

- (2026-09-02) Add `claude-code-connector`: an MCP server (Streamable HTTP,
  port 8765) baked into the image that lets Claude Cowork / the desktop app
  drive the `claude` CLI in this container — list projects and sessions,
  start/resume sessions, run shell commands, poll long jobs. Plan: vendor the
  source at `connector/` (public repo, not a separate private one: the image
  is public on ghcr so the compiled connector is public regardless, the
  source holds no secrets, and a private repo would force the public CI build
  to carry a PAT); build it in the `Dockerfile` into
  `/opt/claude-code-connector`; start it from `entrypoint.sh` as a second
  background process, ONLY when `CONNECTOR_TOKEN` is set (same rule as ttyd —
  `run_command` is arbitrary shell in a container with the Docker socket);
  `PROJECTS_ROOT=/projects` (existing mount, no new mapping);
  `SKIP_PERMISSIONS=1` default because headless `-p` runs cannot answer
  prompts, and `~/.claude/settings.json` deny rules still apply under
  `--dangerously-skip-permissions`; `IS_SANDBOX=1` on the connector process
  only, because the CLI refuses `--dangerously-skip-permissions` as root
  without it; add port 8765 + `CONNECTOR_TOKEN` to `templates/claude-code.xml`.
  Env is scoped to the connector process in `entrypoint.sh` rather than
  image-wide `ENV`, so a global `PORT` doesn't leak into every dev server the
  agent runs. Tests: `test/smoke.sh` runs the container with a token and
  checks `/healthz`, MCP `initialize` (200 + `mcp-session-id`), 401 with a
  missing or wrong token, and that the connector does NOT listen when no
  token is set. Red baseline confirmed by running the new check bodies
  against the live (pre-change) container; full smoke run green, 27/27.
  Source fixes vs the handed-over version: drop `--verbose` (with
  `--output-format json` it emits an array of every message, not the result
  object, so `result`/`session_id` came back empty against the real CLI);
  tighten `safeProjectPath` so `/projects-evil` no longer passes a
  `startsWith("/projects")` check.

## 0.17 (2026-08-29)

- Add registry-backed Docker layer caching to CI and reorder the Dockerfile so
  the unpinned `npm install -g` layer no longer drags the ~130MB Android
  cmdline-tools layer down with it whenever a new Claude Code release busts
  the cache. Files: `.github/workflows/build.yml` (add
  `docker/setup-buildx-action`, since the default `docker` driver silently
  ignores registry cache; add `cache-from`/`cache-to` on `build-push-action`
  pointing at a `buildcache` tag on the same GHCR package,
  `ghcr.io/kmbrimble/claude-code-unraid:buildcache`, with `mode=max` so
  intermediate stages are cached too, not just the final layer — chosen over
  the GitHub Actions cache backend because that has a 10GB per-repo cap and a
  7-day eviction window this large/irregularly-rebuilt image would sit
  awkwardly against), `Dockerfile` (move `RUN npm install -g
  @anthropic-ai/claude-code claude-auto-retry` to immediately after the
  Android cmdline-tools `RUN` block — repository-reader confirmed the npm
  step reads no ENV/ARG and nothing later in the build depends on its
  binaries at build time, only at container runtime). Deliberately out of
  scope: a build ARG to bust the npm layer on demand — considered, deferred.
  Tests: `test/smoke.sh` gets four new static/structural checks (workflow
  declares buildx setup, declares both cache directions against the
  `buildcache` tag, and the Dockerfile's npm line appears after the
  cmdline-tools RUN block) that run before the docker build, no container
  needed; confirmed all four fail against current main first. `provenance:
  false` added to the build step — buildx enables provenance attestation by
  default (the old `docker` driver couldn't), which would otherwise change
  the pushed `:latest` from a bare manifest to an OCI image index; disabled
  to keep this change purely about cache/layer ordering, not artifact shape.
  Expected: the first build after this merges has nothing to read from the
  cache yet, so that pull is exactly as slow as today; the saving starts on
  the second build, where apt/JDK, Playwright-deps, and cmdline-tools layers
  should report "Already exists" on the unRAID pull. Runtime consequence to
  note: from the second cached build onward, pushes to main no longer
  refresh the `claude-code`/`claude-auto-retry` npm install by themselves —
  that layer now only reruns when its own `RUN` line changes or the
  `buildcache` tag is deleted from GHCR, so a new Claude Code release needs
  one of those to actually land in the image (a deliberate trade-off; a
  build ARG to bust this layer on demand was considered and explicitly
  deferred).

## 0.16 (2026-08-29)

- Add Android build/debug toolchain: `openjdk-17-jdk-headless`, apt's `adb`/
  `fastboot` (always-present fallback), and the Android cmdline-tools
  launcher baked into the image at `/opt/android-cmdline-tools` (outside the
  `/root` bind mount, so it survives a fresh persisted home). `ANDROID_SDK_ROOT`
  (`/root/.android-sdk`) and `GRADLE_USER_HOME` (`/root/.gradle`) point at the
  persisted home mount; an idempotent `android-sdk-bootstrap.sh`, backgrounded
  from `entrypoint.sh`, installs `platforms;android-34` and matching
  build-tools via `sdkmanager` and accepts SDK licences non-interactively
  (`yes | sdkmanager --licenses`) on first run, so the container comes up
  usable with no manual step and self-heals if the persisted path is empty.
  `PATH` puts the SDK's `platform-tools` ahead of apt's `adb` once bootstrapped,
  avoiding an `adb` client/server version mismatch. Verified via `docker
  inspect` that the live container runs on Docker's `bridge` network (not
  macvlan), so outbound `adb connect` to the LAN NATs fine. `test/smoke.sh`
  extended to assert JDK/adb/sdkmanager presence and version, that
  `ANDROID_SDK_ROOT`/`GRADLE_USER_HOME` exist and are writable, and that the
  bootstrap actually installs platform 34 + build-tools (`sdkmanager
  --list_installed`), run synchronously in the test rather than backgrounded.
  Skipped a throwaway Gradle build at test time (cost of a full Gradle
  distribution + AGP download for what `--list_installed` already proves);
  the first real project build via `./gradlew` is the first exercise of that
  path. `android-sdk-bootstrap.sh` takes a `flock` on the SDK root before
  invoking `sdkmanager`, so the entrypoint's backgrounded first-run bootstrap
  and the smoke test's synchronous invocation of the same idempotent script
  never write the SDK root concurrently. Release-APK signing is covered by
  `apksigner`, which ships inside `build-tools;34.0.0`. SDK licences are
  accepted non-interactively at first-run bootstrap rather than at image
  build time — nothing SDK-side is installed at build time, only the small
  cmdline-tools launcher, so there is nothing to license until then. Image
  size grew from 1.36 GB to 1.79 GB (+412 MB: `openjdk-17-jdk-headless`,
  `adb`/`fastboot`, and the cmdline-tools launcher); no CA template change
  needed since everything else lives under the existing `/root` mapping.

## 0.15 (2026-08-29)

- Added Remote Control auto-launch. `entrypoint.sh` now, after tmux session
  setup, scans immediate subdirectories of `/projects` and starts a detached
  `claude remote-control` (no tmux pane/window; stdout/stderr redirected to
  `~/claude-remote-logs/<project>.log`) for each one containing a root-level
  `CLAUDE.md`, silently skipping the rest — a project only starts receiving
  an auto-launched session once its `CLAUDE.md` is written, matching how
  every project so far has actually been onboarded. Runs once at start and
  never blocks the entrypoint's own startup or keep-alive loop. Spawn mode
  (e.g. "same-dir") is a one-time interactive choice the CLI persists per
  project on its actual first launch, so this never passes `--spawn` or
  tries to guess it — it relies on whatever was chosen manually for the
  three projects already in use.
- The discovery/launch logic is extracted into
  `scripts/remote-control-launch.sh` (`launch_remote_control_sessions`),
  copied into the image at `/usr/local/lib/remote-control-launch.sh` and
  sourced by `entrypoint.sh`, specifically so it can be tested without a
  real `claude` binary.
- Extended `test/smoke.sh` with a check that sources
  `remote-control-launch.sh` inside the running container, points `$PATH`
  at a stub `claude` script, and runs the discovery loop against a temp
  directory tree (one subdirectory with a `CLAUDE.md`, one without).
  Confirmed it fails before `scripts/remote-control-launch.sh` existed and
  passes after. A real `claude remote-control` session actually connecting
  is NOT covered automatically (it needs live auth and a network
  connection) — after deploying, manually confirm with `docker exec -it
  claude-code cat ~/claude-remote-logs/<project>.log` for a known
  `CLAUDE.md` project, and check the Claude desktop app sees the session.
- Parts 1 (`TMUX_PANE` fix) and 2 (wrapper migration to
  `scripts/claude-wrapper.sh`) of the originating request were already
  completed in 0.13/0.14 — no further change needed for those.

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
