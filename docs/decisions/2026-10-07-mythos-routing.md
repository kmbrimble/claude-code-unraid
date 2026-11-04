<!-- Moved from claude.ai Project "Claude", doc claude/mythos-review-routing-outcome.md, on 2026-11-04. -->
<!-- Known stale at move: The Open section is partly stale; the force-update it mentions as pending has since run. -->

# Mythos in the review path, score-first routing, advisor gates — outcome (7 Oct 2026)

Decision record. All changes are on the **persisted mount**; no image change. Pre-change copies:
`~/.claude/backups/review-mythos-20261007/` (and `...-20261007b/` for the later one-pass edit).
Container ops facts stay in `OPERATIONS.md`.

## What changed

| File | Change |
|---|---|
| `~/.claude/review-lib/run-passes.sh` | New `--model` and `--effort`. A non-default model writes `pass-<family>-N.json` (e.g. `pass-mythos-1.json`). Advisor tool is off inside passes (`CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`). Default-model passes now run at **high** effort. Per-pass line prints `model=`. |
| `~/.claude/review-lib/union.py` | Records each pass's model; prints cost by model and which model raised each finding when models are mixed. |
| `~/.claude/review-lib/score.py` | Prints a pass plan. Bands unchanged. |
| `code-diff-reviewer` skill | **Score first**, then run the passes the score calls for. |
| `code-audit`, `code-security-audit` skills | One Mythos pass added; old "three more Sonnet passes" removed. |
| `~/.claude/commands/feature.md` | Two advisor gates: after the plan, and after the **second** failed fix attempt. No advisor call before hand-back (step 6.5 already ends with one). |
| `~/.claude/CLAUDE.md` | Review routing paragraph names the models. |

## Routing as shipped

| Review | Score | Passes | Then |
|---|---|---|---|
| Diff | <= 2 | 1 Sonnet | report only |
| Diff | 3-5 | 3 Sonnet | advisor |
| Diff | 6-8 | 3 Sonnet + 1 Mythos | advisor; counsel only if a human says yes |
| Diff | >= 9 | 3 Sonnet + 1 Mythos | GPT-5.6 counsel, advisor |
| Module audit | any | 3 Sonnet, + 1 Mythos from 6 up | counsel from 9 up, advisor |
| Security audit | any | scanners, 3 Sonnet + 1 Mythos | counsel from 9 up, advisor |

Decided by Kieren, 7 Oct: the security audit runs **one** Mythos pass, not two, and Mythos stays
at score 6 and up in diff review rather than being extended to lower scores.

## Facts verified on the way

- **Mythos must be called by full id `claude-mythos-5-1`.** The `mythos` alias fails on Claude Code
  2.1.273 and still fails on 2.1.292.
- **Mythos and Fable share one allowance on Max** (up to 50% of the weekly limit), and that usage
  **also counts toward the plan's regular usage limits** — both per Anthropic's CVP support
  article. So a Mythos pass spends the weekly limit, not only the shared allowance.
- **CVP tier is Defense.** Flaw-and-fix analysis is in scope; attack building is not. No pass was
  blocked in this work. A blocked pass must be reported as failed, not clean.
- **Claude Code was 2.1.273; updated in place to 2.1.292** with `npm install -g ...@latest`
  (no restart). `sonnet` now resolves to Sonnet 5.5 (was Sonnet 5).
- **A connector session in `default` mode needs `allowed_tools`** (at least `Bash`) or it cannot
  run `score.py` / `run-passes.sh`: "This command requires approval". Same on 2.1.273 and 2.1.292.
- No pass in these runs used Fable (checked `modelUsage` on every pass file).
- The container was force-updated the same day: it had been running the 16 Sep image, so
  0.29-0.31 (ttyd removal, hourly Claude Code updater) had never deployed. Verified after: ttyd
  gone, updater log present, PAL connected, scanners present, all edits intact.

## Calibration — butler pinned at `3ee81bb`, detached clone, future history removed

Costs are Claude Code's nominal list-price figures, not money charged on the subscription.

**Security template**

| Arm | Time per pass | Findings per pass | Nominal cost |
|---|---|---|---|
| 3 Sonnet 5.5, medium (default) | 23-32 s | 0, 2, 1 | 0.74 USD |
| 3 Sonnet 5.5, high | 64-198 s | 3, 4, 3 | 1.35 USD |
| 2 Mythos 5.1 | 200-229 s | 4, 2 | 4.47 USD |

- Upload chain (terriblebutler#41): 1 of 3 Sonnet-medium, 2 of 3 Sonnet-high, 2 of 2 Mythos.
- Shared rate-limit bucket behind the proxy: found by every arm (quarantined as unverifiable).
- **Mythos only:** tokens not revoked on password change; uploads written outside the bind mount.
- **Sonnet-high only:** unauthenticated login crash on a non-string password; request bodies logged
  before the rate limiter and auth.
- The second Mythos pass added nothing the first had not found.

**Diff template, `a1b881d..3ee81bb`, run end to end through the skill in a connector session**

- Score 12, CALL. 3 Sonnet-medium (0.74 USD) + 1 Mythos (2.13 USD) + counsel + advisor all ran.
- DeductModal `location_id: null`: Mythos and 1 of 3 Sonnet. GPT-5.6 also found it.
- Missing error handling on the modals: all 3 Sonnet, not Mythos.
- GPT-5.6 only: no in-flight guard against double submission.

## Conclusions

1. **No model subsumes another.** Sonnet, Mythos and GPT-5.6 each produced findings the others
   missed. Keep all three on high-score work.
2. **Sonnet 5.5 at medium effort is too shallow for review passes.** High effort is now the
   default for them. This was the largest gain per unit cost in the exercise.
3. **One Mythos pass is the right count everywhere.** It costs roughly five high-effort Sonnet
   passes, and the second security pass added nothing.
4. This is one commit and small samples. Treat the numbers as direction, not proof.

## Open

- The skills and `/feature` gates have run once each on a replay, not on real work, and not since
  the force-update.
- `score.py` judged the replay at 12 where the 4 Sep calibration table had 10. Same band, but the
  factors are judged by the session and drift.
- `OPERATIONS.md` does not yet record the `allowed_tools` requirement or the Mythos alias trap.
- `~/.claude/CLAUDE.md` still says the old `@code-reviewer` agent is "being kept"; it was retired
  on 4 Sep.
