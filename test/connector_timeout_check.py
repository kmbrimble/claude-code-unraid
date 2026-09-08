#!/usr/bin/env python3
"""Drive the connector's real MCP endpoint to prove the wait/timeout fixes behaviourally.

Run inside a smoke-test container started with low timeout env vars and
CLAUDE_BIN pointed at the fake, mode-driven "claude" stand-in that test/smoke.sh
installs. Speaks the Streamable HTTP MCP transport for real: initialize, then
tool calls, asserting on what comes back rather than on the source.

Two modes, because they need incompatible container settings:

  --mode=timeout <token> <wall-timeout-s> <max-wait-s> <grace-s>
      wall-clock timeout, SIGTERM->SIGKILL escalation, the wait_seconds clamp,
      the deadline fields, and live transcript progress.

  --mode=idle <token> <idle-timeout-s>
      IDLE_TIMEOUT_MS kills a stalled job but spares a slow, still-active one.
"""
import json
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

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


def connect(token):
    sid, _ = call(token, None, "initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "smoke", "version": "1"},
    }, id_=1)
    if not sid:
        sys.exit("FAIL: no mcp-session-id from initialize")
    call(token, sid, "notifications/initialized")
    return sid


def check_deadline_fields(job, label, expected_timeout_s=None):
    for f in ("elapsed_seconds", "timeout_seconds", "deadline_at", "started_at"):
        if job.get(f) is None:
            sys.exit(f"FAIL: {label} is missing the {f} deadline field: {job}")
    if expected_timeout_s is not None and abs(job["timeout_seconds"] - expected_timeout_s) > 0.5:
        sys.exit(f"FAIL: {label} reports timeout_seconds={job['timeout_seconds']}, expected {expected_timeout_s}: {job}")
    started = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
    deadline = datetime.fromisoformat(job["deadline_at"].replace("Z", "+00:00"))
    gap = (deadline - started).total_seconds()
    if abs(gap - job["timeout_seconds"]) > 0.5:
        sys.exit(f"FAIL: {label} deadline_at is not started_at + timeout_seconds (gap {gap}s): {job}")


