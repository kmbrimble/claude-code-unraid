<!-- Moved from claude.ai Project "Claude", doc claude/review-skills-outcome.md, on 2026-11-04. -->
<!-- Known stale at move: The Open section is stale: it says the scheduled force-update has not run, but it has. -->

# Three code-review skills — outcome (4 Sep 2026)

Decision record for the work that implemented `claude/review-skills-handoff-brief.md`.
The skills live on the **persisted mount** and are live now. The scanner half is built and
scheduled to land at 03:00 on 5 Sep. Container ops facts stay in `OPERATIONS.md`; the counsel
evaluation stays in gh `kmbrimble/claude-code-unraid#13`.

## What shipped

| Path | What |
|---|---|
| `~/.claude/skills/code-diff-reviewer/SKILL.md` | Review a change before it lands |
| `~/.claude/skills/code-audit/SKILL.md` | Assess standing code |
| `~/.claude/skills/code-security-audit/SKILL.md` | Hunt for holes |
| `~/.claude/review-lib/run-passes.sh` | Launches N independent `claude -p` passes |
| `~/.claude/review-lib/union.py` | Union + dedupe with agreement counts |
| `~/.claude/review-lib/score.py` | Escalation scoring, deterministic arithmetic |
| `~/.claude/review-lib/pass-prompt-{diff,module,security}.md` | The three pass prompts |
| `~/.claude/review-lib/counsel-seed.md` | Neutral seeding rules + attestation template |
| `~/.claude/commands/feature.md` | Step 6.5 now invokes `code-diff-reviewer` |
| `~/.claude/CLAUDE.md` | Routing section added |
| `/projects/.ops/force-update-with-watchdog.sh` | Host-side force-update with recovery watchdog |

Backups: `feature.md.bak-20260904-185315`, `CLAUDE.md.bak-20260904-185328`.

`~/.claude/agents/code-reviewer.md` was **retired the same day** at Kieren's instruction,
ahead of the ordering rule's "prove it first". Moved, not deleted:
`~/.claude/agents-retired/code-reviewer.md.retired-20260904`, with a README stating how to
restore it. Retiring it left no gap because nothing automated ever invoked it.

Retiring it surfaced three dangling references in `~/.claude/agents/silent-failure-hunter.md`
pointing at the retired agent; those now point at `code-diff-reviewer`. `pr-test-analyzer`
and `silent-failure-hunter` are **not** retired — they are narrower, deeper specialists
invoked on explicit request, and the review skills do not replace them.

## Two corrections to the brief, both verified

**§7.1 was wrong: there was no `@code-reviewer` invocation to replace.** `feature.md`
Step 6.5 was a *self*-review ("re-read the plan and diff cold"). `@code-reviewer` appeared
in no command, no `CLAUDE.md`, and no project config — it only ever fired when invoked by
hand. So this was an insertion, not a replacement.

**§4.1's harness fix was backwards.** From the Claude Code 2.1.259 bundle:

```js
var Hl=5000, Vg=600000;
function Rm(){ return a.CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS ?? Vg }
```

`Vg = 600000` **is** the 600 s reap. The env var overrides that default via `??`, so `0` is
a valid override giving a ceiling of zero — `ceilingExceeded` trips on the first check and
the sweeper reaps immediately. Setting it to `0` makes the kill instant rather than
preventing it. The runner sets it to `86400000` and also sets
`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`.

Better than either: `--output-format json` returns `subagent_stats.started_in_background`,
so the runner **asserts** it is `0` per pass and warns loudly otherwise. Measured `0` on
every pass of every run below.

## Agreed with Kieren

- **Bands: CALL ≥ 9 · MID 6–8 · OWN ≤ 5.**
- **Mid band does not call counsel.** It runs a *second* independent three-pass review
  (six total, agreement out of 6). Counsel is offered only when a human is present.
  Unattended mid band records `counsel offered but skipped — unattended` and moves on.
