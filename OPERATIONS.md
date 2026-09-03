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
- **Transport timeout gotcha:** `run_command` / `get_job` calls through the MCP tool front-end
  time out at ~60 seconds *at the transport layer*, regardless of the `wait_seconds` argument
  passed. A timeout does **not** mean the underlying job failed or wasn't started — call
  `list_jobs` to find the job that's actually running (it will show as `status: running`) and
  poll `get_job` on that job id instead of re-issuing the original command.

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

Restart policy on the container is `no`, so a recreate that fails leaves the container
**stopped**, not restarted — check `docker ps -a` after a force-update, don't assume it came
back up.

A container **recreate** (e.g. editing the CA template and hitting Apply) uses the already
pulled/cached image and does **not** pull a new one — only a genuine force-update
(`update_container`) pulls. Don't confuse the two when trying to explain "why didn't my new
image take effect."

## 7. Traps and lessons

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
