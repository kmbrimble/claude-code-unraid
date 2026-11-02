#!/usr/bin/env bash
# Stage 2 gate for the Gitea tooling: drives a throwaway repo kmbrimble/stage2-smoke end to end with
# gt and gitea-mcp only, checks the forge guard against the real forge map, then deletes the repo.
#
#   Post-force-update (everything installed, env from the template):   bash test/stage2-gate.sh
#   Before the update (from /tmp binaries, token injected, needs a route to the Gitea host):
#     hl exec --secret GITEA_TOKEN=claude-code/gitea_token -- env GITEA_CLI_HOST=https://git.kiztigs.com \
#       GT=/path/to/gt GITEA_MCP_BIN=/path/to/gitea-mcp \
#       GITEA_MCP_LAUNCHER=/projects/claude-code-unraid/scripts/gitea-mcp-launch.sh bash test/stage2-gate.sh
#
# Options: --keep leaves the repo and temp dir behind. Exit 0 only if every step passed.
# The repo is created by the token's account (butler-bot) and removed by the same account; that account
# can delete org repos, which is why this script only ever names stage2-smoke and refuses to run if it
# already exists. Nothing here prints the token. Needs the host to be reachable: see OPERATIONS.md §4c.
set -uo pipefail

HOST="${GITEA_CLI_HOST:-${GITEA_HOST:-https://git.kiztigs.com}}"; HOST="${HOST%/}"
OWNER=kmbrimble; NAME=stage2-smoke; REPO="$OWNER/$NAME"
GT="${GT:-gt}"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
HOOK="$HOME/.claude/hooks/forge-guard.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GITEA_CLI_HOST="$HOST" GIT_TERMINAL_PROMPT=0
PASS=0; FAIL=0; CREATED=0
W="$(mktemp -d)"
LAST=""

step() {  # step "name" cmd...  -> runs, records, keeps output in $LAST
  local name="$1"; shift
  if LAST="$("$@" 2>&1)"; then echo "PASS: $name"; PASS=$((PASS + 1))
  else echo "FAIL: $name"; echo "$LAST" | tail -6 | sed 's/^/      /'; FAIL=$((FAIL + 1)); fi
}
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi; }

cleanup() {
  if [ "$KEEP" = 1 ]; then echo "kept: repo $REPO and $W"; return; fi
  if [ "$CREATED" = 1 ]; then
    step "delete the throwaway repo" "$GT" repo delete "$REPO" --yes --no-input
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $GITEA_TOKEN" "$HOST/api/v1/repos/$REPO")
    eq "repo is gone (API 404)" 404 "$code"
    "$HOME/.claude/bin/forge-map-gen" >/dev/null 2>&1
    eq "forge map no longer lists the throwaway repo" null "$(jq -r --arg r "$OWNER/$NAME" '.repos[$r] // "null"' "$HOME/.claude/forge-map.json")"
  fi
  rm -rf "$W"
  echo; echo "${PASS} passed, ${FAIL} failed"
}
trap 'rc=$?; cleanup; [ "$rc" -ne 0 ] && exit "$rc"; [ "$FAIL" -eq 0 ] || exit 1' EXIT

# --- preflight --------------------------------------------------------------------------------
[ -n "${GITEA_TOKEN:-}" ] || { echo "GITEA_TOKEN is not set"; exit 2; }
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$HOST/api/v1/version") || true
case "$code" in 200|401|403) ;; *) echo "cannot reach $HOST (http '$code'): see OPERATIONS.md §4c, network blocker"; exit 2 ;; esac
command -v "$GT" >/dev/null || { echo "gt not found (set GT=)"; exit 2; }
step "gt runs" "$GT" --version
step "gt authenticates as the bot (env token)" bash -c "'$GT' api user --jq .login --no-input | grep -qx butler-bot"
[ "$("$GT" api "repos/$REPO" --jq .name --no-input 2>/dev/null)" = "$NAME" ] && { echo "$REPO already exists: refusing"; exit 2; }

# --- git credentials: use the real global config if the entrypoint already wired it, else isolate ----
if env -u GIT_CONFIG_GLOBAL git config --global --get-all "credential.$HOST.helper" 2>/dev/null | grep -q 'git-credential'; then
  echo "note: using the real global git config (entrypoint already configured $HOST)"
else
  export GIT_CONFIG_GLOBAL="$W/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
  step "gt auth setup-git (isolated gitconfig, pre-update)" "$GT" auth setup-git --no-input --host "$HOST"
fi

# --- repo, Actions, clone, worktree, push, PR, merge ---------------------------------------------------
step "create the private throwaway repo" "$GT" repo create "$NAME" --org "$OWNER" --private --auto-init --default-branch main --no-input
CREATED=1
step "enable Actions on that repo" "$GT" repo edit "$REPO" --actions --no-input
step "git clone over HTTPS (credential helper from gt)" git clone -q "$HOST/$REPO.git" "$W/clone"
cd "$W/clone" || exit 2
git config user.name "Butler Bot"; git config user.email "butler-bot@users.noreply.github.com"   # clone-local; worktrees share it
mkdir -p .gitea/workflows
cat > .gitea/workflows/smoke.yml <<'EOF'
name: smoke
on: [workflow_dispatch]
jobs:
  hello:
    runs-on: ubuntu-latest
    steps:
      - run: echo "stage2 gate ok"