- **Scanners baked into the image.** Deferred at first so the skills were not held hostage
  to a force-update; built and scheduled the same evening.
- **`code-audit` and `code-security-audit` are manual-only.** No schedule.
- Butler treated as **authenticated internet-facing** (Exposure 2).

## The scoring formula

Base 0–17: exposure (0–3) + authority (0–3) + data integrity (0–3) + reversibility (0–2)
+ **test-coverage gap (0–3)** + pattern divergence (0–2) + module spread (0–1).

Length is a modifier that may move a score **within** a band and never **across** one —
`score.py` clamps it. 500 lines of fixtures must not outrank a one-line auth change, and
#13 found long diffs dilute attention rather than earning more of it.

Infra suppressor: −2 when the changed surface leans on infrastructure outside the repo,
with those findings routed to quarantine rather than escalated. That is the 3 Sep `!secret`
false positive, generalised.

### Calibration against the #13 corpus

| Target | E | A | D | R | T | P | M | Score | Band |
|---|--:|--:|--:|--:|--:|--:|--:|--:|---|
| butler security review | 2 | 3 | 1 | 1 | 2 | 0 | 1 | 10 | CALL |
| butler invoice module | 2 | 0 | 3 | 1 | 3 | 1 | 1 | 11 | CALL |
| butler `3ee81bb` DeductModal | 2 | 0 | 2 | 1 | 2 | 2 | 1 | 10 | CALL |
| wallpanel `09030d2` Hilt | 0 | 0 | 0 | 0 | 3 | 1 | 1 | 5 | OWN |
| changelog-only commit | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | OWN |

All three targets where GPT-5.6 earned its US$0.15 land in CALL. **Note the band change:**
under the drafted bands wallpanel Hilt was MID; under the retuned bands it is OWN. That is
the run where counsel corroborated a finding Claude already had and added one false
positive, so OWN looks defensible — but it is the one calibration point the retune moved,
and the one to watch.

## Calibration run — measured, not asserted

Target: `/projects/_replay2-butler` at `3ee81bb`, the pinned DeductModal commit.

**Run 1 — three passes, zero findings.** The passes did deep context work and concluded
"faithful port of the legacy implementation". The historical single-pass control on this
commit found an error-handling gap; three passes found nothing. **The prompt was the
defect, not the run.**

The bug is real and present: `DeductModal.tsx:38` does
`multiLocation ? locationId || null : undefined`, so an untouched dropdown sends
`location_id: null`. The server's own comments state the contract —

```js
// Omitted entirely -> infer (only safe when the item has at most one location row).
// Present as null/'' -> an explicit choice of the "unassigned" bucket, not a fallthrough.
```

— so a missed selection silently targets the Unassigned bucket instead of erroring. The
sibling `QtyModal.tsx` defaults to the item's first real location and gets it right.

**Fix applied to the diff prompt**, derived from that failure rather than invented:

1. *Trace every value across the boundary.* For each value leaving the module, write down
   what the receiver does with `undefined`, `null`, `''`, `0`, and a missing key. Answer in
   words: does the receiver distinguish "the user did not choose" from "the user chose the
   empty option", and can the sender express that difference?
2. *A faithful port is not automatically a correct one.* Check the port preserves the
   legacy **defaults**, not just its shape. And if the legacy behaviour was itself wrong,
   say so.

**Run 2 — all three passes found it independently**, one naming the `QtyModal` sibling
divergence. But every pass reported through the `ReportFindings` tool instead of emitting
JSON, so the parser got prose. Fixed twice over: the rubric forbids it explicitly, and the
runner passes `--disallowed-tools ReportFindings`.

**Run 3 — clean.** 4 raw findings → 2 after dedupe:

- `DeductModal.tsx` location bug, **agreement 3/3**, confidence 90
- No error handling on any of the three new modals, **1/3**, confidence 85 — kept, and it
  is the finding the historical single-pass control found

That beats the single-pass control on the same commit. Cost: US$3.44 for three passes.

