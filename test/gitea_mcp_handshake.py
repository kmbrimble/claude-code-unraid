#!/usr/bin/env python3
"""MCP stdio handshake against gitea-mcp, started the way Claude Code starts it: through
/usr/local/lib/gitea-mcp-launch.sh with GITEA_TOKEN / GITEA_HOST in the environment (set by the
caller; any dummy token and an unreachable host are fine, listing tools makes no Gitea request).
Exits 0 when initialize and tools/list answer and the expected tool groups are present."""
import json
import select
import subprocess
import sys

LAUNCHER = sys.argv[1] if len(sys.argv) > 1 else "/usr/local/lib/gitea-mcp-launch.sh"
# Only names stable across gitea-mcp releases: it consolidated tools into <scope>_read/_write in 1.12.
REQUIRED_SUBSTRINGS = ("issue", "pull_request", "repo", "release")


def main():
    proc = subprocess.Popen([LAUNCHER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def send(msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def recv(timeout=20):
        if not select.select([proc.stdout], [], [], timeout)[0]:
            raise TimeoutError("no response from gitea-mcp within timeout")
        line = proc.stdout.readline()
        if not line:
            raise EOFError("gitea-mcp closed stdout: " + proc.stderr.read()[:300])
        return json.loads(line)

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}}})
        recv()
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools = {t["name"] for t in recv()["result"]["tools"]}
    except Exception as exc:
        print(f"HANDSHAKE FAILED: {exc}", file=sys.stderr)
        proc.kill()
        sys.exit(1)
    proc.kill()
    print(len(tools), "tools:", sorted(tools))
    missing = [s for s in REQUIRED_SUBSTRINGS if not any(s in t for t in tools)]
    if missing:
        print(f"no tool matching: {missing}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
