# claude-code-connector

MCP server (Streamable HTTP) baked into the `claude-code` image. Lets Claude Cowork / the
desktop app / another Claude Code drive the `claude` CLI inside this container: list
projects and sessions, start or resume sessions, run shell commands, poll long jobs.

Built in the `Dockerfile` into `/opt/claude-code-connector`; started by `entrypoint.sh` on
port 8765 **only when `CONNECTOR_TOKEN` is set** (unRAID template variable). Log:
`~/claude-code-connector.log`.

## Tools

| Tool | What it does |
|---|---|
| `list_projects` | Directories under `/projects` |
| `list_sessions` | Sessions from `~/.claude/projects` (id, cwd, first prompt, mtime) |
| `get_session_transcript` | Last N user/assistant messages of a session |
| `start_session` | `claude -p --session-id <new> "<prompt>"` in a project folder |
| `continue_session` | `claude -p --resume <id> "<prompt>"` — full context preserved |
| `run_command` | `bash -lc "<cmd>"` in a project folder |
| `read_file` | Read a file under `/projects` |
| `get_job` / `list_jobs` / `cancel_job` | Long calls return a `job_id` after `wait_seconds`; poll here |

## Connect

- Cowork / desktop: Settings → Connectors → Add custom connector →
  `http://<unraid-ip>:8765/mcp`, Bearer token = `CONNECTOR_TOKEN`.
- Claude Code: `claude mcp add --transport http cc-unraid http://<unraid-ip>:8765/mcp --header "Authorization: Bearer $CONNECTOR_TOKEN"`

## Notes

- `SKIP_PERMISSIONS=1` is on by default: headless `claude -p` cannot answer permission
  prompts. The deny list in `~/.claude/settings.json` still applies. Pass `permission_mode`
  per call to override.
- `run_command` is arbitrary shell in a container that holds the Docker socket. The token
  is the security boundary; keep the port on the trusted LAN.
- Job state is in-memory; a container restart or image update drops it.

## Dev

```bash
cd connector && npm i && npm run build
```