## The dedupe bug, and why the fix is shaped as it is

Run 3 initially reported the *same* defect three times at 1/3 each, anchored at lines 11,
46 and 38. Agreement is the entire point of three passes, so reporting 1/3 for something
unanimous is worse than not counting at all.

Measured on that data: same-defect pairs scored 0.26–0.46 word-overlap and shared 2
identifier-shaped tokens; cross-defect pairs scored 0.06–0.09 and shared 0. So the merge
rule is now **same file AND (overlap ≥ 0.45, OR overlap ≥ 0.25 with ≥ 2 shared identifiers,
OR within 3 lines with overlap ≥ 0.20)**. Anything in the 0.12–0.25 band lands in a
`Candidate duplicates` section for the reviewing session to adjudicate, and merged groups
print every pass's phrasing so a wrong merge is visible rather than silent.

A wrong merge destroys a finding; a missed merge is a row a human can collapse. The rule is
biased accordingly.

## Cost, honestly

Three passes measured at **US$1.55–3.44** per review against **US$0.15** for a counsel call.
The mid-band decision — six passes instead of counsel — is cheaper in dollars and more
expensive in Anthropic usage pool, which the global delegation policy asks to conserve.
That tension is worth revisiting once there is a month of data. It is not a reason to
reverse the decision: #13's finding 3 was that internal run-to-run variance exceeded both
advisors' entire contribution.

## Verification performed

- Harness: `started_in_background=0` on all 10 passes across four runs.
- Routing: a fresh session asked to route five scenarios chose correctly **5/5** with no
  misfires between the three skills.
- Union: parse failure vs "no findings" are reported distinctly — proven when run 2's three
  passes all failed to parse and were reported as failures, not as a clean result.
- `score.py` reproduces the calibration table above.
- Module prompt smoke-tested on `client/src/lib/`: parsed clean.
- Host SSH, `update_container` path, and the staged watchdog script all verified reachable
  and syntax-clean from the host side before scheduling.

## Scanner set — built, scheduled to land 03:00 on 5 Sep

Every figure verified or measured 4 Sep 2026. Committed as `370b530`, CI run `33857063051`
green in 2m24s. **The image is built and waiting; the container picks it up at the scheduled
force-update.** Building on the evening of the 4th rather than at 3am was deliberate: a CI
failure then is one Kieren sees while awake, instead of one that silently wastes the
maintenance window.

| Purpose | Tool | Version | Size |
|---|---|---|---|
| SAST | semgrep CE | 1.176.0 | 348 MB |
| Dependencies | osv-scanner | 2.5.1 | 58 MB |
| Secrets | trufflehog | 3.97.4 | 34 MB |
| Dockerfiles | hadolint | 2.15.1 | 54 MB |

≈ +490 MB to the image. The osv-scanner offline DB (212 MB) goes on the **persisted mount**,
not in the image — baking it guarantees it is stale the day after the build.

Each static binary is SHA256-verified on download rather than curled unverified into
`/usr/local/bin`; this repo has already been bitten once by a name-squatted package
(`pal-mcp-server` on PyPI). semgrep lives in its own venv at `/opt/semgrep` exposed only by a
symlink, because putting the venv's `bin` on `PATH` would shadow `python3`/`pip` for every
session in the container. `test/smoke.sh` asserts each pinned version and asserts the venv
stays off `PATH`.

**Rejected, with reasons:**

- **gitleaks** — 6 findings on a clean corpus, all 6 false positives, every one a
  `SECRET_KEY` example in documentation, all from `generic-api-key`. trufflehog returned 0
  on the same bytes.
- **detect-secrets** — dead. No release since May 2024; `master`'s version string unbumped
  for 28 months.
- **pip-audit** — cannot run offline at all (maintainer-confirmed). Fails the constraint outright.
- **checkov** — 258 MB to run 47 Dockerfile checks, 2 of which fired, and it missed the
  hardcoded `ENV API_KEY` that hadolint caught. Revisit if Terraform or K8s enters scope.
