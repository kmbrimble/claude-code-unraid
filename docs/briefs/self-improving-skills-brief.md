<!-- Moved from claude.ai Project "Claude", doc claude/self-improving-skills-brief.md, on 2026-11-04. -->
<!-- Known stale at move: Brief for the build recorded in docs/decisions/2026-11-03-self-improving-skills.md; holds the acceptance test definitions, open-question defaults, linter criteria and constraints that the outcome omits. -->

# Brief — self-improving skills for the claude-code container

**For:** the Claude Code agent in the `claude-code` container on unRAID
**Working dir:** `/projects/claude-code-unraid` (persistent path — never `~/projects`)
**Written:** 3 Nov 2026

## 1. Goal

Give the agent a Hermes-style learning loop. After substantial sessions it should propose new skills, or patches to existing skills, based on what it learned. Every change waits for Kieren's approval before it takes effect.

Auto memory already covers facts: preferences, corrections, project context. It deliberately skips "debugging fixes" and anything it can work out from the code. This work fills that gap with **procedures**: how something was done, which dead ends to avoid, and how to verify the result.

## 2. Reference model (Nous Research Hermes Agent)

Copy the mechanism, not the software:
- The system prompt tells the agent to save a skill in three cases: (a) a non-trivial multi-step workflow worth repeating, (b) errors or dead ends that led to a working path, (c) a user correcting the agent's approach.
- A background review runs after a session and stages suggested skill changes.
- Targeted patches are preferred over full rewrites.
- Skills hold generalisable lessons and pitfalls, not incident logs.
- An advisory linter warns on oversized skills and on content that reads like an incident log.
- An optional approval mode stages writes for review, with commands to list, diff, approve and reject.
- A "curator" pass consolidates skills over time, and individual skills can be locked against changes.

## 3. Read first

