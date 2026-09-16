# Operations reference — `claude-code-unraid`

Living reference for whoever operates the `claude-code` container next. Keep this file
current as facts change; it is not a changelog and not a narrative — see `CHANGELOG.md` for
history. Each project under `/projects/` has its own chat; project internals do not belong
here or in the container chat.

## 1. What this is

This repo builds the Docker image for the `claude-code` container itself: the container an
agent session runs inside when working via the Claude Code CLI MCP connector.

- Repo (in container): `/projects/claude-code-unraid`
- GitHub: `kmbrimble/claude-code-unraid`
- Published image: `ghcr.io/kmbrimble/claude-code-unraid:latest`
- Live container name: `claude-code`
- Host: unRAID **7.3.1** at `192.168.0.10` (no `python3` on the host — run Python inside the
  container, not via host SSH).

### Mounts

- `/mnt/user/appdata/claude-code/home` → `/root` (auth, `.claude/`, `.bashrc`, persisted home)
- `/mnt/user/appdata/claude-code/projects` → `/projects` (see §3 — this is the persistent path)
- `/mnt/user/appdata/claude-code/config` → `/config`
- `/var/run/docker.sock` → `/var/run/docker.sock` (see §4 — this is effectively host root)

No new top-level mount for PAL: `/root/.claude/pal/custom_models.json` lives inside the
existing home mount above, seeded by `entrypoint.sh` from an image-baked default only if
absent — edit it directly on the host and it survives a rebuild (see §4a).

Do not change any destination path without updating the unRAID CA template in step — changing
a mapping orphans existing state.

### Network

Default `bridge` network (172.17.x range). Not on any custom/overlay network.

## 2. Verified tooling versions

Measured directly in the running container (do not trust older numbers without re-checking —
see §6 on why versions drift silently on force-update):

| Item | Verified value | Verified how |
|---|---|---|
| Docker CLI | `29.7.2`, build `a7dcaa6` (Docker CE, not `docker.io`) | `docker --version` |
| `ps`, `free`, `top` | present at `/usr/bin/{ps,free,top}` (procps) | `which ps free top` |
| Claude Code CLI | `2.1.259` | `claude --version` inside a login shell |
| PAL MCP server | `9.8.2` (SHA `fa78edca0b6bc04ab00ddf5694d855f1b946b87d`), 6 live tools
  (`consensus`, `codereview`, `precommit`, `challenge`, plus hardcoded-essential
  `listmodels`/`version`) | `/opt/pal-mcp/venv/bin/pal-mcp-server` MCP `initialize` +
  `tools/list` handshake, see `test/pal_mcp_handshake.py` |
| Security scanners | `semgrep` 1.176.0, `osv-scanner` 2.5.1, `trufflehog` 3.97.4,
  `hadolint` 2.15.1 — all pinned in the Dockerfile, the three binaries SHA256-verified on
  download. `semgrep` lives in a venv at `/opt/semgrep` and is exposed only by a symlink, so the
  venv never shadows `python3`/`pip`. The osv-scanner offline DB is on the persisted mount, not
  in the image | `test/smoke.sh` asserts each pinned version, and asserts the venv stays off
  `PATH` |
| `claude-wrapper.sh` / `_claude_auto_retry` | sourced correctly; a non-zero exit from the
  wrapper's retry function propagates to the caller's `$?` | forced a `return 7` and confirmed
  `claude foo; echo $?` printed `7` |
| Remote Control sessions running | **10 of 11** onboarded projects (dirs with a `CLAUDE.md`)
  had a live `claude remote-control` process | see §7, "10 vs 11" |
| `~/claude-remote-logs` | ~200MB total, one log per project, capped by a background loop | `du -sh`, and `cap_remote_control_logs_loop` confirmed both running (`ps aux`) and present in
  `entrypoint.sh` |
| `uv` | `0.12.15`, GitHub release tarball, SHA256-verified on download | `uv --version` |
| uv-managed Python | `3.14.7` at `/usr/local/bin/python3.14` (managed install under
  `/opt/uv-python`); system `python3` at `/usr/bin/python3` stays Debian's `3.11.2`, untouched |
  `python3.14 --version`, `python3 --version` |
| `yamllint` | `1.29.0` (Debian `bookworm` package, not pinned by this repo — tracks whatever
  `apt` resolves) | `yamllint --version` |
