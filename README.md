# claude-code-unraid

A Docker image that runs an autonomous [Claude Code](https://claude.com/claude-code) agent as a
long-lived unRAID container, with a persisted home directory, GitHub CLI auth wired up
non-interactively, and a `tmux` session you can attach to at any time.

This repository builds the image; it is not an application in its own right. If you're reading
this from inside the running container, you're looking at the agent's own source.

## What's in the image

- **Base:** `node:22-bookworm-slim`
- **Tooling:** `git`, `tmux`, `docker.io` (client, for controlling sibling containers via the
  mounted socket), `gh` (GitHub CLI), `ttyd` (browser terminal), `jq`, `curl`, `python3`,
  `openssh-client`
- **Agent:** `@anthropic-ai/claude-code` and `claude-auto-retry`, installed globally via npm

See `Dockerfile` for the exact build steps and `entrypoint.sh` for what runs at container start.

## Building and running locally

```
docker build -t claude-code-unraid .
docker run -d --name claude-code \
  -v /path/to/home:/root \
  -v /path/to/projects:/projects \
  -v /path/to/config:/config:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e GH_TOKEN=ghp_... \
  claude-code-unraid
```

Attach to the agent's `tmux` session:

```
docker exec -it claude-code tmux attach -t claude
```

To validate a build without deploying it, run the smoke test instead (see `test/README.md`):

```
bash test/smoke.sh
```

## unRAID setup

The published image is `ghcr.io/kmbrimble/claude-code-unraid:latest`. A ready-made Community
Applications template is checked into this repo at `templates/claude-code.xml` (secrets
blanked) — import it, or configure the container manually with the settings below.

### Required mounts

These map container paths that must **never change** without also editing the template and
migrating existing data — see `CLAUDE.md` for details.

| unRAID host path                       | Container path          | Mode | Purpose                                              |
|-----------------------------------------|--------------------------|------|-------------------------------------------------------|
| `/mnt/user/appdata/claude-code/home`    | `/root`                  | rw   | Persists Claude auth, settings, agents, MCP config    |
| `/mnt/user/appdata/claude-code/projects`| `/projects`              | rw   | Working area for the repos the agent edits            |
| `/mnt/user/appdata/claude-code/config`  | `/config`                | ro   | Read-only secrets (for example a Home Assistant token) |
| `/var/run/docker.sock`                  | `/var/run/docker.sock`   | rw   | Lets the agent inspect/control sibling containers      |

### Environment variables

| Variable          | Required | Purpose                                                                 |
|--------------------|----------|--------------------------------------------------------------------------|
| `GH_TOKEN`         | No       | GitHub token. If set, `entrypoint.sh` runs `gh auth setup-git` so `git push` and `gh` work non-interactively. Without it, autonomous pushes are disabled. |
| `TTYD_CREDENTIAL`  | Yes      | `user:password` for the browser-based `ttyd` terminal on port `7681`. `ttyd` only starts if this is set, so there is never an unauthenticated web shell — see the warning below. |
| `CONNECTOR_TOKEN`  | No       | Bearer token for the MCP connector on port `8765` (see [`connector/README.md`](connector/README.md)). The connector only starts if this is set. Its `run_command` tool is arbitrary shell in this container, so treat it like `TTYD_CREDENTIAL`: strong token, trusted LAN only. |
| `GIT_USER_NAME`    | No       | Defaults to `Butler Bot`.                                                |
| `GIT_USER_EMAIL`   | No       | Defaults to `butler-bot@users.noreply.github.com`.                       |
| `HA_BASE_URL`      | No       | Home Assistant API base, for agent tasks that touch Home Assistant.     |

Never bake `GH_TOKEN` or any other credential into the image — supply it as a template
environment variable at container start, as above.

### Interacting with the agent

The container has no shell entrypoint of its own; it starts a detached `tmux` session and idles.
Attach to talk to the agent:

```
docker exec -it claude-code tmux attach -t claude
```

Detach without killing the session with `Ctrl-b d`.

Alternatively, if `TTYD_CREDENTIAL` is set, browse to `http://<unraid-ip>:7681` for the same
`tmux` session in a browser terminal, password-gated by that credential. `ttyd` serves a real
shell into a container that holds the Docker socket — effectively host root — so only expose
port 7681 on a trusted LAN, and always set a strong `TTYD_CREDENTIAL`.

If `CONNECTOR_TOKEN` is set, Claude Cowork (or another Claude Code) can drive the agent over
MCP at `http://<unraid-ip>:8765/mcp` with that bearer token — list and resume its sessions,
start new ones, run commands. Details in [`connector/README.md`](connector/README.md).

## Deploying a change to this repo

1. Push to `main`.
2. Watch the build: `gh run list --limit 1`, then `gh run watch <id> --exit-status`.
3. Once the build succeeds, force-update the `claude-code` container from unRAID's Docker tab to
   pick up the new image.

Force-updating recreates the container — if you're running the agent from inside it at the time,
that ends the current session. Reattach afterwards with the same command as above.
