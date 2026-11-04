<!-- Moved from claude.ai Project "Claude", doc claude/review-skills-handoff-brief.md, on 2026-11-04. -->
<!-- Known stale at move: Brief for the build recorded in docs/decisions/2026-09-04-review-skills.md; holds the rationale for three skills, the narrow rubric, counsel discipline, scanner-vs-LLM split, constraints and the acceptance checklist that the outcome omits. Its section 7.1 and 4.1 were corrected by the outcome doc. -->

# Handoff brief — build three code-review skills

Paste this into a Cowork session in the Claude project. It is written to be self-contained, but §2 lists what to read first.

---

## §1 What to build

Three skills for the `claude-code` container, replacing the single monolithic `code-reviewer` agent path with three purpose-scoped ones:

| Skill | Input | Trigger | Question it answers |
|---|---|---|---|
| `code-diff-reviewer` | a diff or commit range | every change, inside `/feature` | Does this change break something or open a hole? |
| `code-audit` | a whole module or codebase | periodic, or when a module has moved substantially | Is this code fit for purpose? |
| `code-security-audit` | whole repo + deterministic scanners | periodic, and before anything becomes internet-facing | Where are the holes? |

These are **advisory only**. None of them gets repo write access.

### Why three and not one

This split is evidence-based, not aesthetic. From a controlled evaluation (gh `kmbrimble/claude-code-unraid#13`), diff review and whole-module review demonstrably surface **different classes of defect**:

