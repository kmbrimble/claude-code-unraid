# Operations reference — claude-code-unraid

Living reference for whoever operates this container next. Not a changelog and not a narrative
— see `CHANGELOG.md` and git history for what happened and when. Keep this tight and update it
in place as facts change.

## What this is

This repo builds the Docker image for the Claude Code agent container you are running inside
right now — the "container chat" for the whole `/projects` tree.

- Repo (in container): `/projects/claude-code-unraid`
- GitHub: `kmbrimble/claude-code-unraid`
- Published image: `ghcr.io/kmbrimble/claude-code-unraid:latest`
- Live container: `claude-code`, restart policy `no` (a failed recreate leaves it **stopped**,
  not restarted)
- Host: unRAID **7.3.1** at `192.168.0.10`. The host itself has **no `python3`** — anything that
  needs Python must run inside a container, not via SSH on the host directly.

### Mounts (do not change destination paths — see CLAUDE.md constraint 1)

| Host path | Container path | Contents |
|---|---|---|
| `/mnt/user/appdata/claude-code/home` | `/root` | auth, settings, agents, commands, MCP config |
| `/mnt/user/appdata/claude-code/projects` | `/projects` | **the persistent, bind-mounted project tree** |
| `/mnt/user/appdata/claude-code/config` | `/config` | misc config |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker socket (see Connector section — this is real power) |

`/projects/<name>` is the persistent path; anything written under `~/projects` (i.e. `/root/projects`,
a different, non-bind-mounted directory) is **not** persisted and will vanish on container
recreation. Always work under `/projects/<name>`.

## Verified tooling versions (measured 2026-09-03, image 0.20)

- Docker CE CLI: **29.7.2** (build a7dcaa6) — bumped from 20.10.24 as of image 0.20/0.19.
- `claude` CLI: **2.1.259**.
- `ps`, `free`, `top`: present (via `procps`, added in 0.19).
- `claude-auto-retry` wrapper: non-zero exit codes propagate correctly through the `claude`
  shell function (verified: a stubbed `_claude_auto_retry` returning 7 propagates as `$?` = 7).

Re-measure after every image update rather than trusting this table — it is a snapshot, not a
guarantee.

## The MCP connector (`connector/`, port 8765)

- What it is: an MCP-over-HTTP server (Streamable HTTP transport) that lets a Claude client
  (e.g. Cowork) drive this container's `claude` CLI remotely via tools like `run_command`,
  `start_session`, `read_file`.
- **`run_command` runs `bash -lc` as root, in a container that holds the Docker socket. This is
  effectively root on the unRAID host.** Treat every connector session accordingly.
