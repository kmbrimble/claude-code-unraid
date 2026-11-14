# Long sessions: idle timeout as the control, wall clock as a backstop (15 Nov 2026)

Status: implemented (changelog entry 15 Nov 2026). Supersedes in part
[2026-09-08-connector-timeouts.md](2026-09-08-connector-timeouts.md) (its "pass `timeout_seconds`
explicitly" advice for long runs).

## Problem

`start_session` / `continue_session` capped `timeout_seconds` at 3600 (`.max(3600)`, present since the
first connector commit 328319f with no recorded rationale), and the claude.ai skill told callers to
pass `timeout_seconds=3600`. Connector logs showed long jobs wall-clock killed at about 59-60 minutes.
A caller could not ask for more than an hour even if it wanted to.

## Findings (verified before any change)

**1a. Subagent activity did NOT count (fixed).** The idle timer judged a Claude job on one file: the
main transcript `~/.claude/projects/<cwd-key>/<session>.jsonl` (via `sessionLogPath`), plus stdout/stderr.
Claude Code writes each subagent's (Task tool, `/feature` review passes) transcript to
`~/.claude/projects/<cwd-key>/<session>/subagents/agent-*.jsonl` (seen on disk, with a `.meta.json`
beside each). While a subagent runs, the main transcript only has the `tool_use` at the start and the
`tool_result` at the end, so a long subagent run looked idle and would have been killed at the idle
threshold. Reproduced against the pre-change connector with the fake-claude stub: a job whose only
activity is in `subagents/` was killed as `idle` after 2 s. Fix: `sessionActivityMs` takes the newest
mtime over the main transcript and every `subagents/*.jsonl` of the same session. (Other siblings of the
transcript, e.g. `tool-results/`, are tool output spill files, not liveness, and are ignored.)

**1b. A single long tool call is quiet; measured.** Nothing is written to any transcript while one tool
call runs. I paired every `tool_use` with its `tool_result` across all 1722 transcripts on the persisted
mount (main and `subagents/`, 21 587 pairs) and took the gap:

| Tool | pairs | longest gap | p99 |
|---|---|---|---|
| Bash (foreground) | 18 588 | 10.0 min (exactly, repeatedly: the 600 000 ms ceiling; 8 of 10 gaps over 10 min sit there) | 4.3 min |
| `mcp__pal__thinkdeep` | 2 | **20.0 min** | 7.8 min |
| Agent (Task) | 33 | 8.3 min | 5.5 min |
| other tools (Skill, PAL consensus/codereview, Read, browser, web) | | under 2.5 min | |

Two Bash gaps (45 and 350 min) are session pauses, not a running command (a foreground Bash call is
bounded by its 10 min ceiling; this container sets neither `BASH_DEFAULT_TIMEOUT_MS` nor
`BASH_MAX_TIMEOUT_MS`). The exception that matters is a slow PAL call: 20 min once. Background tasks
(`run_in_background`) return at once, so they do not extend a quiet stretch by themselves; what a
headless `claude -p` job writes while it waits on a background task or Monitor was **not** verified.
Hence the recommended idle value is **3600 s**: three times the longest single tool call seen, and the
same as the old wall-clock cap, so a stalled run is ended within an hour rather than burning the day.
I considered treating "a child process of the job is still running" as activity and did not: it is not
robust (a hung child looks alive forever, the exact failure idle detection exists to catch) and needs
process-tree inspection. Only `subagents/` holds extra transcripts inside a session directory (the other
subdirectory, `tool-results/`, holds spilled tool output, not liveness), so that is all
`sessionActivityMs` adds.

## Decisions

- **Ceilings.** `timeout_seconds` and `idle_timeout_seconds` on `start_session` / `continue_session` go
  to **86400 (24 h)** (`MAX_CLAUDE_SECONDS`). 86 400 000 ms is far inside `setTimeout`'s 2^31-1 limit, and
  the `envInt` validation of `DEFAULT_TIMEOUT_MS` etc. is untouched. `run_command` keeps 3600 on both:
  there is no evidence it needs more, and its semantics (output-only idle) are unchanged.
- **No per-tool default on `timeout_seconds`.** Unchanged and still deliberate (OPERATIONS.md §4):
  a default would shadow `DEFAULT_TIMEOUT_MS`.
- **`IDLE_TIMEOUT_MS` stays `0`.** The env default also applies to `run_command`, where idle means
  "no output" and a quiet build or `sleep`-heavy test would be killed by a global threshold nobody
  asked for; and CLAUDE.md constraint 9 already forbids a non-zero built-in. Callers who want stall
  detection pass `idle_timeout_seconds` explicitly, and the tool descriptions now say so.
- **Recommended pattern.** Long Claude runs (/feature, night runs, anything that may exceed 30 min):
  `idle_timeout_seconds: 3600` and `timeout_seconds: 86400`. 3600 s is three times the longest quiet tool
  call measured (20 min, a PAL call); a genuinely stalled run is ended within an hour instead of burning
  the day, and a busy one is never ended by elapsed time. Short work: omit both (30 min wall clock via `DEFAULT_TIMEOUT_MS`,
  no idle timer), or `idle_timeout_seconds: 300` if stall detection matters. If a run does die (idle or backstop), `continue_session` with the same `session_id` resumes
  with the full context, so no "progress file and re-read the docs" workaround is needed for the
  timeout reason (a progress file can still be worth keeping for humans).

## Not verified

- Transcript behaviour of a headless job waiting on a background task or Monitor (see 1b).
- Live subagent write cadence: evidenced by one on-disk example plus the stub, not a live run.
- That the live claude.ai client forwards values above 3600; the connector schema accepts them
  (smoke-tested), the client side is not observable from here.
- Takes effect on the running connector only after the image is rebuilt and the container force-updated.
  No env or template change is required.