EOF
git add -A && git commit -q -m "Add trivial workflow" && step "push to main" git push -q origin main
step "git worktree add on a feature branch" git worktree add -q "$W/wt" -b feature/gate
cd "$W/wt" || exit 2
echo "hello from a worktree" > NOTE.md; echo "asset body" > "$W/asset.txt"
git add -A && git commit -q -m "Add NOTE" && step "push the feature branch" git push -q -u origin feature/gate
step "open a PR" "$GT" pr create --no-input --yes --title "gate PR" --body-file - -R "$REPO" -H feature/gate -B main <<<"PR body from the gate"
PR="$("$GT" pr list -R "$REPO" --no-input --json number --jq '.[0].number' 2>/dev/null)"
[ -n "$PR" ] && step "merge PR #$PR (squash)" "$GT" pr merge "$PR" --squash --yes --no-input -R "$REPO" || { echo "FAIL: no PR number"; FAIL=$((FAIL + 1)); }

# --- issues: gt, then gitea-mcp --------------------------------------------------------------------------
step "gt: file an issue" "$GT" issue create --no-input -R "$REPO" -t "gate issue (gt)" -b "filed by gt"
IS="$("$GT" issue list -R "$REPO" --no-input --json number,title --jq '.[] | select(.title=="gate issue (gt)") | .number' 2>/dev/null | head -1)"
step "gt: comment on #$IS" "$GT" issue comment "$IS" --no-input -R "$REPO" -b "comment from gt"
step "gt: close #$IS" "$GT" issue close "$IS" --no-input -R "$REPO" -c "closing"
eq "gt: issue #$IS is closed" closed "$("$GT" issue view "$IS" -R "$REPO" --no-input --json state --jq .state 2>/dev/null)"
step "gitea-mcp: create, comment, close, read back" env GITEA_HOST="$HOST" python3 -I "$HERE/gitea_mcp_issue.py" "$OWNER" "$NAME"

# --- release with an asset ----------------------------------------------------------------------------
step "create a release with an asset" "$GT" release create v0.0.1 "$W/asset.txt" -R "$REPO" --no-input --title "gate release" --notes "gate" --target main
eq "release asset is listed" asset.txt "$("$GT" api "repos/$REPO/releases/tags/v0.0.1" --jq '.assets[0].name' --no-input 2>/dev/null)"

# --- Actions: dispatch the trivial workflow and wait --------------------------------------------------------
ok=1
for _ in 1 2 3 4 5 6 7 8; do
  if LAST="$("$GT" workflow run smoke.yml --ref main --follow --timeout 5m --no-input -R "$REPO" 2>&1)"; then ok=0; break; fi
  case "$LAST" in *"not found"*|*"No workflow"*|*404*) sleep 4 ;; *) break ;; esac
done
if [ $ok = 0 ]; then echo "PASS: dispatch smoke.yml and follow it to success"; PASS=$((PASS + 1))
else echo "FAIL: dispatch smoke.yml and follow it to success"; echo "$LAST" | tail -6 | sed 's/^/      /'; FAIL=$((FAIL + 1)); fi

# --- forge map + guard --------------------------------------------------------------------------------------------
cd "$W" || exit 2
step "forge-map-gen sees the new repo" "$HOME/.claude/bin/forge-map-gen"
eq "forge map: throwaway repo maps to gitea" gitea "$(jq -r --arg r "$OWNER/$NAME" '.repos[$r] // "missing"' "$HOME/.claude/forge-map.json")"
hook() { jq -n --arg c "$1" --arg m "$2" '{tool_name:"Bash",cwd:"/tmp",permission_mode:$m,tool_input:{command:$c}}' | bash "$HOOK"; }
out="$(hook "gh issue list -R $REPO" default)"
mode="$(jq -r '.mode // "warn"' "$HOME/.claude/forge-guard.json" 2>/dev/null || echo warn)"
if [ "$mode" = deny ]; then
  eq "guard: gh against a gitea repo is denied (deny mode)" deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
else
  eq "guard: gh against a gitea repo warns with the gt equivalent (warn mode)" "warn+gt" \
     "$(jq -r 'if .hookSpecificOutput.permissionDecision then "decision" elif (.hookSpecificOutput.additionalContext|test("lives on Gitea.*gt issue")) then "warn+gt" else "other" end' <<<"$out")"
fi
eq "guard: an unmapped kmbrimble repo is denied under bypassPermissions" deny \
   "$(hook 'gh issue list -R kmbrimble/not-a-real-repo-xyz' bypassPermissions | jq -r '.hookSpecificOutput.permissionDecision')"
eq "guard: a destructive verb is denied under bypassPermissions" deny \
   "$(hook "gt repo delete $REPO" bypassPermissions | jq -r '.hookSpecificOutput.permissionDecision')"
if [ "$(command -v gh)" = /usr/local/bin/gh ]; then
  eq "gh shim warns on stderr for the gitea repo" 1 "$(FORGE_GUARD_MODE=warn gh issue list -R "$REPO" 2>&1 >/dev/null | grep -c 'lives on Gitea')"
else
  echo "SKIP: gh shim check (gh is not the shim: pre-update image)"
fi
exit 0