- **trivy / grype+syft** — good tools, but 1.28 GB and 2.03 GB of database respectively for
  coverage osv-scanner already provides at 212 MB. Add trivy only for base-image OS CVE
  scanning, the one thing osv-scanner does not do.
- **bandit** — 1,033 findings on one real project, 1,004 of them `B101 assert_used`.
  Only viable with `--exclude tests --severity-level medium`.
- **mobsfscan** — 353 MB and flagged none of MD5, AES/ECB or a hardcoded key on a test
  module. It is a manifest linter, not Kotlin SAST.

**Licence change worth knowing:** Semgrep's maintained rules stopped being open source on
13 Dec 2024 (Semgrep Rules License v1.0). Internal scanning of your own repos is the
explicitly permitted case, so this use is fine — but it is now a dependency of the pipeline,
and it forbids offering the rules as a service. Opengrep is the credible LGPL fork at 45 MB,
but its own rules repo was archived in Nov 2025 with no successor, so it ends up vendoring
`semgrep-rules` and depending on the same licence anyway.

**Known coverage gap: Kotlin SAST is thin.** `p/kotlin` ran 9 rules against a test module
where `p/php` ran 23 and caught SQLi, reflected XSS and two command injections via taint
tracking. For wallpanel, the LLM passes are doing nearly all the work, and the skill says so
in its report.

## Scheduled tasks created (4 Sep, firing 5 Sep)

| When (Brisbane) | What |
|---|---|
| 03:00 | Preflight, then fire `/projects/.ops/force-update-with-watchdog.sh` on the host. Aborts without updating if the repo, CI, container state, staged script, or an active `claude` job says no. Expects to lose its own connection — that is success, not failure. |
| 03:25 | Fresh session verifies scanners at pinned versions, re-runs the OPERATIONS.md §2 checks (a recreate can silently change tool versions), confirms skill and retired-agent state, seeds the osv DB, and writes `claude/scanner-install-outcome.md`. Push notification on. |

**Why the watchdog exists.** The container's restart policy is `no`, so a failed recreate
leaves it stopped. Once stopped, nothing in the cloud can reach the unRAID host to restart
it — the MCP connector runs inside the very container being replaced. Recovery therefore has
to already be running on the host before the update starts. The script arms the watchdog
*first*, then invokes `update_container`; a watchdog armed afterwards would die with the
container.

**The residual risk that cannot be designed away:** if both the recreate and all 30 watchdog
restart attempts fail, the container stays down and no scheduled session can recover it.
That needs someone at the unRAID web UI. The 03:25 task is instructed to say exactly that
rather than burning the run retrying.

## Open

- **The scheduled force-update has not run yet.** Nothing below it is proven until it does.
- **The osv-scanner offline DB is not seeded.** The 03:25 run does it (~212 MB).
- **Per-project `CLAUDE.md` review sections** are not written. A self-contained prompt for
  each project's own chat was handed over on 4 Sep, covering exposure, modules that own data
  users rely on, infrastructure the repo depends on but does not contain, and test reality.
- **Counsel has not been exercised through the new pipeline.** Every calibration run landed
  in a band, but no run has actually called `openai/gpt-5.6-terra` through
  `counsel-seed.md`'s attestation flow. First CALL-band review in anger is the real test.
- **`code-diff-reviewer` has not run on real work** — only on the pinned replay corpus. The
  old reviewer is now retired, so the review skills are the only review path and there is no
  fallback in place.
- **The wallpanel Hilt calibration point** moved from MID to OWN under the retuned bands.
  Worth watching whether that class of change should be getting more review.
- **Repo/live template drift** on `Mask` and `Description` for `CUSTOM_API_KEY` is still
  outstanding from 3 Sep, and `templates/claude-code.xml` is still uncommitted in the working
  tree. Deliberately left alone by this work — it is unrelated drift, not this change's to
  fix.