1. `OPERATIONS.md` in this repo: mounts, the persisted home, known traps.
2. `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, `~/.claude/hooks/`, `~/.claude/skills/`, `~/.claude/agents/`.
3. The current Claude Code docs for **hooks** (https://code.claude.com/docs/en/hooks), **memory** (https://code.claude.com/docs/en/memory) and **skills**. Verify every hook field, handler type and setting you rely on against these docs or the installed version. Don't work from recollection.

## 4. Step 0 — verify, then report before building

Collect these facts and include them in the handback:
1. `claude --version`.
2. **Is auto memory on** in each of these session types?
   - an interactive session
   - a session started through the Claude Code CLI MCP connector
   - a direct `claude -p` session

   The docs say auto memory is off by default in self-hosted environments. They also say it can't be turned on in a session that another Claude Code session started. Report what each type actually shows, and how you determined it.
3. The input schema for `SessionEnd` and `Stop` on the installed version: `transcript_path`, the `reason` field, and which handler types each event allows (`command`, `prompt`, `agent`). Also the `SessionEnd` time budget.
4. How a nested or child `claude` process can be detected, for example an environment variable Claude Code sets. This is the basis for the recursion guard.
5. The current `cleanupPeriodDays` value and where transcripts live.

If auto memory is off in the session types Kieren uses, propose how to turn it on and **stop for confirmation**. Don't change it silently.

## 5. Build

All of this is **home-mount only** (`~/.claude/…`). The goal is no image change and therefore no force-update. If you find an image change is unavoidable, say so before doing it: a force-update drops the connector and every session.

### 5.1 Saving rules in `~/.claude/CLAUDE.md`
Add a short section, about 15 lines or fewer, that:
- states the three save triggers from §2
- says to patch an existing skill before creating a new one, and to check for duplicates by name and description
- says skills hold generalisable rules and pitfalls, with a "Verification" section; not incident narratives
- says **never put secrets, tokens, IPs plus credentials, or `!secret` values in skills**; reference the secretsman key name instead
- says that during a normal session the agent may only write proposals to the pending directory, never to `~/.claude/skills/` directly

Run the existing pre-edit check for shadowing and duplicates first, and back up the file to `~/.claude/.backups/`.

### 5.2 Skills under version control
- `git init` in `~/.claude/skills/` (local only, no remote; see §7) and make an initial commit of the current state.
- Each approved change becomes one commit, with a message naming the source session.

### 5.3 Background reviewer, launched from `SessionEnd`
- A `command` hook (`~/.claude/hooks/skill-review-launch.sh`) that returns in well under the time budget. It launches a **detached** reviewer (`nohup`/`setsid`) and exits 0.
- **Recursion guard:** do nothing if the session is itself a reviewer or curator run. Use the variable found in Step 0, plus a variable of your own set by the launcher.
- **Threshold:** skip trivial sessions, for example fewer than N tool calls or a transcript under X KB. Pick defaults, justify them, and make them configurable.
- **Reviewer run:** `claude -p` on Sonnet. Give it a dedicated prompt file (`~/.claude/skill-review/reviewer.md`) and the transcript path.
  - **Allowed tools:** reading `~/.claude/skills/` and the transcript; writing only to `~/.claude/skill-review/pending/`.
  - Enforce that through `--allowed-tools` and permissions, not just the prompt.
  - Set a max-turns cap and a timeout.
- **Output:** one proposal per change in `pending/<timestamp>-<slug>/`, containing:
  - `proposal.md`: what, why, which trigger, and evidence from the transcript
  - either a full new `SKILL.md` or a unified diff against the existing skill
- **Proposing nothing is the expected outcome for most sessions.** Tell the reviewer that explicitly, so it doesn't pad.
- **Secret scan:** run gitleaks or the existing secret-scan approach on every proposal. Quarantine any proposal that fails.
- **Logging:** one line per run to `~/.claude/skill-review/review.log` (session, decision, duration, proposals made).

### 5.4 Approval command: `/skills-pending`
A skill or slash command that:
- lists pending proposals with one-line summaries
- shows the diff for a chosen proposal
- **approve** applies the proposal, runs the linter, commits, and archives the proposal
- **reject** archives the proposal with an optional reason; the reviewer prompt reads recent rejections so it learns what not to propose
- respects a lock list (`~/.claude/skill-review/locked.txt`): proposals touching a locked skill are flagged and can't be approved without unlocking it first

### 5.5 Linter
A script that runs on approve and on demand. It is advisory and warns without blocking on:
- a `SKILL.md` body over about 24k characters
- a description that is missing or vague
- content that reads like an incident log (dates, "today", session-specific paths)
- a likely duplicate name or description of an existing skill

### 5.6 Weekly curator
- A scheduled run that reads all skills and writes **proposals only** into the same pending queue. It looks for skills to merge, oversized skills to split, skills to retire as stale, and description fixes.
- Use the container's existing scheduling mechanism (check `OPERATIONS.md`). If there isn't one, propose one and stop for confirmation.

### 5.7 Searching past sessions
- Raise `cleanupPeriodDays` to a value you justify. Back up `settings.json` first, using the `.bak-<date>-<reason>` pattern.
- Add a `session-search` skill that searches transcripts (ripgrep over the `.jsonl` files is fine) and returns matching session IDs, dates and short excerpts.

## 6. Tests (acceptance)

1. **Synthetic transcript, positive case.** A transcript containing a dead end and then a fix produces exactly one sensible proposal in `pending/`.
2. **Synthetic transcript, trivial case.** Nothing is proposed, and the log shows a skip.
3. **Recursion.** A reviewer run does not trigger another reviewer.
4. **Permissions.** The reviewer can't write outside `pending/`. Prove it with a direct `claude -p` run under enforced permissions. Note that testing through the connector proves nothing, because it may skip permissions.
5. **Approve and reject.** Approving produces a git commit and the skill loads in a fresh session. Rejecting archives the proposal and the reason appears in the reviewer's context.
6. **Lock.** A proposal against a locked skill can't be approved.
7. **Secret scan.** A planted fake token in a proposal gets quarantined.
8. **Real run.** One real `SessionEnd` from a normal interactive session leaves a log entry, and the session doesn't hang on exit.

## 7. Open questions

Use the default for each, sanity-check it with `advisor`, and report the reasoning:

| # | Question | Default |
|---|---|---|
| 1 | Push the skills repo to a private GitHub remote? | No; keep it local for now |
| 2 | Mirror the hook scripts into this repo for versioning? | Only if `OPERATIONS.md` has an established convention for home-mount files; otherwise no |
| 3 | Reviewer model | Sonnet (the subscription pin); not Fable |
| 4 | Should the reviewer also propose `CLAUDE.md` or rules edits? | No; skills only, to start |
| 5 | Notify Kieren when proposals are waiting? | Include a pending count in the handback of any `/feature` run; nothing more for now |

## 8. Constraints

- Nothing applies to `~/.claude/skills/` without Kieren's approval.
- Report missing tools; don't substitute alternatives.
- Back up every shared file before editing it.
- Raise decisions explicitly; don't assume them.
- Usage: this runs on the Max 5x subscription, so keep the reviewer cheap (threshold, turn cap, Sonnet).

## 9. Handback

- Step 0 findings
- what was built, with file paths
- test results 1–8
- answers to the open questions with `advisor`'s view
- the thresholds and limits chosen
- anything that would need an image change