def mode_timeout(token, expected_timeout_s, max_wait_s, grace_s):
    sid = connect(token)

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

    # Slow job: sleeps well past the effective (env-driven) wall-clock timeout.
    # It has no SIGTERM handler, so it should die on the graceful signal and
    # never need the escalation.
    _, resp = call(token, sid, "tools/call", {
        "name": "start_session",
        "arguments": {"project": "smoketest-timeout", "prompt": "SLEEP=20"},
    }, id_=3, timeout=30)
    slow_job = tool_result(resp)
    if slow_job.get("status") != "timeout":
        sys.exit(f"FAIL: expected status=timeout for the slow job, got: {slow_job}")
    info = slow_job.get("timeout")
    if not info:
        sys.exit(f"FAIL: slow job result missing its timeout explanation: {slow_job}")
    if info.get("kind") != "wall_clock":
        sys.exit(f"FAIL: slow job should have been killed by the wall clock, got kind={info.get('kind')}: {slow_job}")
    if abs(info.get("seconds", -1) - expected_timeout_s) > 1:
        sys.exit(
            f"FAIL: reported timeout seconds ({info.get('seconds')}) doesn't match the "
            f"DEFAULT_TIMEOUT_MS-derived effective timeout ({expected_timeout_s}s) — env var may be shadowed: {slow_job}"
        )
    if info.get("signal") != "SIGTERM" or info.get("escalated") is not False:
        sys.exit(f"FAIL: a job with no SIGTERM handler should die on SIGTERM without escalating: {slow_job}")
    if not info.get("message") or "timeout_seconds" not in info["message"]:
        sys.exit(f"FAIL: timeout explanation doesn't point the caller at timeout_seconds: {slow_job}")
    check_deadline_fields(slow_job, "slow job", expected_timeout_s)

    # A job that ignores SIGTERM must still be stopped, by SIGKILL, after the
    # grace period — and say that it took the escalation.
    _, resp = call(token, sid, "tools/call", {
        "name": "start_session",
        "arguments": {"project": "smoketest-timeout", "prompt": "TRAP_TERM=1 SLEEP=60"},
    }, id_=4, timeout=30)
    stubborn = tool_result(resp)
    if stubborn.get("status") != "timeout":
        sys.exit(f"FAIL: SIGTERM-ignoring job did not end as a timeout: {stubborn}")
    sinfo = stubborn.get("timeout") or {}
    if sinfo.get("signal") != "SIGKILL" or sinfo.get("escalated") is not True:
        sys.exit(f"FAIL: SIGTERM-ignoring job should have been escalated to SIGKILL: {stubborn}")
    if stubborn.get("elapsed_seconds", 0) < expected_timeout_s:
        sys.exit(f"FAIL: escalated kill happened before the wall-clock timeout even elapsed: {stubborn}")
    if stubborn.get("elapsed_seconds", 999) > expected_timeout_s + grace_s + 3:
        sys.exit(f"FAIL: escalation took far longer than timeout+grace ({expected_timeout_s}+{grace_s}s): {stubborn}")

    # Fast job: finishes well inside the same effective timeout.
    _, resp2 = call(token, sid, "tools/call", {
        "name": "start_session",
        "arguments": {"project": "smoketest-timeout", "prompt": "SLEEP=1"},
    }, id_=5, timeout=30)
    fast_job = tool_result(resp2)
    if fast_job.get("status") != "done":
        sys.exit(f"FAIL: expected status=done for the fast job (happy path broken), got: {fast_job}")
    if fast_job.get("timeout") is not None:
        sys.exit(f"FAIL: fast job unexpectedly carries a timeout explanation: {fast_job}")

    # wait_seconds far above MAX_WAIT_SECONDS: the client would abandon the call
    # long before 300s, so the connector must clamp, say so, and hand back a
    # still-running job that is recoverable by BOTH job_id and session_id.
    started = time.monotonic()
    _, resp3 = call(token, sid, "tools/call", {
        "name": "start_session",
        "arguments": {
            "project": "smoketest-timeout", "prompt": "BIGLOG=1 SLEEP=60",
            "wait_seconds": 300, "timeout_seconds": 120,
        },
    }, id_=6, timeout=30)
    elapsed = time.monotonic() - started
    long_job = tool_result(resp3)
    if elapsed > max_wait_s + 5:
        sys.exit(f"FAIL: wait_seconds=300 blocked for {elapsed:.1f}s; MAX_WAIT_SECONDS={max_wait_s} was not applied")
    if long_job.get("status") != "running":
        sys.exit(f"FAIL: clamped call should return a still-running job, got: {long_job}")
    if not long_job.get("job_id") or not long_job.get("session_id"):
        sys.exit(f"FAIL: clamped call must stay recoverable — needs both job_id and session_id: {long_job}")
    clamp = long_job.get("wait_clamped")
    if not clamp or clamp.get("applied_seconds") != max_wait_s or clamp.get("requested_seconds") != 300:
        sys.exit(f"FAIL: clamped call doesn't report the clamp back to the caller: {long_job}")
    check_deadline_fields(long_job, "clamped job", 120)

    # Live progress: a running `claude -p` prints nothing, so the transcript is
    # the only view in. The stub left a 600MB sparse transcript — larger than a
    # JS string can hold — so events coming back at all proves a tail read.
    _, resp4 = call(token, sid, "tools/call", {
        "name": "get_job",
        "arguments": {"job_id": long_job["job_id"], "progress_events": 5},
    }, id_=7, timeout=30)
    polled = tool_result(resp4)
    if polled.get("status") != "running":
        sys.exit(f"FAIL: the long job should still be running when polled: {polled}")
    progress = polled.get("progress") or {}
    events = progress.get("events") or []
    if not events:
        sys.exit(f"FAIL: no progress events for a running Claude job: {polled}")
    if not any("big-log" in (e.get("text") or "") for e in events):
        sys.exit(f"FAIL: progress events don't contain the transcript the job is writing: {events}")
    if progress.get("transcript_bytes", 0) < 500_000_000:
        sys.exit(f"FAIL: progress test isn't exercising a large transcript: {progress}")
    if progress.get("tail_bytes_read", 10 ** 9) >= progress["transcript_bytes"]:
        sys.exit(f"FAIL: progress read the whole transcript instead of its tail: {progress}")

    # list_jobs is the recovery path after a cut-off call: it must expose the
    # connector-level settings and each job's own deadline.
    _, resp5 = call(token, sid, "tools/call", {"name": "list_jobs", "arguments": {}}, id_=8, timeout=30)
    listing = tool_result(resp5)
    settings = listing.get("settings") or {}
    if settings.get("max_wait_seconds") != max_wait_s or settings.get("default_timeout_seconds") != expected_timeout_s:
        sys.exit(f"FAIL: list_jobs doesn't report the connector's wait/timeout settings: {listing}")
    listed = {j["job_id"]: j for j in listing.get("jobs", [])}
    if long_job["job_id"] not in listed:
        sys.exit(f"FAIL: the running job is not recoverable from list_jobs: {listing}")
    check_deadline_fields(listed[long_job["job_id"]], "listed job", 120)

    # cancel_job: graceful, and reports that it has started terminating.
    _, resp6 = call(token, sid, "tools/call", {
        "name": "cancel_job", "arguments": {"job_id": long_job["job_id"]},
    }, id_=9, timeout=30)
    cancelled = tool_result(resp6)
    if (cancelled.get("terminating") or {}).get("kind") != "cancel":
        sys.exit(f"FAIL: cancel_job didn't report a cancel in progress: {cancelled}")

    print("OK: wall-clock", slow_job["timeout"], "| escalation", stubborn["timeout"],
          "| clamp", clamp, "| progress events", len(events))


