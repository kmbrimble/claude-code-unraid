# claude-code-unraid — project context

This repo defines the Docker image for the Claude Code agent container itself — the container
you are currently running inside. It contains a `Dockerfile`, an `entrypoint.sh`, and a
container smoke test.

Use British/Australian English in all writing and comments.

**Read this first: you are modifying your own runtime.** A bad change here does not break an
app, it breaks the agent. Be correspondingly conservative.

## Layout

- Repo (in container): `/projects/claude-code-unraid`
- GitHub: `kmbrimble/claude-code-unraid`
- Published image: `ghcr.io/kmbrimble/claude-code-unraid:latest`
- Live container: `claude-code` (this one)

## Test command

- **Container smoke test:** `bash test/smoke.sh`

This is the ONLY test harness in this repo. There is no `npm test` here; do not run it.

The smoke test builds the image, runs it, and checks tooling presence and that SIGTERM stop is
fast. It is slow (a full image build) and requires the Docker socket. Run it deliberately at the
red-baseline and green-confirmation points, not repeatedly during iteration.

Because a full run is expensive, prefer to validate syntax and obvious errors cheaply first
(for example `docker build` alone, or shell syntax checking `entrypoint.sh` with `sh -n`) before
committing to a full smoke run.

## Non-negotiable constraints

1. **Persistence mappings must not change.** The container expects:
   - `/mnt/user/appdata/claude-code/home` → `/root` (auth, settings, agents, commands, MCP config)
   - `/mnt/user/appdata/claude-code/projects` → `/projects`
   - `/mnt/user/appdata/claude-code/config` → `/config`
   - `/var/run/docker.sock` → `/var/run/docker.sock`
   Changing any destination path orphans existing state. If a change requires a new mapping, do
   NOT silently alter an existing one — flag it, because the unRAID CA template must be edited
   by the user in step with the image.
2. **Never bake secrets into the image.** `GH_TOKEN` and any other credentials are supplied as
   CA template environment variables at runtime. No tokens, keys, or passwords in the
   `Dockerfile`, `entrypoint.sh`, or any committed file.
3. **`gh auth setup-git` must continue to run in the entrypoint**, otherwise `git push` and
   `gh run watch` stop working non-interactively from inside the container.
4. **The GitHub CLI (`gh`), `git`, `tmux`, and `node` must remain present** in the image. The
   smoke test guards this; do not weaken it.
5. **SIGTERM must be handled promptly.** A slow stop makes unRAID force-kill the container. The
   smoke test guards this.
6. **Do not remove or relax the permission deny list** in `~/.claude/settings.json` behaviour
   assumptions. Note that file lives in the persisted home mapping, not the image.
7. **The MCP connector (`connector/`, port 8765) must only start when `CONNECTOR_TOKEN` is
   set.** Its `run_command` tool is arbitrary shell in a container holding the Docker socket.
   The smoke test guards this; do not weaken it.

## Deploy and verify

1. Push to `main`.
2. Watch the GitHub Actions build: `gh run list --limit 1`, then
   `gh run watch <id> --exit-status`.
3. On success, tell the user the image is built and waiting. **Do not force-update as part of
   a routine change** — a `/feature` run on this repo should be a pure source+CI change; the
   running container does not need to change for the work to be done.
4. **Warn the user explicitly** before any force-update: it recreates the container the agent
   is running in, ending the current session and every other Remote Control session, and
   dropping the MCP connector with all its in-memory job state. They can reattach afterwards
   with:
   ```
   docker exec -it claude-code tmux attach -t claude
   ```
5. The force-update itself must run **from the host**, never from inside the container being
   updated — an in-container SSH-to-self commits suicide mid-script. The procedure and its
   traps are in `OPERATIONS.md` §6. `/projects/.ops/force-update-with-watchdog.sh` wraps it
   and arms a recovery watchdog first, because the container's restart policy is `no`: a
   failed recreate leaves it stopped, and once it is stopped nothing in the cloud can reach
   the host to restart it.

