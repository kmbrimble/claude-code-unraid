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

Re-run these checks after any force-update rather than assuming they still hold — a recreate
can silently change installed tool versions if the image changed.

## 3. Filesystem: persistent vs not

- `/projects/<name>` is the **persistent, bind-mounted** path (`…/appdata/claude-code/projects`
  on the host). This is where project repos and their `CLAUDE.md` live, and it survives
  container recreation.
- `~/projects` (i.e. `/root/projects`) is **not** the same thing and is **not** persisted —
  don't create work there expecting it to survive a restart.

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

## 9. Scope reminder

Each project under `/projects/` has its own chat — this repo's chat is for the container image
itself (Dockerfile, entrypoint, connector, wrappers, Remote Control launch, permissions,
tooling versions). Do not modify `/projects/butler` or any other project from here, and don't
pull a project-level issue into this thread — write a short, self-contained prompt for that
project's own chat instead.