def mode_idle(token, idle_s):
    sid = connect(token)

    # Stalled job: no stdout, no transcript growth. Only the idle timer can end
    # it — the wall clock is 60s away.
    _, resp = call(token, sid, "tools/call", {
        "name": "start_session",
        "arguments": {"project": "smoketest-idle", "prompt": "SLEEP=30", "wait_seconds": 20},
    }, id_=3, timeout=45)
    stalled = tool_result(resp)
    if stalled.get("status") != "timeout":
        sys.exit(f"FAIL: a job idle for longer than IDLE_TIMEOUT_MS should be killed, got: {stalled}")
    info = stalled.get("timeout") or {}
    if info.get("kind") != "idle":
        sys.exit(f"FAIL: the kill should be attributed to the idle timer, got kind={info.get('kind')}: {stalled}")
    if abs(info.get("seconds", -1) - idle_s) > 1:
        sys.exit(f"FAIL: idle timeout reports {info.get('seconds')}s, expected IDLE_TIMEOUT_MS ({idle_s}s): {stalled}")
    if "idle_timeout_seconds" not in (info.get("message") or ""):
        sys.exit(f"FAIL: idle timeout message doesn't point the caller at idle_timeout_seconds: {stalled}")
    if stalled.get("elapsed_seconds", 0) > 25:
        sys.exit(f"FAIL: idle job outlived the idle timer by too much: {stalled}")

    # Slow but alive: same idle setting, still silent on stdout, but appending
    # to its session transcript once a second. It must survive to completion.
    _, resp2 = call(token, sid, "tools/call", {
        "name": "start_session",
        "arguments": {"project": "smoketest-idle", "prompt": "ACTIVE=1 SLEEP=8", "wait_seconds": 20},
    }, id_=4, timeout=45)
    active = tool_result(resp2)
    if active.get("status") != "done":
        sys.exit(f"FAIL: a job with a live session transcript was not spared by the idle timer: {active}")
    if active.get("elapsed_seconds", 0) < idle_s * 2:
        sys.exit(f"FAIL: the surviving job didn't even outlive the idle timeout, so it proves nothing: {active}")

    # A shell job has no transcript of its own, so it must be judged on its
    # output alone: a concurrent Claude session writing in the same project
    # directory must not keep a stalled run_command alive.
    call(token, sid, "tools/call", {
        "name": "start_session",
        "arguments": {"project": "smoketest-idle", "prompt": "ACTIVE=1 SLEEP=25", "wait_seconds": 0},
    }, id_=5, timeout=30)
    _, resp3 = call(token, sid, "tools/call", {
        "name": "run_command",
        "arguments": {"project": "smoketest-idle", "command": "sleep 25", "wait_seconds": 20},
    }, id_=6, timeout=45)
    shell_job = tool_result(resp3)
    if shell_job.get("status") != "timeout" or (shell_job.get("timeout") or {}).get("kind") != "idle":
        sys.exit(
            "FAIL: a silent run_command was not killed by the idle timer while another "
            f"session wrote transcripts in the same project: {shell_job}"
        )

    # A resumed session can fork to a new id, leaving the file named by the
    # session id present but no longer written to. Progress and liveness must
    # follow the file that is actually growing, or a live job looks dead.
    call(token, sid, "tools/call", {
        "name": "run_command",
        "arguments": {
            "project": "smoketest-idle",
            "command": "mkdir -p ~/.claude/projects/-projects-smoketest-idle && touch ~/.claude/projects/-projects-smoketest-idle/forked-parent.jsonl",
            "wait_seconds": 10,
        },
    }, id_=7, timeout=30)
    _, resp4 = call(token, sid, "tools/call", {
        "name": "continue_session",
        "arguments": {
            "project": "smoketest-idle", "session_id": "forked-parent",
            "prompt": "ACTIVE=1 FORK=1 SLEEP=8", "wait_seconds": 20, "progress_events": 3,
        },
    }, id_=8, timeout=45)
    forked = tool_result(resp4)
    if forked.get("status") != "done":
        sys.exit(f"FAIL: a resumed session that forked its transcript id was not seen as alive: {forked}")
    tpath = (forked.get("progress") or {}).get("transcript_path", "")
    if not tpath.endswith("forked-parent-fork.jsonl"):
        sys.exit(f"FAIL: progress followed the stale session-id file instead of the one being written: {forked}")

    print("OK: stalled job killed by idle timer", stalled["timeout"],
          "; transcript-active job survived", active["elapsed_seconds"], "s")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    mode = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--mode=")), "timeout")
    if mode == "idle":
        mode_idle(args[0], float(args[1]))
    else:
        mode_timeout(args[0], float(args[1]), float(args[2]), float(args[3]))


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        sys.exit(f"FAIL: HTTP {e.code}: {e.read().decode()[:500]}")