- Only starts when `CONNECTOR_TOKEN` is set (CLAUDE.md non-negotiable #7); requests to `/mcp`
  require `Authorization: Bearer <token>` or get 401.
- The `~/.claude/settings.json` permission deny list still applies to everything the connector
  runs (it denies e.g. `rm -rf /*`, `mkfs*`, `dd if=*`, `docker kill:*`, and more) — the
  connector does not bypass Claude Code's own permission system.
- **Session handling**: sessions are kept in an in-memory map, keyed by `Mcp-Session-Id`. A
  connector restart (which happens on every container force-update) wipes that map. As of
  **0.21**, an unknown/expired session id gets **HTTP 404** (spec: MCP Streamable HTTP,
  revision 2025-06-18, "Session Management" — 404 is the only status that makes a compliant
  client transparently re-initialise). A request with no session id header at all on a
  non-`initialize` call still correctly gets 400. If you ever see a client stuck forever on
  `HTTP 400 "no valid session"` after a restart, that is this bug reintroduced — check
  `connector/src/index.ts`'s `POST /mcp` and `handleSessionReq` handlers first.
- **Transport timeout gotcha**: `start_session` / `get_job` calls from the client side time out
  at ~60s regardless of the `wait_seconds` argument passed. This is a transport-level limit, not
  a job failure. If a call times out, **do not assume the job died** — call `list_jobs` to find
  the actually-running job and poll `get_job` on that job id instead of restarting the work.

## The `/feature` workflow

Full current text lives in `~/.claude/commands/feature.md` — read it fresh each time you invoke
it, since it changes. As of 2026-09, it no longer references `local-llm` (a local Ollama
summarisation model that was retired — it hallucinated on log summaries; there is no local
summarisation fallback now, only direct reading of logs/diffs/test output).

Shape of a good invocation:
- State the bug/feature precisely, including exact file paths, line numbers, and code snippets
  where you already know them — don't make the agent rediscover what you've already found.
- Name the exact test command and what a genuine RED baseline should look like, and insist the
  agent report it explicitly rather than jumping straight to green.
- State scope explicitly (which directories/files are in play) and point at this repo's
  `CLAUDE.md` non-negotiable constraints.
- State the versioning/changelog expectation explicitly if it matters for this change.

Versioning: `MAJOR.MINOR`, where MINOR is a **plain integer counter** incremented once per
released change (0.19 → 0.20 → 0.21 → …). MAJOR is only ever bumped manually, when Kieren
declares a milestone — **never** default to 1.0.

## Force-updating the container

Performed on the unRAID host, not from inside this container (a force-update kills the container
your SSH session would otherwise be running inside, hence `setsid nohup`):

```
ssh -i /root/.ssh/unraid_secretsman root@192.168.0.10
setsid nohup /usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container claude-code &
```

**Cost**: this drops every Remote Control session (all `claude remote-control` processes die)
and restarts the connector (wiping its in-memory MCP session map — see above). Recovery is
automatic for Remote Control (`entrypoint.sh` relaunches one per `CLAUDE.md`-containing project
directory on boot) but **not instant** and **not always complete** — verify session count after
every restart, don't assume it. Because restart policy is `no`, if the recreate itself fails,
the container is left stopped, not retried.

A container **recreate** (e.g. editing the unRAID template) uses the cached image and does
**not** pull — only a genuine force-update pulls a new image. Don't confuse the two when
diagnosing "why didn't my new image take".

## Traps and lessons

- **`/proc/uptime` inside this container reports the HOST's uptime**, not the container's — it
  is not namespaced. To get the actual container start time, use:
  `docker inspect --format '{{.State.StartedAt}}' claude-code` (run this from the host, or via
  the connector's `run_command` against the host through SSH — not meaningful from inside the
  container's own `/proc`).
- A container **recreate** does not pull a new image; only a **force-update** does. Don't assume
  a template edit picked up a freshly-pushed image.
- **Never pattern-kill processes by matching `/proc/*/cmdline` (or `ps aux | grep`) against a
  string that also appears inside a running agent's own prompt text.** An earlier session killed
  its own `/feature` run this way. The same trap applies to read-only greps: a `ps aux | grep
  '<literal string>'` run from inside a `run_command` call will self-match if that literal string
  appears in the command line you just ran (it will, since the command line contains its own
  grep pattern). Use `pgrep -f` with a pattern that excludes the invoking shell, or split the
  check into its own isolated command, and sanity-check any surprising positive against a second,
  differently-phrased check before trusting it.
- **Verify a `/feature` hand-back by executing the code and reading the actual test output**,
  not by reading the diff and trusting the agent's "all green" summary. A shipped "green" change
  has previously contained a real defect (a log-cap loop that never reached a stable size) that
  only became visible when the shipped script was actually run.
- The container's background log-cap loop (`cap_remote_control_logs_loop`, sourced from
  `remote-log-cap.sh`) does not show up under its function name in `ps`/`pgrep -f` while it's
  sleeping — it appears as a bare `sleep <interval>` process whose parent is `entrypoint.sh`'s
  PID. Don't conclude it isn't running just because a name-based process search comes up empty;
  check for the `sleep` child of the entrypoint PID, or check the log files' actual sawtooth size
  pattern (should hover just under/over the `REMOTE_CONTROL_LOG_MAX_BYTES` cap, currently 20MB,
  never running away unbounded).

## Open items

- **`claude-auto-retry`'s retry logic has never been proven end-to-end against a real rate
  limit.** Exit-code propagation is verified (see tooling table above), but the actual retry
  behaviour under a genuine 429/rate-limit response from Anthropic has not been observed live.
- **ttyd (browser terminal, port 7681) is a manual fallback only.** OSC 52 copy/paste through it
  is parked/unsolved. It's served on a raw IP (no TLS, no reverse-proxy hostname), so browser
  automation against it needs per-action approval and is impractical as an automated path — treat
  it as a human-only escape hatch, password-protected via `TTYD_CREDENTIAL`.
- **`/projects/butler-preflight-20260808/`** is an unidentified early Butler prototype snapshot
  (git repo, Dockerfile, `inventory.db`, "Stage 3" files, dated 26 Jul–8 Aug, ~1.2MB). Awaiting
  Kieren's decision on whether to keep it — don't delete without asking.
- **`/projects/_archive/`** holds `monitor.js.txt` and `patterns.js.txt` — debug artefacts, safe
  to delete whenever someone gets to it.
- **`-c`/`--continue` correction**: it was previously believed `--continue` was unusable with
  Remote Control (thought incompatible with `--spawn`). `claude remote-control --help` now lists
  `-c, --continue` to reattach to the session last recorded for a directory, within roughly a
  four-hour window, and the entrypoint never actually passes `--spawn`. A
  `claude remote-control -c || claude remote-control` fallback in
  `scripts/remote-control-launch.sh` might let Remote Control sessions survive a force-update
  restart instead of starting fresh every time. **This is untested** — treat it as a candidate
  for its own dedicated `/feature`, not something to fold into an unrelated change.

## One more thing

Each project under `/projects/<name>` has its own separate chat/session. Project-internal
questions, debugging, and feature work belong there — this container's own chat is for the
image/entrypoint/connector itself, not for driving work inside individual projects.