| `ha-yaml-check` | `/usr/local/bin/ha-yaml-check`, from `scripts/ha-yaml-check.py` | `ha-yaml-check FILE` |
| Connector image support | `read_file` returns an MCP image block for PNG/JPEG/GIF/WebP
  (magic-byte detection), capped at `MAX_IMAGE_BYTES` (default 5,000,000 bytes decoded, ~6.7MB
  once base64-encoded — comfortably under the 10MB base64-per-image limit the Claude API and
  claude.ai document); text files unchanged | `test/connector_image_check.py`, driven behaviourally
  against a real MCP endpoint the same way `test/connector_timeout_check.py` does |

Re-run these checks after any force-update rather than assuming they still hold — a recreate
can silently change installed tool versions if the image changed.

## 3. Filesystem: persistent vs not

- `/projects/<name>` is the **persistent, bind-mounted** path (`…/appdata/claude-code/projects`
  on the host). This is where project repos and their `CLAUDE.md` live, and it survives
  container recreation.
- `~/projects` (i.e. `/root/projects`) is **not** the same thing and is **not** persisted —
  don't create work there expecting it to survive a restart.
- `/projects/.worktrees/` holds per-session git worktrees (see §5a). Dotted deliberately, so
  the `*/` glob used by the Remote Control launcher and by project listings skips it —
  worktrees are not projects and must not appear as such.

## 4. The MCP connector (`connector/`)

