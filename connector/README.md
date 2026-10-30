# claude-code-connector

MCP server (Streamable HTTP) baked into the `claude-code` image. Lets Claude Cowork / the
desktop app / another Claude Code drive the `claude` CLI inside this container: list
projects and sessions, start or resume sessions, run shell commands, poll long jobs.

Built in the `Dockerfile` into `/opt/claude-code-connector`; started by `entrypoint.sh` on
port 8765 **only with a complete auth config for its `AUTH_MODE`** (default `bearer`: `CONNECTOR_TOKEN`; `access`/`both` also need `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD`, `ACCESS_ALLOWED_EMAILS`; see OPERATIONS.md §4). Log:
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

`wait_seconds` is clamped to `MAX_WAIT_SECONDS` (default 55s) because the MCP client
abandons a blocking call before then; a clamped call says so in `wait_clamped` and still
returns `job_id` and `session_id`. `get_job` accepts `progress_events: N` to tail the live
session transcript of a running Claude job, which is otherwise silent until it finishes.
Jobs are killed with SIGTERM then SIGKILL after `KILL_GRACE_MS` (default 10s), on the
wall clock (`timeout_seconds` / `DEFAULT_TIMEOUT_MS`) or, if enabled, on no progress
(`idle_timeout_seconds` / `IDLE_TIMEOUT_MS`, default 0 = off). See OPERATIONS.md §4.

## Log

Structured JSON Lines (requests, connections, sessions, tool calls, process health) at
`CONNECTOR_LOG_FILE`, size-rotated. Never contains the token, headers, bodies or tool
arguments' values. Detail, event list and `jq` recipes: OPERATIONS.md §4.

| Variable | Default | |
|---|---|---|
| `CONNECTOR_LOG_FILE` | `/root/connector-logs/connector.jsonl` | Where it is written (directory auto-created). |
| `CONNECTOR_LOG_MAX_BYTES` | `20971520` | Rotate when a write would pass this size. |
| `CONNECTOR_LOG_KEEP` | `3` | Rotated files kept (`.1`, `.2`, ...). |

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
