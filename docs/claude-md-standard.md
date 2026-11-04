<!-- Moved from claude.ai Project "Claude", doc claude/claude-md-standard.md, on 2026-11-03. -->
<!-- Known stale at move: the CI example in section 3 uses gh, which may not apply to Gitea-primary repos (unverified); "this one" in the intro means the claude.ai Project chat. -->

# What every project CLAUDE.md must contain

A repo's `CLAUDE.md` is read by the Claude Code agent running **inside the container**,
at the start of every session in that project. The `/feature` workflow reads it before
planning. Sections missing from it are not neutral — they are places where `/feature`
either guesses or silently skips a safety step.

This is the container-level convention. Filling it in for a given repo is that
project's own chat's job, not this one's.

## The four required sections

### 1. What this project is
One paragraph: the stack, the shape of the thing, where the code lives. Enough that an
agent doesn't infer the architecture from one file and get it wrong.

### 2. Test command
The exact command, and what it covers. `/feature` must prove a **red baseline** before
implementing — it cannot do that without knowing how to run the tests.

If a project genuinely has no automated harness, say so explicitly and state what manual
verification is required instead. `/feature` has a rule for this case: it must tell the
user there is no automatic test, describe the manual check, and get agreement before
continuing. Silence causes it to guess; an explicit "no harness, verify by X" does not.

### 3. Deploy and verify
What happens after a green push, exactly. Options seen across these projects:

- Watch a CI build (`gh run list --limit 1`, then `gh run watch <id> --exit-status`)
- Push and let a host redeploy (GitHub Pages, a watcher)
- Promote a verified candidate file to a live location
- Nothing at all

If there is no deploy step, **say so explicitly**. `/feature` is instructed not to invent
one and not to wait on a CI build that does not exist, but an absent section reads as an
oversight rather than a decision.

### 4. Non-negotiable constraints
The things that look like bugs, look like poor practice, or look ripe for a tidy-up, and
are none of those. This is the highest-value section and the most commonly missing.

State each as: the constraint, the file that implements it, and **why** it exists. The
"why" is what stops a future agent reasoning its way around it.

Good examples from this codebase:

- Bind to all interfaces on a fixed port, never loopback — a loopback bind makes the app
  unreachable by the reverse proxy and the LAN.
- Build and sign our own APKs; no signing credentials in the repo — the app holds Home
  Assistant credentials.
- CDR feed rates are in dollars, not cents. Do not re-divide by 100.
- Controlled-load energy is already included in the main usage totals; only its daily
  charge is added. Re-costing the energy would double-count.

An agent hitting a constraint it believes is wrong must stop and raise it, never rewrite
it to match current behaviour. A non-negotiable that has become false is either a
regression to fix or a decision to record, and that is the owner's call.

## Optional but useful

- **Scope fences** — files or directories a change should never touch.
- **Known gotchas** — things already documented inline in the code, repeated here so they
  don't get "fixed" by accident.
- **Explicitly out of scope** — approaches already considered and rejected, so they don't
  get re-proposed (e.g. "no build step, no bundler, decided against Docker").

## Versioning

`MAJOR.MINOR`, where MINOR is a plain integer counter: `0.9 → 0.10 → 0.11`. Never `1.0`
unless the owner declares a milestone. If `CHANGELOG.md` states its own convention in a
header sentence, that wins.