- Node/Express service in `connector/src/index.ts`, built into `/opt/claude-code-connector`,
  started by `entrypoint.sh` on port 8765 **only if `CONNECTOR_TOKEN` is set** (bearer-token
  auth is the entire security boundary — see CLAUDE.md's non-negotiable constraint #7).
- Its `run_command` tool is an arbitrary shell running as root inside a container that holds
  the Docker socket — this is effectively root on the unRAID box. Treat any credential that
  reaches this connector as a full host compromise if leaked.
- The `~/.claude/settings.json` permission deny list (destructive `docker`/`rm`/`mkfs`/`dd`
  commands) still applies to commands run through the connector, same as an interactive
  session — it is not bypassed by `run_command`.
- Session state is **in-memory only**. A connector restart (image update, container restart)
  wipes every session id it knew about. As of v0.21, a request carrying an unknown/expired
  `Mcp-Session-Id` gets **HTTP 404** (not 400), which is what makes a spec-compliant client
  re-initialise automatically instead of getting permanently stuck — see CHANGELOG 0.21 for the
  full spec citation. A request with no session id at all (other than `initialize`) still
  correctly gets 400 — don't "fix" that path, it's correct per spec.
- **Transport timeout gotcha:** a blocking MCP tool call is abandoned by the *client* after a
  fixed period, regardless of the `wait_seconds` argument passed. The figure is
  **client-dependent** — this doc long said ~60s, and a `run_command` with `wait_seconds: 300`
  was measured returning `timed out after 180s` on 8 Sep 2026 — so never hardcode it. A
  timeout does **not** mean the underlying job failed or wasn't started; the job runs on
  perfectly. Call `list_jobs` to find it (`status: running`) and poll `get_job` on that job id
  instead of re-issuing the original command.
- Since 0.27 the connector no longer leaves this to chance: every blocking wait is clamped to
  **`MAX_WAIT_SECONDS`** (default 55s), and a clamped call returns a `wait_clamped` object
  explaining why, alongside both `job_id` and `session_id` so the run stays recoverable. Set it
  below whatever your client's ceiling actually is; the default is deliberately conservative
  because the ceiling has been seen at both ~60s and 180s.
- **Two different timeouts, and confusing them is expensive.** They are unrelated and have
  opposite consequences:

  | | What it is | Effect | Fixable here? |
  |---|---|---|---|
  | **client ceiling** (~60s–180s, client-dependent) | Transport gives up on a blocking call (client/proxy side, above the connector) | Cosmetic. Forces polling — the stop-start rhythm. **The job keeps running.** | Not ours, but bounded by `MAX_WAIT_SECONDS` since 0.27 |
  | **`DEFAULT_TIMEOUT_MS`** | The connector's own wall-clock timer | Kills the job: SIGTERM, then SIGKILL after `KILL_GRACE_MS`. Work stops mid-flight | Yes |
  | **`IDLE_TIMEOUT_MS`** | The connector's stalled-job timer (0 = off, and off by default) | Same kill, but only when nothing has happened for that long | Yes |

  The chunky stop-start progress people notice is the *first* one and is harmless. If a long
  job silently loses its work, that is the *second* one. A session once concluded the
  connector "cuts the connection after about four minutes", treated the chunking as the
  explanation, and carried on while its long jobs were being killed.
- **Job timeout (`DEFAULT_TIMEOUT_MS`).** Applies when a caller omits `timeout_seconds`.
  Set in the unRAID template — **the value is in MILLISECONDS** (`1800000` = 30 minutes);
  `1800` would be 1.8 seconds. The built-in fallback is also 30 minutes as of 0.26 (it was
  5 minutes before, which routinely killed `/feature` runs that included an image build).
  Exceeding it is a hard `SIGKILL`: no cleanup, no exit code, and a session killed mid-write
  can leave a partial file or a dirty tree. `cancel_job` is the graceful path — it sends
  `SIGTERM`.
- **Why `timeout_seconds` deliberately has no per-tool default on `start_session` /
  `continue_session`.** Giving them one would make `opts.timeoutMs` always defined, shadowing
  `DEFAULT_TIMEOUT_MS` and silently making the template variable inert — you would set it,
  see no change, and have no way to tell why. The omitted case must keep falling through to
  the env var. `run_command` is the exception and legitimately defaults to 600s.
- Since 0.26 a killed job **announces itself**: the result carries a `timeout` object with the
  effective seconds and a pointer at `timeout_seconds`. Before that it returned a bare
  `status: "timeout"` with no `finished_at`, which was easy to misread as a hang. If you see
  that bare shape, the connector is older than 0.26.
- **Since 0.27 the kill is graceful and the object says what really happened.** `timeout` now
  carries `kind` (`wall_clock` or `idle`), the signal the process actually died from, and
  `escalated`. The sequence is SIGTERM, then SIGKILL only if the process is still alive after
  `KILL_GRACE_MS` (default 10s) — so `signal: "SIGTERM", escalated: false` means it shut down
  cleanly and its transcript was flushed, while `signal: "SIGKILL", escalated: true` means it
  ignored the graceful signal and no cleanup ran. `cancel_job` uses the same escalation, so it
  can no longer hang on an unresponsive child. Signals go to the process *group* (jobs are
  spawned `detached`): killing `bash -lc` alone used to orphan the real work, which kept
  running and held the pipe open.
- **Watching a running job (`progress_events`, 0.27).** A `claude -p --output-format json` job
  prints nothing on stdout until it finishes, so `get_job` used to look identical for a busy
  job and a hung one. Pass `progress_events: N` to `get_job` (or to
  `start_session`/`continue_session`) to get the last N events from the session transcript the
  job is writing. It is a tail read of the last 256KB only — these files reach tens of
  megabytes — and it is read-only, so watching never disturbs the session. If a job shows no
  progress *and* no transcript growth, it really is stuck; that is also exactly what
  `IDLE_TIMEOUT_MS` keys off.
- **New env vars in 0.27, all with working defaults — none is required, and the unRAID CA
  template does not carry them yet.** If you want to change any of them, **add them by hand**
  to the template as plain `-e` variables (they are not secrets, and none of them is a path
  mapping — do not touch those):

  | Variable | Default | What it does |
  |---|---|---|
  | `MAX_WAIT_SECONDS` | `55` | Ceiling on any blocking wait, in **seconds**. Keep it under your client's transport ceiling. |
  | `IDLE_TIMEOUT_MS` | `0` (disabled) | **Milliseconds.** Kill a job that has made no progress for this long. Deliberately off by default so `DEFAULT_TIMEOUT_MS` keeps its 0.26 meaning. |
  | `KILL_GRACE_MS` | `10000` | **Milliseconds** between the SIGTERM and the SIGKILL. |

## 4a. PAL MCP server (code-review advisor)

- Baked at `/opt/pal-mcp` (not `/root` — shadowed by the persisted home mount, same reasoning
  as `/opt/android-cmdline-tools`). Upstream is `BeehiveInnovations/pal-mcp-server`, cloned
  Git-only and SHA-pinned (never PyPI — the `pal-mcp-server` PyPI project is a separate,
  apparently name-squatted release line unrelated to GitHub's 9.x). Deps are installed
  `--no-deps` from the committed `pal-requirements.lock.txt`.
- **Trap:** upstream's `mcp>=1.0.0` is unpinned and resolves to `mcp==2.1.1`, which removes
  `Server.list_tools` and crashes PAL at import. The lock file pins `mcp==1.29.1` explicitly —
  `test/smoke.sh` has a static check guarding this pin; do not let it drift.
  `DISABLED_TOOLS` (Dockerfile `ENV`) trims the 18 upstream tools to 6 live ones —
  `version`/`listmodels` are hardcoded `ESSENTIAL_TOOLS` in PAL's `server.py` and cannot be
  disabled.
- Wired to AWS Bedrock ap-southeast-2 as an OpenAI-compatible custom provider
  (`CUSTOM_API_URL`). `CUSTOM_API_KEY` is supplied **only** via the CA template
  (`templates/claude-code.xml`, `!secret claude-code/bedrock-api-key`, masked) — never baked
  into the image, entrypoint, or any log line. PAL reads it straight from the process
  environment; it's never written into `.claude.json`.
- `entrypoint.sh` idempotently registers PAL as a user-scope stdio MCP server
  (`claude mcp get pal || claude mcp add ...`), before anything else touches `.claude.json`
  (avoids a write race with the Remote Control auto-launch further down).
- **Trap:** the non-secret `-e` values (`CUSTOM_API_URL`, `DISABLED_TOOLS`, etc.) are frozen
  into `.claude.json` at first registration. Because registration is idempotent, a later
  Dockerfile `ENV` change to any of them is silently inert on an existing persisted home —
  `claude mcp remove -s user pal` and let the next start re-register to pick up a change.
- PAL is an advisor only — it has no repository write access, and nothing in this wiring grants
  it one.
- **MCP servers, PAL included, ARE available in headless `claude -p` sessions — and the
  `permissions.allow` list in `~/.claude/settings.json` IS honoured there.** Several sessions
  have claimed the opposite and reached for the OpenRouter API directly as a workaround. That
  advice is wrong; don't repeat it. The six `mcp__pal__*` tools are listed under
  `permissions.allow`, so they run without prompting in `-p` runs.

  Verified 2026-09-12 with two `claude -p` arms under identical
  `--permission-mode manual --permission-prompts none` (which denies anything not
  pre-approved): `mcp__pal__version` succeeded and returned real output, while a `Write` to
  `/tmp` was denied and the file never appeared. The contrast is the proof — permissions were
  genuinely enforced, so only the allow-list entry could have permitted the PAL call.
- **Don't test permissions through the connector.** `entrypoint.sh` sets `SKIP_PERMISSIONS=1`,
  and `connector/src/index.ts` turns that into `--dangerously-skip-permissions` on every
  `start_session`/`continue_session` (unless `permission_mode` is passed explicitly). A
  connector-driven session therefore never prompts regardless of the allow list, so it can
  confirm MCP *availability* but tells you nothing about *permissions*. Use a direct
  `claude -p` invocation for that.

## 4b. uv-managed Python 3.14, and HA YAML linting (issue #18)

- **Why it exists.** The live HA is `2026.9.1`; its `pyproject.toml` requires
  `python_requires >= 3.14.2`, and `pytest-homeassistant-custom-component` 0.13.365 requires
  `>= 3.14`. The image's system Python (Debian bookworm's `3.11.2` at `/usr/bin/python3`) can
  run neither, so ha-config and nectr-energy tests were stubbing every `homeassistant` import
  instead of running against real HA. `uv` + a managed Python 3.14 close that gap without
  touching system Python.
- **Where it lives, and why.** `uv` itself is at `/usr/local/bin` (a pinned, SHA256-verified
  GitHub release tarball, same pattern as osv-scanner/trufflehog/hadolint). The managed
  interpreter is baked at `UV_PYTHON_INSTALL_DIR=/opt/uv-python` — **not** `/root`, which is
  bind-mounted from the persisted appdata home at runtime and would shadow anything the image
  put there (the same trap as the Android cmdline-tools and PAL). `UV_PYTHON_BIN_DIR=/usr/local/bin`
  is where `uv python install 3.14.7` links the versioned `python3.14` executable; without
  `--default`, this never touches or shadows the unversioned `python`/`pip` that Debian's
  system Python owns.
- **`UV_PYTHON_DOWNLOADS=manual`.** This is a deliberate runtime restriction, not just a build-time
  one: if a session runs `uv python install <some other version>` at runtime, it lands under
  `/opt/uv-python` same as the baked 3.14.7 — but `/opt` is **not** on the persisted mounts (see
  §1), so that extra interpreter is silently lost on the next image rebuild/recreate, while
  anything that depended on it keeps working until then. `manual` doesn't prevent the runtime
  install itself (explicit `uv python install` is still allowed); it prevents an *implicit*
  download when some other command (e.g. `uv venv --python 3.12`) can't find a matching
  interpreter — that would otherwise silently fetch one over the network rather than erroring,
  which is worse for a container whose Python footprint is supposed to be exactly what's baked in.
- **Per-project venv recipe:**
  ```
  uv venv --python 3.14 .venv
  . .venv/bin/activate
  uv pip install pytest-homeassistant-custom-component==0.13.365
  ```
  This resolves to the baked 3.14.7 (not a fresh download, per the `manual` setting above).
- **Trap: pytest-asyncio's default `strict` mode doesn't pick up `pytest-homeassistant-custom-component`'s
  autouse async fixtures** (e.g. `configure_event_loop`). A test using the `hass` fixture fails
  at setup with `PytestRemovedIn9Warning: ... requested an async fixture ... with no plugin or
  hook that handled it`, even with `@pytest.mark.asyncio` on the test itself — the mark doesn't
  extend to the plugin's own fixtures. Fix: run with `--asyncio-mode=auto` (or set
  `asyncio_mode = auto` in the project's `pytest.ini`/`pyproject.toml`), not a per-test mark.
  `test/smoke.sh`'s HA venv stage does this; `test/fixtures/ha_smoke_test.py` is the minimal
  real-`hass`-fixture test it runs.
- **HA YAML linting.** `python3 -c 'import yaml'` and `yamllint` work against the **system**
  Python (Debian's `python3-yaml`/`yamllint` packages — not a pip install into system Python,
  which bookworm's PEP-668-externally-managed Python refuses by default). `pip3`/`python3 -m
  venv` also work now (`python3-pip`/`python3-venv`), for anything that wants its own venv
  without needing uv. `python3-pil`/ImageMagick were judged not worth the image weight: the
  issue calls them minor with no acceptance criterion.
- **`ha-yaml-check`** (`scripts/ha-yaml-check.py` → `/usr/local/bin/ha-yaml-check`): a PyYAML
  `SafeLoader` subclass that registers an opaque constructor for exactly HA's eight custom
  tags (`!secret`, `!include`, `!include_dir_list`, `!include_dir_named`,
  `!include_dir_merge_list`, `!include_dir_merge_named`, `!env_var`, `!input`) rather than a
  `!`-prefix multi-constructor — a prefix match would silently accept a typo'd tag (e.g.
  `!secrets`) as valid instead of reporting it, and HA would then fail to resolve it for real
  at load time. A genuine syntax error, or any tag outside that exact list, is reported as
  `file:line: message` and exits non-zero. It validates syntax only, not HA schema semantics.
  Recommended `yamllint` config for HA configs (put in `.yamllint` at the config root):
  ```yaml
  extends: default
  rules:
    line-length: disable
    document-start: disable
    truthy:
      allowed-values: ["true", "false", "on", "off"]
  ```
  (HA's YAML makes heavy use of `on`/`off` truthy values and long `value_template` lines that
  standard yamllint would otherwise flag.)
- **Not attempted here — see §8.** Whether `hass --script check_config -c <copy of /config>`
  catches the class of `template:` platform-schema errors that the REST `check_config` misses
  is still open; the custom components' own requirements may make it impractical.

## 5. The `/feature` workflow

The standing primer is `~/.claude/commands/feature.md` — read it directly for the current text
rather than trusting a summary, it changes. As of this writing it no longer references
`local-llm` (gpt-oss:120b via host Ollama, retired — it hallucinated on log summaries; read
logs and diffs directly instead).

Shape of a good invocation via `start_session`/`continue_session`:

1. State the concrete behaviour change and cite the spec/root-cause if there is one — don't
   make the agent re-derive a diagnosis you already have.
2. Name the exact files/line ranges involved if known, and the exact test command
   (`bash test/smoke.sh` for this repo — the only harness, slow, needs the Docker socket).
3. State the scope boundary explicitly (which directories/files are in play).
4. Require a genuine RED baseline before any implementation change, and a full green re-run
   after, not just the new checks — this repo's smoke suite also covers unrelated tooling
   (procps, Playwright, Android SDK) that must not regress.
5. State the versioning rule (see below) so the agent doesn't invent a version number.
6. Say explicitly whether the container may be restarted/force-updated as part of the run (for
   this repo: normally **no** — a `/feature` run on `claude-code-unraid` should be a pure
   source+CI change; the running container doesn't need to change for the work to be "done",
   and restarting it kills every Remote Control session sharing that container, including the
   one doing the work).

**Versioning:** MAJOR.MINOR. MINOR is a plain integer counter, incremented by one per
commit-worthy change (0.1, 0.2, … 0.20, 0.21, …). MAJOR only ever advances on Kieren's explicit
declaration of a milestone — never round up to 1.0 on your own initiative.

**Before dispatching a new `/feature` run, check `list_jobs` and `git status` first.** An
interrupted earlier session can leave a `/feature` run still active (or resumable) with
uncommitted work already in the tree — starting a duplicate run on the same repo risks two
agents editing the same files/branch concurrently. If `git status` shows uncommitted changes
that look like an in-progress feature (matching a CHANGELOG `[Unreleased]` entry, say), check
`list_jobs` for a running `claude`-kind job on this project before starting a new one.

## 5a. Concurrent sessions and git worktrees

Several sessions can be live in the same repo at once — a Cowork chat driving the connector, a
scheduled run, and whatever is open interactively. They share one checkout at
`/projects/<name>`, so without isolation one lands on another's branch or commits into another's
dirty working tree.

**Any session that WRITES to a shared repo takes its own worktree.** Read-only investigation
does not need one.

```
git -C /projects/<project> worktree prune
git -C /projects/<project> fetch origin
git -C /projects/<project> worktree add -b <branch> \
    /projects/.worktrees/<project>-<slug> origin/main
cd /projects/.worktrees/<project>-<slug>
```

- **Branch from `origin/main`, not local `main`.** Two reasons: the local ref goes stale (the
  push-based merge below never updates it), and `main` may be checked out in the shared
  checkout, which makes it unavailable to a worktree.
- **Merge by pushing, never by checking out `main`.** `git push origin HEAD:main` is
  fast-forward only, so it **fails if `main` moved** since the worktree was cut — that failure
  is the collision detector, not an obstacle. Rebase onto the new `origin/main`, re-run the
  suite, push again. Never force.
- **`git worktree add` refusing a branch already checked out elsewhere is the protection
  working.** Pick a different slug; never `--force` past it.
- **Prune on the way IN, not just on the way out.** The connector SIGKILLs a job at its timeout
  (see §4), and SIGKILL runs no cleanup — so a killed session leaves its worktree behind by
  design, not by accident.

**What a worktree does NOT isolate: the deploy target.** `ha-config`'s deploy step copies files
onto a running Home Assistant via the SMB mount at `/ha-config` — a separate filesystem, outside
git entirely. Two sessions in two clean worktrees can still both write there. Worktrees solve
branch collisions; concurrent deploys to a live system need their own lock or a one-at-a-time
rule, and that is still an open question for `ha-config`.

Why this is written down: six worktrees from the September 2026 counsel evaluation
(`_replay-butler` and friends) sat in `/projects/` for twelve days — 61 MB, and counted as
projects by the `*/` glob — before being cleaned up on 16 Sep. That is the failure mode this
convention exists to prevent, hence the dotted directory and prune-on-entry.

## 6. Force-updating the container

Procedure, run **from the host**, not from inside the container being updated (the update kills
the container the session is running in, so an in-container SSH-to-self approach commits
suicide mid-script):

```
ssh -i /root/.ssh/unraid_secretsman root@192.168.0.10
setsid nohup /usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container claude-code
```

`setsid nohup` detaches it from the SSH session, because the script kills the container the SSH
session may itself be running through.

**Cost:** this pulls the new image, recreates the container, and drops:

- Every Remote Control session for every `/projects/<name>` (all reconnect only if their
  workspace trust was already accepted and the entrypoint's auto-launch picks them up again —
  see §7).
- The `claude-code-connector` MCP server and all of its in-memory job/session state — any
  Cowork chat connected to it needs to reconnect and, pre-v0.21, would get stuck forever if it
  reused an old session id (fixed in 0.21, see §4).

Restart policy is **`unless-stopped`** as of 8 Sep 2026 — applied to the live container with
`docker update --restart unless-stopped claude-code`, and persisted in the CA template's
`ExtraParams` so a future recreate keeps it (unRAID has no restart-policy field of its own;
it goes in Extra Parameters).

**That does not retire the watchdog, and the distinction matters.** `unless-stopped` restarts a
container that *exits* — a crash, an OOM kill, a Docker daemon or host restart. It does nothing
about a recreate that fails before a container exists, or one created but never started, which
is exactly the force-update failure mode the watchdog is for. Still check `docker ps -a` after a
force-update rather than assuming it came back up.

A container **recreate** (e.g. editing the CA template and hitting Apply) uses the already
pulled/cached image and does **not** pull a new one — only a genuine force-update
(`update_container`) pulls. Don't confuse the two when trying to explain "why didn't my new
image take effect."

## 7. Traps and lessons

- **A finished job is not a completed task.** A headless `claude -p` session can end its turn
  mid-work — one ended with "I'll wait for the smoke test to finish before continuing", which
  it cannot do, since ending the turn ends the run. The job reported `status: done` and
  `exit_code: 0` with only a checkpoint commit and nothing implemented. Always verify a
  hand-back against `git log` and the working tree, never against the job's status field.
- **`/proc/uptime` inside this container reports the HOST's uptime**, not the container's. Use
  `docker inspect --format '{{.State.StartedAt}}' claude-code'` (run from the host, or via SSH)
  to find when the container itself actually started.
- **Never pattern-kill processes by matching a string against `/proc/*/cmdline`.** An agent's
  own prompt text can contain the very string you're trying to match against a *different*
  process, and you can kill your own run. Match on a stable identifier (PID captured at spawn
  time, a job id from `list_jobs`) instead.
- **Verify a `/feature` hand-back by executing the result, not by reading the diff.** A shipped
  "all green" summary has previously contained a real defect that only showed up when the code
  actually ran (see CHANGELOG 0.20 — a log-capping bug that looked correct on read-through).
  Re-run the specific test/assertion yourself before treating a run as done.
- **10 vs 11 Remote Control sessions:** eleven `/projects/*` dirs currently have a `CLAUDE.md`
  (the signal `launch_remote_control_sessions` uses to auto-launch a session at container
  start), but only ten actually launch. `unraid-multinet` fails with `Error: Workspace not
  trusted. Please run 'claude' in /projects/unraid-multinet first to review and accept the
  workspace trust dialog.` — its workspace trust has never been accepted interactively. This is
  independent of the connector's session-restart bug in §4; don't conflate the two. Fix: run
  `claude` interactively in that directory once to accept the trust dialog, then the next
  container start (or force-update) will pick it up.
- **A genuinely-running background job can outlive an early "done" status from a polling tool
  call that returned before the process actually finished** — if a result looks implausibly
  fast for what it claims to have done (e.g. a full multi-stage smoke suite reporting a result
  in under a minute when the same suite normally takes longer, or reporting failures in stages
  that hadn't had time to even start), re-check before trusting it: `ps aux` for the actual
  process, `docker ps -a` for containers it should have created, and re-poll rather than taking
  the first result at face value.

- **Headless default-mode sessions have a working-directory path guard on Bash — and it
  is not a sign that a script is unreachable.** With `permission_mode: default` (as every
  Cowork-driven `/feature` run passes), the Bash tool refuses `ls`/`cat`/`mkdir`, input
  *and* output redirection on paths outside the session's allowed directories, and treats a
  `cp` **from** anything under `~/.claude` as an edit of a sensitive file (a hang/deny in
  `-p`). It does **not** guard script execution (`bash <script>`, `python3 <script>`) or the
  `Read` tool. Three `/feature` runs on unraid-dormouse (13–15 Sep 2026) probed with
  `ls ~/.claude/review-lib`, got blocked, and skipped the whole `code-diff-reviewer`
  pipeline. Fixed 15 Sep 2026 without an image change:
  - `~/.claude/settings.json` → `permissions.additionalDirectories:
    ["/root/.claude/review-lib", "/tmp/claude-review"]`. This makes `ls`/`cat`/`mkdir` work
    there, but **not** the `cp`-from-`~/.claude` block and **not** output redirection, and a
    listed directory that does not exist when the session starts is silently dropped —
    `/tmp/claude-review` is gone after every container restart until the first review run
    recreates it. `--add-dir` on the connector's `claude -p` line was tested and behaves
    identically, so it was not added (it would have needed a force-update for no gain).
  - `~/.claude/review-lib/run-passes.sh` now takes `--template diff|module|security
    --brief TEXT` and makes its own run directory under `/tmp/claude-review` (first output
    line `out=<dir>`); omit `--template` with an existing `--out` to reuse its `prompt.md`.
    New `run-scanners.sh` does the same for `code-security-audit`'s scanners. The three
    review skills and `/feature` step 18 no longer contain any blocked shape, and say "run,
    don't probe". Pre-change copies: `~/.claude/backups/review-path-guard-20260915/`.
  - Verified with a connector `start_session` in `default` mode on unraid-dormouse: three
    passes, union and score all ran, `started_in_background=0` on each.
  - Related trap found on the way: skill bodies substitute `$0`, `$1`… with the invocation
    arguments, so `US$0.15` rendered as `US/projects/unraid-dormouse.15`. Write currency as
    `0.15 USD` in skills and commands.

## 8. Open items

a. `claude-auto-retry`'s retry logic has never been proven end-to-end against a real rate
   limit — only unit-level/synthetic exit-code propagation has been verified (see §2).

b. ttyd (browser terminal, port 7681, `TTYD_CREDENTIAL`-gated) copy/paste via OSC 52 is parked;
   ttyd is a manual fallback only. It's served on a raw IP, so browser automation against it
   would need per-action approval and is impractical as a driving mechanism — don't build
   tooling that assumes it can be automated.

c. `/projects/butler-preflight-20260808/` is an unidentified early Butler prototype snapshot
   (git repo, `Dockerfile`, `inventory.db`, "Stage 3" files, dated 26 Jul – 8 Aug, ~1.2MB).
   Awaiting Kieren's decision on whether to keep it. Do not delete or modify without asking.

d. `/projects/_archive/` holds `monitor.js.txt` and `patterns.js.txt` — debug artefacts, safe
   to delete whenever someone gets around to it.

e. **`-c`/`--continue` correction:** it was previously believed `--continue` was unusable with
   Remote Control (thought incompatible with `--spawn`). `claude remote-control --help` now
   lists `-c, --continue` to reattach to the session last recorded for a directory (roughly a
   4-hour window), and the entrypoint's auto-launch never passes `--spawn`. A
   `claude remote-control -c || claude remote-control` fallback in
   `scripts/remote-control-launch.sh` might let sessions survive a force-update restart intact.
   **This is untested** — treat it as a candidate for its own `/feature`, not something to fold
   into an unrelated change.

f. **Whether `hass --script check_config -c <copy of /config>` catches the `template:`
   platform-schema errors that the REST `check_config` misses is untested** (issue #18,
   surfaced during the 2026-09-13 `device_id` incident). Now that a real Python 3.14 + HA test
   environment exists (§4b), this is worth trying — but the custom components' own dependency
   requirements may make it impractical. Not attempted in the #18 change; treat as a candidate
   for its own follow-up.

g. **`test/connector_timeout_check.py`'s `mode_idle` forked-session check is intermittently
   flaky for a different reason than its neighbouring comment documents** (found investigating
   #18's smoke run, 16 Sep 2026). The comment above the fake-claude stub's `ACTIVE=1` branch
   attributes flakiness to a 0.25s heartbeat against a 2s idle timer leaving only 1s of slack
   under host load. That mechanism is real, but a *separate* failure was also observed: the
   "progress followed the stale session-id file instead of the one being written" assertion
   (checking that a resumed session which forks to a new transcript id is tracked via the file
   actually being written, not the stale one named by the original session id) fails
   intermittently — roughly 1-in-3 in a small sample — with `transcript_path` pointing at a
   random UUID-named file that matches neither the expected `forked-parent-fork.jsonl` nor the
   stale `forked-parent.jsonl`. **Reproduced against an unmodified pre-#18 build** in isolated,
   single-container, single-invocation runs (no concurrent load from this or other test
   stages), so it is pre-existing in `connector/src/index.ts`'s session-transcript-following
   logic, not something #18 introduced or made worse. Root cause not investigated further —
   candidate for its own `/feature` run, starting from `mode_idle` in
   `test/connector_timeout_check.py` and the `continue_session`/progress-tail code around the
   `encodeProjectDir`/transcript-selection logic in `connector/src/index.ts`.

## 9. Scope reminder

Each project under `/projects/` has its own chat — this repo's chat is for the container image
itself (Dockerfile, entrypoint, connector, wrappers, Remote Control launch, permissions,
tooling versions). Do not modify `/projects/butler` or any other project from here, and don't
pull a project-level issue into this thread — write a short, self-contained prompt for that
project's own chat instead.
