<!-- Moved from claude.ai Project "Claude", doc claude/scanner-install-outcome.md, on 2026-11-04. -->
<!-- Known stale at move: CLI 2.1.260 drift is superseded (OPERATIONS now says the CLI tracks npm latest with an hourly updater); the uncommitted template edit is stale; the osv seeding command, cache path /root/.cache/osv-scalibr and the measured 245 MB size are only recorded here; the butler smoke findings belong to butler. -->

# Scanner force-update — verification outcome

**Update run:** 03:00 Brisbane, 5 Sep 2026 (scheduled, autonomous)
**Verification run:** 03:25 Brisbane, 5 Sep 2026 (autonomous, this document)
**Target:** `ghcr.io/kmbrimble/claude-code-unraid:latest` — commit `370b530`, CI run `33857063051`

**Verdict: the update succeeded. All four scanners are present at their pinned versions and nothing verified as regressed. One deviation and one stale doc entry are noted below; neither is urgent.**

## Container recreate

Came back cleanly on the first attempt. The watchdog armed, slept its 120 s, found the container running on **check 1**, and did nothing further — there was no `container NOT running … attempting docker start` line, so the recreate did not need rescuing.

Image id moved `sha256:febe54a7…` → `sha256:45ce5553…`.

Preflight (logged by the 03:00 run) passed on all five gates: HEAD `6a3845b` on main with `370b530` as an ancestor, newest CI run `33864470950` green, container running, watchdog script present and executable, 489 jobs all terminal with 0 running.

## Scanner versions — all four match their pins

| Scanner | Expected | Found | |
|---|---|---|---|
| semgrep | 1.176.0 | 1.176.0 | ✅ |
| osv-scanner | 2.5.1 | 2.5.1 (osv-scalibr 0.5.2) | ✅ |
| trufflehog | 3.97.4 | 3.97.4 | ✅ |
| hadolint | 2.15.1 | 2.15.1 | ✅ |

No silent drift.

## Regression checks (OPERATIONS.md §2)

| Check | Expected | Found | |
|---|---|---|---|
| `claude --version` | 2.1.259 | **2.1.260** | ⚠️ see below |
| `docker --version` | 29.7.2 | 29.7.2 | ✅ |
| procps (`ps`, `free`, `top`) | present | all three in `/usr/bin` | ✅ |
| `pal` MCP server | Connected | Connected | ✅ |
| `/root/.claude/pal/custom_models.json` | exists | present — seed-if-absent did not clobber it | ✅ |
| skills | code-diff-reviewer, code-audit, code-security-audit | all three present (plus issue-sprint, issue-to-ship, new-project) | ✅ |
| agents | `code-reviewer.md` absent | absent | ✅ |
| agents | repository-reader, pr-test-analyzer, silent-failure-hunter | all three present | ✅ |
| review-lib | run-passes.sh, union.py, score.py + 3 pass prompts | all present (plus `_rubric.md`, `counsel-seed.md`) | ✅ |
| semgrep venv on `PATH` | count 0 | 0 — not on PATH | ✅ |
| `python3` resolution | not under /opt/semgrep | `/usr/bin/python3.11` | ✅ |

The semgrep venv is correctly kept off `PATH`; python3/pip are unshadowed for every session.

### The one deviation: Claude Code CLI 2.1.260

The container is running **2.1.260**, not the 2.1.259 recorded in the OPERATIONS.md version table. This is expected drift rather than a regression: the Dockerfile installs the CLI unpinned (`npm install -g @anthropic-ai/claude-code claude-auto-retry`), so any rebuild floats it to whatever npm publishes as latest. The 03:00 rebuild picked up a newer patch release.

Nothing was changed in response — this run records and stops.

## osv-scanner offline database — seeded

`osv-scanner scan source -r . --offline --download-offline-databases` over `/projects/claude-code-unraid` completed cleanly (exit 0, "No issues found") after scanning `connector/package-lock.json` (133 packages) and `pal-requirements.lock.txt` (46 packages).

The database landed at `/root/.cache/osv-scalibr` — **245 MB total** (npm 212 MB, PyPI 33 MB). `/root` is the persisted shfs mount (`/appdata/claude-code/home`), so this survives future recreates and the first real audit will not pay the download cost.

## Smoke pass on /projects/butler

- **hadolint**: ran, exit 1, one finding — `Dockerfile:7 DL3008 warning: pin versions in apt-get install`. Scanner works; the finding is butler's, not the image's.
- **trufflehog**: **10 findings** (`--no-verification`, so these are unverified detector matches, not confirmed live credentials). Counts only — no values were read, printed or stored anywhere in this run.

Triage of those 10 belongs in the butler project, not here. A suggested prompt to paste into that chat:

> Run `trufflehog filesystem . --no-verification --json` in /projects/butler and triage the 10 detector matches: for each, say whether it is a real credential, a test fixture, or a false positive, and what to do about it. Do not paste any secret value into the chat — reference file and line only.

## Outstanding manual steps

1. **OPERATIONS.md version table is stale** — it records the Claude Code CLI as `2.1.259`; the container runs `2.1.260`. Either bump the table, or decide the CLI should be pinned in the Dockerfile so the table means something. This run did not edit it.
2. **Uncommitted local edit in the repo** — `templates/claude-code.xml` has 3 uncommitted added lines (the OpenRouter/PAL config variables: API key, models-config path, allowed-models allowlist). Pre-existing and unrelated to the scanner update; it survived the recreate because `/projects` is persisted. Commit or discard when convenient.

Nothing else is outstanding. No repairs were attempted.
