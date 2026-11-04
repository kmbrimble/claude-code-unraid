<!-- Moved from claude.ai Project "Claude", doc claude/connector-timeout-diagnosis.md, on 2026-11-04. -->
<!-- Known stale at move: Measured values are client-dependent and may have drifted; the how-to-drive part also lives in the homelab-lan-access skill. -->

# Connector timeouts from Cowork — diagnosis, the 0.27 fix, and how to drive it now

Diagnosed and shipped 2026-09-08. **Deployed and verified live.** Code detail lives in
`CHANGELOG.md` 0.27, `OPERATIONS.md` §4 and `connector/README.md` in `claude-code-unraid`;
this doc holds only what those can't, because it spans Cowork and the container.

## How to drive the connector now (read this part)

- **A blocking call can no longer be cut off.** Every wait is clamped to `MAX_WAIT_SECONDS`
  (55s). Ask for longer and you get the job back at 55s with a `wait_clamped` block saying so,
  plus `job_id` **and** `session_id`. Don't pass a big `wait_seconds` hoping to avoid polling —
  it does nothing except get reported back to you.
- **Poll with `get_job` and pass `progress_events: N`.** A running `claude -p` prints nothing
  until it finishes, so without this a busy job and a hung one look identical. You get the last
  N transcript events, tail-read from the last 256KB, read-only.
- **`deadline_at` tells you when a job dies.** Also `elapsed_seconds` and `timeout_seconds`, on
  both `get_job` and `list_jobs`. Check it before predicting anything about a job's fate — the
  absence of this field previously produced a confident wrong prediction (see below).
- **Long autonomous runs: pass `timeout_seconds` explicitly.** The wall clock still defaults to
  30 min (`DEFAULT_TIMEOUT_MS`) and still kills. `idle_timeout_seconds` is the better tool
  where it fits — it judges a job on progress rather than elapsed time — but `IDLE_TIMEOUT_MS`
  ships **disabled (0)** and stays that way until set in the CA template by hand.
- **A cut-off call is recoverable, always.** `list_jobs` still has the job, its `job_id` and its
  `session_id`.
- **Starting a `/feature` run over the connector?** Include the PAL tool in `allowed_tools` or
  the review's CALL band silently can't call counsel (see traps).

## The symptom was never a timeout

Cowork-driven sessions appeared to "keep timing out". Nothing was killing them. The **MCP
client** abandons a single tool call after a fixed period and reports a timeout while the job
underneath runs to completion.

Reproduced live: a `run_command` issued with `wait_seconds: 300` returned
`MCP server "Claude_Code_CLI" tool "run_command" timed out after 180s` while the underlying
job finished normally.

**The ~60s figure OPERATIONS.md carried was wrong here — 180s was measured.** Treat the
ceiling as client-dependent and never hardcode it. That is why 0.27 introduces
`MAX_WAIT_SECONDS` rather than a literal.

The trigger was `wait_seconds` declaring `.default(120).max(600)`: both can exceed the
ceiling, so the connector routinely asked the client to wait longer than it ever would.

## "Resuming by session id doesn't time out" is not a real difference

`start_session` and `continue_session` share `runProcess()` and had byte-identical timeout
handling — the only difference in `claudeArgs()` is `--session-id` vs `--resume`. The one
Claude job that ever hit the hard timeout (`c6f1a513`, 7 Sep) was itself a `--resume`. What
differs is turn length: a cold first turn outruns the ceiling, warm follow-ups don't.

## Why issue #11's ttyd/tmux approach was rejected

Connector jobs are spawned with `shell: false` and `child.stdin.end()`, and `CLAUDE_BIN`
resolves to `/usr/local/bin/claude` — not `claude-wrapper.sh`, which is a shell function that
`shell: false` never sources. Jobs are therefore plain children of the connector process: not
in a tmux pane, not on a PTY, stdin closed, nothing to type into. ttyd serves the separate
`claude` tmux session `entrypoint.sh` creates, which has no relationship to any job.

The session JSONL, by contrast, is appended to continuously while a session runs. Tailing it
gets #11's actual value — watching a running session — without re-architecting job spawning
onto PTYs or reworking `parseClaudeJson()`.

## Traps worth remembering

- **`get_job` used to hide a job's own timeout.** During diagnosis this produced a confident
  wrong prediction that a job would die at 30 minutes when it had been started with a larger
  explicit `timeout_seconds`. 0.27 adds `deadline_at` for exactly this reason.
- **A running `claude -p --output-format json` prints nothing until it finishes.** stdout
  silence says nothing about liveness; only the transcript does. Any future health or progress
  logic must use the transcript, not stdout.
- **Counsel is permission-gated in unattended MCP sessions.** A `/feature` run started via
  `start_session` scored CALL band but could not invoke `mcp__pal__codereview` — nobody was
  there to approve it — and degraded to the MID-band procedure. Include the PAL tool in
  `allowed_tools` if you want a CALL band to actually reach counsel.
- **CI builds only on push to `main`**, so an open PR has no run to watch.
- **Restart policy is `unless-stopped` as of 8 Sep 2026** — but the force-update watchdog
  stays. `unless-stopped` restarts a container that *exits*; it does nothing about a recreate
  that fails before a container exists, which is the failure mode the watchdog is for.
- **Unexplained, logged for honesty:** the tool schemas this session first loaded (before 0.27
  was written) already described `MAX_WAIT_SECONDS`, `progress_events` and
  `idle_timeout_seconds`, even though the source at `928cdf7` contained none of them and the
  `/feature` run got a genuine red baseline against an image built from it. The *behaviour*
  before the update was definitely the old one — a 300s wait ran to a 180s client cut-off with
  no `wait_clamped` in the result. Treat a schema description as weaker evidence than observed
  behaviour.
