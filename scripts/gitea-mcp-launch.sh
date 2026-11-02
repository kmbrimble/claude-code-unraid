#!/bin/sh
# Starts gitea-mcp (stdio) for Claude Code. Registered once, user scope, by entrypoint.sh with no
# `-e` flags, so nothing secret is frozen into ~/.claude.json: this wrapper reads the container
# environment at launch. gitea-mcp itself wants GITEA_ACCESS_TOKEN, while the CA template (and gt)
# use GITEA_TOKEN, hence the mapping. GITEA_HOST/GITEA_CLI_HOST come from the template too.
: "${GITEA_TOKEN:?gitea-mcp-launch: GITEA_TOKEN is not set}"
GITEA_HOST="${GITEA_HOST:-${GITEA_CLI_HOST:-}}"
: "${GITEA_HOST:?gitea-mcp-launch: neither GITEA_HOST nor GITEA_CLI_HOST is set}"
export GITEA_HOST
export GITEA_ACCESS_TOKEN="$GITEA_TOKEN"
exec "${GITEA_MCP_BIN:-/usr/local/bin/gitea-mcp}" -t stdio
