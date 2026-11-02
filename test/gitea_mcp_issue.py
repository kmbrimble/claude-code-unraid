#!/usr/bin/env python3
"""Drive gitea-mcp over stdio the way Claude Code does: create an issue, comment on it, close it, and
read it back. Used by test/stage2-gate.sh. Usage: gitea_mcp_issue.py OWNER REPO

Needs GITEA_TOKEN and GITEA_HOST (or GITEA_CLI_HOST) in the environment, exactly like the registered
server. The launcher is /usr/local/lib/gitea-mcp-launch.sh unless GITEA_MCP_LAUNCHER overrides it.
Prints one line per step; exits non-zero on the first failure. Never prints the token."""
import json
import os
import select
import subprocess
import sys

LAUNCHER = os.environ.get("GITEA_MCP_LAUNCHER", "/usr/local/lib/gitea-mcp-launch.sh")


def main(owner, repo):
    proc = subprocess.Popen([LAUNCHER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    nid = [0]

    def rpc(method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if not notify:
            nid[0] += 1
            msg["id"] = nid[0]
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()
        if notify:
            return None
        while True:
            if not select.select([proc.stdout], [], [], 60)[0]:
                raise TimeoutError(method)
            line = proc.stdout.readline()
            if not line:
                raise EOFError("gitea-mcp exited")
            resp = json.loads(line)
            if resp.get("id") == nid[0]:
                return resp

    def call(tool, **args):
        resp = rpc("tools/call", {"name": tool, "arguments": args})
        if "error" in resp or resp["result"].get("isError"):
            raise RuntimeError(f"{tool}: {json.dumps(resp)[:300]}")
        text = "".join(c.get("text", "") for c in resp["result"].get("content", []))
        try:
            return json.loads(text)
        except ValueError:
            return text

    try:
        rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "gate", "version": "1"}})
        rpc("notifications/initialized", notify=True)
        me = call("get_me")
        print("get_me ok:", (me.get("login") or me.get("username") or "?") if isinstance(me, dict) else "?")
        made = call("issue_write", method="create", owner=owner, repo=repo, title="stage2 gate (via gitea-mcp)", body="filed by test/gitea_mcp_issue.py")
        number = made.get("number") if isinstance(made, dict) else None
        if not number:
            raise RuntimeError(f"create returned no issue number: {str(made)[:200]}")
        print("issue_write create ok: #%s" % number)
        call("issue_write", method="add_comment", owner=owner, repo=repo, issue_number=number, body="comment via gitea-mcp")
        print("issue_write add_comment ok")
        call("issue_write", method="update", owner=owner, repo=repo, issue_number=number, state="closed")
        print("issue_write update state=closed ok")
        got = call("issue_read", method="get", owner=owner, repo=repo, issue_number=number)
        state = got.get("state") if isinstance(got, dict) else None
        if state != "closed":
            raise RuntimeError(f"issue #{number} state is {state!r}, expected 'closed'")
        print("issue_read get ok: state closed")
    except Exception as exc:
        print(f"MCP DRIVE FAILED: {exc}", file=sys.stderr)
        proc.kill()
        sys.exit(1)
    proc.kill()


if __name__ == "__main__":
    main(*sys.argv[1:3])