- Diff review caught a build-breaking Hilt change (`ActivityModule` package-private) and a real runtime bug (`DeductModal` sending `location_id: null`).
- Whole-module review of the *same commit* caught a data-loss bug three separate diff reviews had missed (`ItemFormModal.useExisting()` silently discarding price/vendor/purchase_date — terriblebutler#50).

Neither subsumes the other. Do not collapse them back into one skill.

Security is split out because it has a different cadence (periodic, not per-change), a different toolchain (deterministic scanners), and a different failure mode (see §6.3).

---

## §2 Read before designing

1. **gh `kmbrimble/claude-code-unraid#13`** — the counsel evaluation, its two result comments, and the pinned-commit test corpus. This is your calibration data.
2. **gh `kmbrimble/claude-code-unraid#15`** — three-pass union, already specced.
3. **`~/.claude/agents/code-reviewer.md`** — the current local reviewer. Its rubric is the starting point, not a blank sheet.
4. **`~/.claude/commands/feature.md`** — the `/feature` workflow these must slot into.
5. **`~/.claude/CLAUDE.md`** and per-project `CLAUDE.md` files — where the routing rules will live.

---

## §3 The rubric — unchanged, and deliberately narrow

All three skills inherit the existing rubric:

> What gets published works the first go, has no security holes, and fits the brief.

Naming, function length, and readability-for-others are **explicitly out of scope**. This is a single-maintainer codebase; team-maintainability findings are noise here.

Enforce this hard. In the evaluation, one advisor repeatedly filed testability and inline-style findings after being told they were out of scope. Skills must state the exclusion and drop violating findings rather than passing them through.

Keep the **≥80 confidence floor** from the current reviewer.

---

## §4 Shared review mechanics

All three skills share this pipeline:

```
  N independent passes  →  union + dedupe  →  [optional counsel]  →  advisor scrutiny  →  report
```

### §4.1 Three independent passes

Per #15. Non-negotiable design points:

- Passes must be **genuinely independent sessions**, not three turns in one context, or they correlate and the exercise is pointless.
- Union then dedupe on file+line+claim, but **keep an agreement count** per finding. Agreement across passes is a confidence signal a single pass cannot produce.
- **Single-pass findings are kept, not suppressed.** In the evaluation, suppressing them would have discarded two real defects. Report them with lower confidence.

**Known harness trap:** Claude Code sessions sometimes dispatch a background `Agent` despite being told to work inline; print-mode then kills the session at 600s with the review never returning. This broke one evaluation run outright and a second self-reported doing it. Either instruct passes explicitly to work inline, or set `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`. Verify whichever you choose actually works before shipping.

### §4.2 Counsel call

Advisor is **`openai/gpt-5.6-terra` via OpenRouter** through PAL MCP. The Bedrock advisors (`zai.glm-5`, `deepseek.v3.2`) were evaluated and dropped — do not reintroduce them.

Mandatory discipline, learned the hard way:

- Seed the advisor with **neutral, conclusion-free input** and **empty `issues_found`**. One evaluation run seeded one advisor with the reviewer's own findings and voided that arm entirely.
- Require a **seeding attestation** in the output so this is auditable.
- **Exclude `CHANGELOG.md`, `CLAUDE.md` and commit messages** from the reviewed material — they frequently contain the answer.
- Report advisor findings **verbatim and unfiltered**, in their own section. Do not merge, improve, or drop ones the primary reviewer disagrees with. Adjudication happens later and visibly.

**PAL limitation to design around:** PAL cannot send OpenRouter provider-routing parameters (`only`, `order`, `allow_fallbacks`, `sort`). The account-level Allowed Providers allowlist is the sole routing control. Do not write config that assumes per-request routing works.

### §4.3 Advisor scrutiny

The unioned findings — with counsel's output if called — go to Claude Code's built-in `advisor` (currently Fable) for a final pass before handing back.

**Do not treat advisor as a false-positive filter.** Documented failure: the review pipeline is repo-scoped, so cross-repo infrastructure dependencies produce confident false positives, and `advisor` shares the blind spot rather than catching them. It once ranked a false finding as HIGH-confirmed.

Mitigation, which must be built in: any finding whose logic is "nothing in this repo implements X" must be **quarantined into a separate section** and marked as requiring verification against the deployed system. Never reported as a confirmed finding.

---

## §5 Counsel escalation scoring

### §5.1 Kieren's proposal

Score on **length, complexity, risk**. Above a high threshold → call counsel automatically. Mid band → ask, with a suggested benefit. Below → own review only.

The three-band shape is right. The factors need work.

### §5.2 Recommended changes

**Keep risk, but decompose it.** As stated it is doing all the work and is the least defined. Split into named, checkable components:

- *Exposure* — is this path internet-facing, or reachable only on the LAN?
- *Authority* — does it touch auth, tokens, secrets, or permissions?
- *Data integrity* — can it corrupt, delete, or double-count persisted data?
- *Reversibility* — migration or destructive operation versus a UI tweak.

**Demote length to a modifier.** A one-line auth change outranks 500 lines of test fixtures. The evaluation also found long diffs *dilute* reviewer attention rather than warranting more of it — so length should not linearly increase the score.

**Pin down "complexity" or drop it.** As a word it is a vibe. Candidates that are actually computable: number of modules crossed, new control-flow depth, whether the change introduces a *new* pattern versus following an existing one in the repo. That last one has direct evidence behind it — the `DeductModal` bug was precisely "the sibling component did this right, this one diverged".

**Add: test-coverage gap on the changed path.** Strongest recommendation in this section. Both of the best findings in the evaluation had this signature — the DeductModal bug survived because the e2e test always called `.selectOption()` before submitting, and the invoice-commit gap survived because `test/invoices.test.js` only exercised positive quantities. Changed code with no test exercising the new branch is cheap to detect and flagged real defects twice.

**Consider a suppressor, not just triggers.** Changes that depend heavily on infrastructure outside the repo are where counsel is *least* reliable (§4.3). Weight them down, or route them to the quarantine section rather than escalating.

### §5.3 The unattended problem

The mid band as specified — "ask what I want to do" — **does not work when nobody is watching**, which is most of when this runs. Define explicit behaviour:

- Mid band, human present: ask, with the expected benefit stated.
- Mid band, unattended: pick a default (recommend: **do not call counsel**, but record in the report that it would have asked and why). This keeps unattended runs cheap and leaves a visible audit trail.

Decide how "unattended" is detected and state it in the skill.

### §5.4 Calibrate, do not invent

Do not ship invented thresholds. There is now a real corpus: the pinned commits and recorded findings in #13, spanning butler and wallpanel, diff and whole-module, with known outcomes.

Score that corpus with your proposed formula and check the bands land sensibly — the butler security review and the invoice module should land high, a changelog-only commit should land low. If they don't, the formula is wrong, not the corpus.

### §5.5 Cost context

Counsel runs at roughly **US$0.15 per review**; a large whole-module review reached US$1.72. Unfiltered at 60–70 reviews a month is roughly US$10. The scoring exists to bring that down while keeping counsel on the reviews where it earns its place — so a formula that escalates almost everything has failed even if its findings are good.

---

## §6 `code-security-audit`

### §6.1 Research task

Search GitHub for widely-used open-source security scanners and replicate the features and workflows relevant to a homelab. Do not assume the list below is complete or current — **verify each is still maintained before recommending it**, and look for what has displaced them.

Starting points worth evaluating: `gitleaks`, `trufflehog`, `detect-secrets` (secrets); `semgrep` (OSS rules), `bandit`, `govulncheck` (SAST); `trivy`, `grype`/`syft`, `osv-scanner`, `npm audit`, `pip-audit` (dependencies and containers); `checkov`, `hadolint` (IaC and Dockerfiles).

For each, answer: does it run fully locally with no SaaS account, what does it actually catch, what is the false-positive rate like, and how noisy is its default ruleset.

### §6.2 Why local execution matters

GitHub's own scanning covers repos that build through GitHub Actions. **Not all of Kieren's projects do.** The skill must run scanners locally in the container so nothing is missed.

Practical constraint: apt packages do not survive image rebuilds, and per-run installs are slow. Decide deliberately between baking the chosen scanners into `claude-code-unraid`'s Dockerfile (a repo change, CI build, force-update) versus installing to the persisted mount. State the decision and its cost.

### §6.3 Division of labour — the important part

Scanners and LLM review catch different things, and the skill must not conflate them:

- **Scanners** catch known patterns: committed secrets, vulnerable dependency versions, dangerous API usage, IaC misconfigurations. Deterministic, low false-negative on what they cover, and they cover a narrow slice.
- **LLM review** catches logic and authorisation flaws no ruleset encodes.

Worked example from this codebase: butler's `/uploads` was served by `express.static` before `requireAuth`, while `fileFilterFor` trusted the client-declared MIME type and `diskStorage.filename` took the extension from `originalname`. Chained, that allows attacker-controlled HTML served from the trusted origin against a `localStorage` JWT. No off-the-shelf ruleset finds that chain. A reviewer reasoning about the code did (terriblebutler#41).

So: run the scanners for coverage and determinism, then have the LLM pass reason about **authorisation boundaries, trust assumptions, and multi-step chains** — and explicitly instruct it not to re-report what the scanners already found.

### §6.4 Scope honesty

Carry the §4.3 rule verbatim into this skill, with its own `UNVERIFIABLE FROM THIS REPO` section. Security review is where repo-scoped blindness produces the most confident wrong answers — the infrastructure in front of these apps (Cloudflare, NPM, unraid-secretsman) is not in the repos being reviewed.

---

## §7 Integration

### §7.1 `/feature`

`code-diff-reviewer` slots into the existing `/feature` flow at the review step, replacing the current `@code-reviewer` invocation. It must:

- run the three-pass union,
- compute the escalation score,
- call counsel or not per §5,
- pass the result to `advisor`,
- and hand back before the changelog/push steps.

`code-audit` and `code-security-audit` are **not** part of `/feature` — they are invoked deliberately or on a schedule.

### §7.2 CLAUDE.md routing

Add routing rules to global `~/.claude/CLAUDE.md` so every session knows which to reach for. Keep it short and decision-shaped:

- reviewing a change → `code-diff-reviewer`
- assessing an existing module → `code-audit`
- looking for holes, or before exposing something → `code-security-audit`

Per-project `CLAUDE.md` files should note anything project-specific: internet-facing status, which modules are sensitive, known infra dependencies that will otherwise produce false positives.

### §7.3 Retirement

The current `~/.claude/agents/code-reviewer.md` is superseded by `code-diff-reviewer`. Do not delete it until the new skill is proven — the same ordering rule that applied when `code-reviewer@dotclaude` was replaced. Leaving a gap with no review capability is the failure to avoid.

---

## §8 Constraints

- **Advisory only.** No repo write access for any of these, and no counsel model gets write access ever.
- **Projects live at `/projects/<name>`** in the container, never `~/projects`.
- **No secrets in output.** Findings must never quote a secret value; reference the location instead.
- Public repos get **no working exploit payloads in issue bodies** — describe the defect and the fix, not a ready-made attack. terriblebutler is public.

---

## §9 Ask Kieren before finalising

1. **The escalation scoring formula.** He has views on length/complexity/risk; §5.2 proposes changes. Agree the factors and weights with him before implementing, and show him how the #13 corpus scores under the agreed formula.
2. The unattended default for the mid band (§5.3).
3. Scanner install location — image bake versus persisted mount (§6.2).
4. Cadence for `code-audit` and `code-security-audit` — scheduled, or manual only.

---

## §10 Acceptance criteria

- [ ] Three skills exist, with non-overlapping trigger descriptions that don't misfire into each other
- [ ] Three-pass union implemented with per-finding agreement counts, single-pass findings retained
- [ ] Counsel seeding is neutral, attested, and auditable; advisor findings reported verbatim in their own section
- [ ] Escalation scoring implemented, agreed with Kieren, and **calibrated against the #13 corpus** with the scores shown
- [ ] Defined unattended behaviour for the mid band
- [ ] Security skill runs its scanners locally and does not depend on GitHub Actions
- [ ] `UNVERIFIABLE FROM THIS REPO` quarantine present in all three skills
- [ ] `/feature` updated; global and per-project `CLAUDE.md` routing added
- [ ] Old `code-reviewer` retired only after the replacement is proven
