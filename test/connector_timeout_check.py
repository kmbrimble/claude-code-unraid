#!/usr/bin/env python3
"""Drive the connector's real MCP endpoint to prove the timeout fix behaviourally.

Run inside a smoke-test container that was started with a low DEFAULT_TIMEOUT_MS
and CLAUDE_BIN pointed at a fake, controllably-slow "claude" stand-in. Speaks the
Streamable HTTP MCP transport for real: initialize, then two start_session calls
(one that outruns the effective timeout, one that finishes inside it).

Usage: connector_timeout_check.py <bearer-token> <expected-timeout-seconds>
"""
import json
import re
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8765/mcp"


def call(token, session_id, method, params=None, id_=None, timeout=30):
    body = {"jsonrpc": "2.0", "method": method}
    if id_ is not None:
        body["id"] = id_
    if params is not None:
        body["params"] = params
    headers = {
        "content-type": "application/json",
        "accept": "application/json, text/event-stream",
        "authorization": f"Bearer {token}",
    }
    if session_id:
        headers["mcp-session-id"] = session_id
    req = urllib.request.Request(BASE, data=json.dumps(body).encode(), headers=headers, method="POST")
    resp = urllib.request.urlopen(req, timeout=timeout)
    new_sid = resp.headers.get("mcp-session-id")
    raw = resp.read().decode().strip()
    if id_ is None:
        return new_sid, None
    if raw.startswith("{"):
        candidates = [raw]
    else:
        candidates = re.findall(r"^data:\s*(\{.*\})\s*$", raw, re.MULTILINE)
    objs = [json.loads(c) for c in candidates]
    for o in objs:
        if o.get("id") == id_:
            return new_sid, o
    return new_sid, (objs[-1] if objs else None)


def tool_result(resp):
    result = resp.get("result")
    if result is None:
        raise AssertionError(f"tool call returned no result: {resp}")
    text = result["content"][0]["text"]
    return json.loads(text)


def main():
    token, expected_timeout_s = sys.argv[1], float(sys.argv[2])

    sid, _ = call(token, None, "initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "smoke", "version": "1"},
    }, id_=1)
    if not sid:
        sys.exit("FAIL: no mcp-session-id from initialize")
    call(token, sid, "notifications/initialized")

    # tools/list: description text must be discoverable before it bites, from
    # the live server, not grepped from source.
    _, list_resp = call(token, sid, "tools/list", id_=2)
    tools = {t["name"]: t for t in list_resp["result"]["tools"]}
    start_desc = tools["start_session"]["inputSchema"]["properties"]["timeout_seconds"]["description"]
    if "SIGKILL" not in start_desc or "omit" not in start_desc.lower():
        sys.exit(f"FAIL: start_session timeout_seconds description doesn't explain the omitted-case default/SIGKILL: {start_desc!r}")
    run_desc = tools["run_command"]["inputSchema"]["properties"]["timeout_seconds"]["description"]
    if "SIGKILL" not in run_desc:
        sys.exit(f"FAIL: run_command timeout_seconds description doesn't mention SIGKILL: {run_desc!r}")
    cancel_desc = tools["cancel_job"]["description"]
    if "SIGTERM" not in cancel_desc or "graceful" not in cancel_desc.lower():
        sys.exit(f"FAIL: cancel_job description doesn't contrast its graceful SIGTERM: {cancel_desc!r}")

    # Slow job: sleeps well past the effective (env-driven) timeout.
    _, resp = call(token, sid, "tools/call", {
        "name": "start_session",
        "arguments": {"project": "smoketest-timeout", "prompt": "SLEEP=8"},
    }, id_=3, timeout=30)
    slow_job = tool_result(resp)
    if slow_job.get("status") != "timeout":
        sys.exit(f"FAIL: expected status=timeout for the slow job, got: {slow_job}")
    info = slow_job.get("timeout")
    if not info or info.get("signal") != "SIGKILL":
        sys.exit(f"FAIL: slow job result missing an explicit SIGKILL timeout explanation: {slow_job}")
    if abs(info.get("seconds", -1) - expected_timeout_s) > 1:
        sys.exit(
            f"FAIL: reported timeout seconds ({info.get('seconds')}) doesn't match the "
            f"DEFAULT_TIMEOUT_MS-derived effective timeout ({expected_timeout_s}s) — env var may be shadowed: {slow_job}"
        )
    if not info.get("message") or "timeout_seconds" not in info["message"]:
        sys.exit(f"FAIL: timeout explanation doesn't point the caller at timeout_seconds: {slow_job}")

    # Fast job: finishes well inside the same effective timeout.
    _, resp2 = call(token, sid, "tools/call", {
        "name": "start_session",
        "arguments": {"project": "smoketest-timeout", "prompt": "SLEEP=1"},
    }, id_=4, timeout=30)
    fast_job = tool_result(resp2)
    if fast_job.get("status") != "done":
        sys.exit(f"FAIL: expected status=done for the fast job (happy path broken), got: {fast_job}")
    if fast_job.get("timeout") is not None:
        sys.exit(f"FAIL: fast job unexpectedly carries a timeout explanation: {fast_job}")

    print("OK: slow job timed out with explanation", slow_job["timeout"], "; fast job:", fast_job["status"])


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        sys.exit(f"FAIL: HTTP {e.code}: {e.read().decode()[:500]}")
