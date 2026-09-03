#!/usr/bin/env python3
"""Speak a minimal MCP stdio handshake to the PAL server and check its tool list.

Run inside the built image (needs the venv's dependencies), with no API key
set, to prove PAL imports cleanly and DISABLED_TOOLS took effect. Exits 0 and
prints the tool list on success, non-zero with a diagnostic otherwise.
"""
import json
import subprocess
import sys

REQUIRED_TOOLS = {"consensus", "codereview", "precommit", "challenge", "listmodels", "version"}
EXCLUDED_TOOLS = {
    "chat", "analyze", "refactor", "testgen", "secaudit", "docgen",
    "tracer", "debug", "thinkdeep", "planner", "clink", "apilookup",
}


def main():
    proc = subprocess.Popen(
        ["/opt/pal-mcp/venv/bin/pal-mcp-server"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )

    def send(msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def recv(timeout=15):
        import select
        r, _, _ = select.select([proc.stdout], [], [], timeout)
        if not r:
            raise TimeoutError("no response from pal-mcp-server within timeout")
        line = proc.stdout.readline()
        if not line:
            raise EOFError("pal-mcp-server closed stdout: " + proc.stderr.read())
        return json.loads(line)

    try:
        send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "smoke", "version": "1"},
            },
        })
        recv()
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        resp = recv()
        tools = {t["name"] for t in resp["result"]["tools"]}
    except Exception as exc:
        print(f"HANDSHAKE FAILED: {exc}", file=sys.stderr)
        proc.kill()
        sys.exit(1)

    proc.kill()
    print("tools:", sorted(tools))
    missing = REQUIRED_TOOLS - tools
    unexpected = EXCLUDED_TOOLS & tools
    if missing or unexpected:
        print(f"missing required: {missing}", file=sys.stderr)
        print(f"unexpectedly present: {unexpected}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
