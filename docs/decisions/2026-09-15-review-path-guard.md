<!-- Moved from claude.ai Project "Claude", doc claude/review-path-guard-outcome.md, on 2026-11-04. -->
<!-- Known stale at move: Not covered in OPERATIONS.md §7: the suggestion to fix the missing directory via an entrypoint.sh mkdir, and that the brief's `sleep N && ssh` guard was never actioned. -->

# code-diff-reviewer path guard — outcome (15 Sep 2026)

Brief: `code-diff-reviewer-path-block-brief.md` (headless `/feature` runs skipped the review pipeline after a blocked `ls ~/.claude/review-lib`).

Resolved without an image change or force-update. Full detail is in `OPERATIONS.md` §7 of kmbrimble/claude-code-unraid (commit 1a9e53d). In short:

- The brief's diagnosis was confirmed by re-running it.
- **Correction to the brief:** its option 1 (`--add-dir`) does not fix things on its own. It unblocks `ls`, `cat` and `mkdir`, but the block on copying (`cp`) from `~/.claude` stays, and so does the block on writing files with `>` redirects. So the skills had to change as well.
- `settings.json`: `permissions.additionalDirectories` = `/root/.claude/review-lib`, `/tmp/claude-review`.
- `run-passes.sh`: new `--template` and `--brief` options. It builds the prompt and creates its own run directory, and prints that directory as `out=`.
- New `run-scanners.sh` for `code-security-audit`.
- All three review skills and `/feature` step 18 were rewritten to avoid the blocked commands, and now say "run, don't probe".
- Fixed a `$0` substitution bug: `US$0.15` was rendering as a path.
- Checked with a connector session in `default` permission mode on unraid-dormouse: the whole pipeline ran with no blocks.
- Backups of the original files: `~/.claude/backups/review-path-guard-20260915/`.

Open:

- `/tmp/claude-review` is removed on every container restart. A directory listed in `additionalDirectories` that doesn't exist when a session starts is ignored, so `ls` in that folder is blocked until the first review run recreates it. The scripts don't need `ls`, so nothing breaks. An `entrypoint.sh` `mkdir` would fix it at the next image update.
- The `sleep N && ssh` guard from the brief was not actioned.
