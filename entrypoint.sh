#!/usr/bin/env bash
 set -euo pipefail

#Keep a long lived tmux server running for the agent session.
tmux new-session -d -s claude -c /projects || true
echo "Container ready. Attach with: docker exec -it claude-code tmux attach -t claude"

#Hold the container open.
tail -f /dev/null