## Code review

Read by `code-diff-reviewer`, `code-audit` and `code-security-audit` to calibrate their
escalation scoring. These four answers are what stop them guessing.

**Exposure: internet-facing behind authentication — and the blast radius is the whole box.**
The MCP connector (`connector/`, port 8765) is published at `https://claude.kiztigs.com/mcp`
and reached from Claude Cowork over the internet; a bearer token is the entire security
boundary (constraint 7). Score exposure 2. Score authority at the top of its range for
anything touching the connector, `CONNECTOR_TOKEN`, or `entrypoint.sh` — `run_command` is
arbitrary shell in a container holding the Docker socket, so a hole here is root on unRAID,
not a bug in an app.

**What owns state that matters.** There is no user data here in the usual sense; the "data"
is the agent's own runtime state, and nothing this repo knows about backs it up.

- `entrypoint.sh` — the seed-if-absent logic for `/root/.claude/pal/custom_models.json`. It
  must never overwrite an existing file: that roster is hand-edited and a rebuild clobbering
  it is silent, unrecoverable loss. `test/smoke.sh` guards it.
- The persistence mappings in constraint 1. Changing a destination path orphans everything
  the agent has — auth, settings, agents, skills, `review-lib`, and every project repo.
- `templates/claude-code.xml` — carries the `!secret` token, not the key. A review must never
  quote a value out of it.

**Infrastructure this repo depends on but does not contain.** This is the list that prevents
false positives, and its absence has already cost one:

- **`unraid-secretsman`** resolves `!secret claude-code/bedrock-api-key` at container-create
  time, through a live patch to the host's dockerMan `Helpers.php`. Nothing in this repo
  resolves that syntax. On 3 Sep 2026 a reviewer correctly observed exactly that and filed it
  as a defect, and `advisor` confirmed it HIGH. It was wrong — the mechanism is on the host.
- **Whatever publishes `https://claude.kiztigs.com/mcp`.** The ingress is not here; the
  hostname appears nowhere in this tree.
- **The unRAID CA template**, applied by the host. The committed `templates/claude-code.xml`
  is a copy and is known to have drifted from the live one.
- **The persisted appdata mounts**, created and owned by the host.
- **`/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container`** — the
  force-update path, on the host.

Any finding of the form "nothing in this repo implements X" against one of these belongs in
`UNVERIFIABLE FROM THIS REPO`, never in Findings.

**Test reality — assume the coverage gap is high.** `test/smoke.sh` is the only harness. It
builds the whole image and runs a real container, so it is slow, needs the Docker socket, and
is deliberately not run per-iteration; in practice most changes here are validated with
`docker build` and `sh -n` alone before a single smoke run at the end.

- Covered: tool presence and pinned versions (including the four security scanners), the
  connector's `CONNECTOR_TOKEN` gate, SIGTERM stop time, PAL's `mcp==1.29.1` pin, and the
  `custom_models.json` seed-if-absent behaviour.
- Not covered at all: the entrypoint's Remote Control auto-launch path, `gh auth setup-git`,
  and anything that only manifests after a real force-update against the live host.

Score the test-coverage-gap factor accordingly for anything outside that first list.

## Known maintenance items

- The GitHub Actions build logs "Node 20 is being deprecated" on every run. **The earlier
  diagnosis here was wrong and has been corrected:** the workflow is already on current
  action majors (`actions/checkout@v4`, `docker/login-action@v3`,
  `docker/setup-buildx-action@v3`, `docker/build-push-action@v6`), verified against run
  `33857063051` on 4 Sep 2026. The warning is about the runner's default Node runtime, not
  the action versions, and the runner already defaults to Node 24 — so bumping the actions
  would fix nothing. No action needed; leave it unless a build actually breaks.

## Scope notes

- Do not modify anything under `/projects/butler` or any other project from this repo's work.
- Do not run `docker stop`, `docker rm`, `docker restart`, or similar against the `claude-code`
  container — these are denied in settings and would kill your own session anyway.
