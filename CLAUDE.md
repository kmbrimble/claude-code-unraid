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
3. On success, tell the user: **force update the `claude-code` container in unRAID's Docker
   tab.**
4. **Warn the user explicitly** that force-updating `claude-code` recreates the container the
   agent is running in and therefore ends the current session. They can reattach afterwards
   with:
   ```
   docker exec -it claude-code tmux attach -t claude
   ```

## Known maintenance items

- The GitHub Actions workflow uses older action versions (Node 20 deprecation notices).
  `actions/checkout`, `docker/login-action`, and `docker/build-push-action` could be bumped to
  current majors. This is a small, self-contained change suitable for a `/feature`.

## Scope notes

- Do not modify anything under `/projects/butler` or any other project from this repo's work.
- Do not run `docker stop`, `docker rm`, `docker restart`, or similar against the `claude-code`
  container — these are denied in settings and would kill your own session anyway.
