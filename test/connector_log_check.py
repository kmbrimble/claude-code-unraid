#!/usr/bin/env python3
"""Drive the connector's real HTTP endpoint to prove its structured log behaviourally.

Run inside a smoke-test container. The log is JSON Lines at CONNECTOR_LOG_FILE;
this reads that file back and asserts on what the connector actually wrote, and
— as importantly — on what it did not.

Modes (they need incompatible container settings):

  --mode=main <token> <logfile>
      The event catalogue, the reject reasons, the redaction guarantee, an
      aborted call, SSE req_start immediacy, tool outcomes. The container runs
      with MAX_WAIT_SECONDS=5 so a clamped call is quick.

  --mode=rotate <token> <logfile> <keep> <max_bytes>
      Size rotation, with a tiny CONNECTOR_LOG_MAX_BYTES.

  --mode=unwritable <token> <logfile>
      Sabotages the log path under a running connector: requests must still
      succeed quickly, and once the path is repaired the log resumes and
      reports how many lines it dropped.

CONNECTOR_URL (default http://127.0.0.1:8765) points it at another listener.
"""
import json
import os
import shutil
import socket
import sys
import time
import urllib.error
import urllib.request
import uuid
from urllib.parse import urlparse

URL = os.environ.get("CONNECTOR_URL", "http://127.0.0.1:8765")
MCP = URL + "/mcp"
PROJECTS = os.environ.get("PROJECTS_ROOT", "/projects")


def fail(msg):
    sys.exit(f"FAIL: {msg}")


def http(method, url, token=None, sid=None, body=None, headers=None, timeout=30):
    """One request; returns (status, response headers, raw body). Never raises on 4xx/5xx."""
    h = {"content-type": "application/json", "accept": "application/json, text/event-stream"}
    if token:
        h["authorization"] = f"Bearer {token}"
    if sid:
        h["mcp-session-id"] = sid
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        return r.status, r.headers, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode()


def rpc(token, sid, method, params=None, id_=1, **kw):
    body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if id_ is not None:
        body["id"] = id_
    return http("POST", MCP, token, sid, body, **kw)


def initialize(token, headers=None, url=MCP):
    status, hdrs, _ = http("POST", url, token, None, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "logcheck", "version": "1"}},
    }, headers=headers)
    if status != 200 or not hdrs.get("mcp-session-id"):
        fail(f"initialize returned {status} without a session id")
    sid = hdrs["mcp-session-id"]
    rpc(token, sid, "notifications/initialized", id_=None)
    return sid


def log_files(logfile):
    d, base = os.path.split(logfile)
    try:
        names = os.listdir(d)
    except OSError:
        return []
    return sorted(os.path.join(d, n) for n in names if n == base or n.startswith(base + "."))


def raw_log(logfile):
    out = ""
    for f in log_files(logfile):
        with open(f, errors="replace") as fh:
            out += fh.read()
    return out


def events(logfile):
    evs = []
    for n, line in enumerate(raw_log(logfile).splitlines(), 1):
        if not line.strip():
            continue
        try:
            evs.append(json.loads(line))
        except ValueError:
            fail(f"log line {n} is not valid JSON: {line[:200]!r}")
    return evs


def wait_for(logfile, pred, what, timeout=8):
    """The writer is asynchronous, so poll the file until the event shows up."""
    end = time.monotonic() + timeout
    while True:
        found = [e for e in events(logfile) if pred(e)]
        if found:
            return found[-1]
        if time.monotonic() > end:
            names = sorted({e.get("event") for e in events(logfile)})
            fail(f"no log event for: {what} (log file {logfile}: "
                 f"{'missing/empty' if not events(logfile) else 'has events ' + str(names)})")
        time.sleep(0.2)


def req_end(logfile, what, **want):
    def pred(e):
        return e.get("event") == "req_end" and all(e.get(k) == v for k, v in want.items())
    return wait_for(logfile, pred, f"req_end {what} {want}")


def need(cond, msg):
    if not cond:
        fail(msg)


def raw_abort(token, sid, body_obj):
    """Open a socket, send a request, wait for it to be in flight, then drop the connection."""
    u = urlparse(URL)
    body = json.dumps(body_obj).encode()
    s = socket.create_connection((u.hostname, u.port), timeout=10)
    s.sendall((
        f"POST /mcp HTTP/1.1\r\nHost: {u.netloc}\r\ncontent-type: application/json\r\n"
        f"accept: application/json, text/event-stream\r\nauthorization: Bearer {token}\r\n"
        f"mcp-session-id: {sid}\r\ncontent-length: {len(body)}\r\n\r\n"
    ).encode() + body)
    time.sleep(1.0)
    s.close()


def mode_main(token, logfile):
    marker = "QSMARKER" + uuid.uuid4().hex[:6]
    os.makedirs(PROJECTS + "/smoketest-log", exist_ok=True)

    # (a) initialize: session_created + a 200 req_end naming the rpc method.
    # Sent with a query string (which must be dropped) and Cloudflare-ish headers.
    sid = initialize(token, headers={"cf-connecting-ip": "203.0.113.9", "cf-ray": "9abc123def-SYD",
                                     "user-agent": "logcheck/1 " + "x" * 400},
                     url=f"{MCP}?leak={marker}")
    pre = sid[:8]
    created = wait_for(logfile, lambda e: e.get("event") == "session_created" and e.get("session") == pre,
                       "session_created for the initialize")
    need(created.get("active_sessions", 0) >= 1, f"session_created lacks active_sessions: {created}")
    for e in events(logfile):
        need("ts" in e and "event" in e, f"line without ts/event: {e}")
    ev = req_end(logfile, "initialize", rpc_method="initialize", status=200)
    for k in ("req_id", "method", "path", "duration_ms", "bytes_in", "bytes_out", "conn_id",
              "conn_req_n", "http_version", "client_ip", "cf_ray", "ua", "accept", "session_known"):
        need(k in ev, f"req_end is missing {k}: {ev}")
    need(ev["method"] == "POST" and ev["path"] == "/mcp", f"path must exclude the query string: {ev}")
    need(ev["client_ip"] == "203.0.113.9", f"client_ip should prefer cf-connecting-ip: {ev}")
    need(ev["cf_ray"] == "9abc123def-SYD", f"cf_ray not recorded: {ev}")
    need(len(ev["ua"]) <= 200, f"ua not capped at 200 chars ({len(ev['ua'])})")
    need(ev["http_version"] == "1.1" and ev["conn_req_n"] >= 1, f"connection fields wrong: {ev}")
    need(ev["session_known"] is False and ev["session"] is None, f"initialize carries no session yet: {ev}")
    start = wait_for(logfile, lambda e: e.get("event") == "req_start" and e.get("req_id") == ev["req_id"],
                     "req_start sharing the initialize's req_id")
    need(start.get("path") == "/mcp", f"req_start path wrong: {start}")
    srv = wait_for(logfile, lambda e: e.get("event") == "server_start", "server_start")
    for k in ("pid", "node", "keep_alive_timeout_ms", "headers_timeout_ms", "request_timeout_ms",
              "max_wait_seconds", "default_timeout_ms", "idle_timeout_ms", "kill_grace_ms", "log_file"):
        need(k in srv, f"server_start is missing {k}: {srv}")
    wait_for(logfile, lambda e: e.get("event") == "conn_open", "conn_open")

    # healthz is logged too.
    http("GET", URL + "/healthz")
    req_end(logfile, "healthz", path="/healthz", status=200)

    # (b) no session id on a non-initialize request: 400 and the stable reason.
    status, _, _ = rpc(token, None, "tools/list", id_=2)
    need(status == 400, f"expected 400 for no-session non-initialize, got {status}")
    req_end(logfile, "no session", status=400, reject_reason="no_session_non_initialize", rpc_method="tools/list")

    # (c) unknown session id: 404.
    bogus = str(uuid.uuid4())
    status, _, _ = rpc(token, bogus, "tools/list", id_=2)
    need(status == 404, f"expected 404 for unknown session, got {status}")
    e = req_end(logfile, "unknown session", status=404, reject_reason="unknown_session")
    need(e["session"] == bogus[:8] and e["session_known"] is False, f"unknown session fields wrong: {e}")
    status, _, _ = http("GET", MCP, token, None, headers={"accept": "text/event-stream"})
    need(status == 400, f"expected 400 for GET without a session header, got {status}")
    req_end(logfile, "GET without session header", status=400, reject_reason="missing_session_header")

    # (d) wrong bearer: 401, reason, and the wrong token must not be written down.
    wrong = "WRONGTOKEN" + uuid.uuid4().hex
    status, _, _ = rpc(wrong, sid, "tools/list", id_=2)
    need(status == 401, f"expected 401 for a wrong bearer, got {status}")
    req_end(logfile, "wrong bearer", status=401, reject_reason="bad_bearer")
    status, _, _ = http("POST", MCP, None, None, {"jsonrpc": "2.0", "id": 1, "method": "ping"})
    need(status == 401, f"expected 401 for a missing bearer, got {status}")
    req_end(logfile, "missing bearer", status=401, reject_reason="missing_bearer")
    # A malformed body is the other way to earn a 400 on a valid session.
    u = urlparse(URL)
    s = socket.create_connection((u.hostname, u.port), timeout=10)
    junk = b"{not json"
    s.sendall((f"POST /mcp HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\n"
               f"authorization: Bearer {token}\r\ncontent-length: {len(junk)}\r\nconnection: close\r\n\r\n").encode() + junk)
    reply = s.recv(200)
    s.close()
    need(b" 400 " in reply.split(b"\r\n")[0], f"malformed JSON should still be a 400: {reply[:80]!r}")
    req_end(logfile, "malformed body", status=400, reject_reason="body_parse_failed")

    # (e) tool calls: the name and the argument KEYS, never the values.
    valmark = "VALMARKER" + uuid.uuid4().hex[:8]
    rpc(token, sid, "tools/call", {"name": "get_job", "arguments": {"job_id": valmark, "progress_events": 2}}, id_=3)
    ts = wait_for(logfile, lambda e: e.get("event") == "tool_call_start" and e.get("tool") == "get_job", "tool_call_start get_job")
    # Schema defaults (wait_seconds) are keys too once zod has parsed the call.
    need({"job_id", "progress_events"} <= set(ts.get("arg_keys", [])) <= {"job_id", "progress_events", "wait_seconds"},
         f"arg_keys should be the schema's key names: {ts}")
    wait_for(logfile, lambda e: e.get("event") == "tool_call_end" and e.get("tool") == "get_job", "tool_call_end get_job")
    rpc(token, sid, "tools/call", {"name": "list_jobs", "arguments": {}}, id_=4)
    te = wait_for(logfile, lambda e: e.get("event") == "tool_call_end" and e.get("tool") == "list_jobs", "tool_call_end list_jobs")
    need(te.get("outcome") == "ok" and "duration_ms" in te, f"list_jobs end event wrong: {te}")
    e = req_end(logfile, "list_jobs", rpc_method="tools/call", tool="list_jobs", status=200)
    need(e["session"] == pre and e["session_known"] is True, f"session fields wrong on a live session: {e}")

    # Outcomes: ok / wait_clamped / timeout / error, each with a job id where one exists.
    rpc(token, sid, "tools/call", {"name": "run_command", "arguments": {
        "project": "smoketest-log", "command": "true", "wait_seconds": 3}}, id_=5)
    o = wait_for(logfile, lambda e: e.get("event") == "tool_call_end" and e.get("tool") == "run_command"
                 and e.get("outcome") == "ok", "run_command outcome ok")
    need(o.get("job_id"), f"run_command end lacks job_id: {o}")
    rpc(token, sid, "tools/call", {"name": "run_command", "arguments": {
        "project": "smoketest-log", "command": "sleep 30", "wait_seconds": 600}}, id_=6)
    o = wait_for(logfile, lambda e: e.get("event") == "tool_call_end" and e.get("outcome") == "wait_clamped", "outcome wait_clamped")
    need(o.get("job_id"), f"clamped end lacks job_id: {o}")
    rpc(token, sid, "tools/call", {"name": "run_command", "arguments": {
        "project": "smoketest-log", "command": "sleep 30", "idle_timeout_seconds": 1, "wait_seconds": 5}}, id_=7)
    wait_for(logfile, lambda e: e.get("event") == "tool_call_end" and e.get("outcome") == "timeout", "outcome timeout")
    # The path-escape error quotes the caller's path; the log must not.
    pathmark = "PATHMARKER" + uuid.uuid4().hex[:8]
    rpc(token, sid, "tools/call", {"name": "read_file", "arguments": {"path": "../../" + pathmark}}, id_=8)
    wait_for(logfile, lambda e: e.get("event") == "tool_call_end" and e.get("tool") == "read_file"
             and e.get("outcome") == "error", "outcome error")

    # (f) a client that goes away mid-call.
    raw_abort(token, sid, {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {
        "name": "run_command", "arguments": {"project": "smoketest-log", "command": "sleep 20", "wait_seconds": 5}}})
    ab = req_end(logfile, "aborted call", aborted=True)
    need(ab.get("rpc_method") == "tools/call" and ab.get("tool") == "run_command", f"aborted req_end lost its identity: {ab}")
    need(ab.get("duration_ms", 0) >= 500 and "bytes_out" in ab, f"aborted req_end lacks duration/bytes_out: {ab}")
    need(ab.get("session") == pre, f"aborted req_end lost its session: {ab}")

    # SSE: req_start is logged while the stream is still open; req_end only when it closes.
    u = urlparse(URL)
    sse = socket.create_connection((u.hostname, u.port), timeout=10)
    sse.sendall((f"GET /mcp HTTP/1.1\r\nHost: {u.netloc}\r\naccept: text/event-stream\r\n"
                 f"authorization: Bearer {token}\r\nmcp-session-id: {sid}\r\n\r\n").encode())
    sse.recv(200)
    st = wait_for(logfile, lambda e: e.get("event") == "req_start" and e.get("method") == "GET" and e.get("path") == "/mcp"
                  and e.get("session") == pre, "req_start for the open SSE stream")
    need(not [e for e in events(logfile) if e.get("event") == "req_end" and e.get("req_id") == st["req_id"]],
         "SSE req_end was logged before the stream closed")
    sse.close()
    req_end(logfile, "SSE stream close", req_id=st["req_id"], aborted=True)

    # Session close via DELETE.
    status, _, _ = http("DELETE", MCP, token, sid)
    cl = wait_for(logfile, lambda e: e.get("event") == "session_closed" and e.get("session") == pre, "session_closed")
    need(cl.get("reason") and "age_s" in cl and cl.get("requests", 0) >= 1 and "active_sessions" in cl, f"session_closed fields: {cl}")

    # (g) redaction, over the whole file. Nothing secret, no bodies, no values, no full ids.
    time.sleep(0.5)
    text = raw_log(logfile)
    for what, needle in (("the real CONNECTOR_TOKEN", token), ("a wrong bearer token", wrong),
                         ("a query string", marker), ("a tool argument value", valmark), ("an error message quoting an argument", pathmark),
                         ("a full session id", sid), ("a Bearer header", "Bearer "),
                         ("an Authorization header", "authorization"), ("a request body", "jsonrpc"),
                         ("a malformed request body", "not json")):
        need(needle.lower() not in text.lower(), f"{what} leaked into the log")
    longest = max(len(l) for l in text.splitlines())
    need(longest < 8192, f"a log line is {longest} bytes: lines must be bounded")
    print(f"OK: {len(events(logfile))} events; reject reasons, tool outcomes, abort, SSE, redaction all verified")


def mode_rotate(token, logfile, keep, max_bytes):
    for _ in range(120):
        http("GET", URL + "/healthz")
        time.sleep(0.01)
    wait_for(logfile, lambda e: e.get("event") == "req_end", "any req_end")
    time.sleep(1)
    files = log_files(logfile)
    names = sorted(os.path.basename(f) for f in files)
    base = os.path.basename(logfile)
    want = sorted([base] + [f"{base}.{i}" for i in range(1, keep + 1)])
    need(names == want, f"expected exactly {want} after rotating, got {names}")
    for f in files:
        size = os.path.getsize(f)
        need(size <= max_bytes + 4096, f"{f} is {size} bytes, far over CONNECTOR_LOG_MAX_BYTES={max_bytes}")
    events(logfile)  # every line, in every file, still parses
    http("GET", URL + "/healthz")
    req_end(logfile, "request after rotation", path="/healthz", status=200)
    print("OK: rotated into", names)


def mode_unwritable(token, logfile):
    d = os.path.dirname(logfile)
    http("GET", URL + "/healthz")
    wait_for(logfile, lambda e: e.get("event") == "req_end", "a first, working log line")
    shutil.rmtree(d)
    open(d, "w").close()  # a file where the log directory should be: mkdir and open both fail
    slowest = 0.0
    try:
        for _ in range(15):
            t = time.monotonic()
            status, _, _ = http("GET", URL + "/healthz")
            need(status == 200, f"/healthz returned {status} with an unwritable log path")
            sid = initialize(token)
            need(bool(sid), "initialize failed with an unwritable log path")
            slowest = max(slowest, time.monotonic() - t)
            time.sleep(0.1)
    finally:
        os.remove(d)
        os.makedirs(d, exist_ok=True)
    need(slowest < 2.0, f"a request took {slowest:.1f}s with an unwritable log path")
    end = time.monotonic() + 15
    rec = None
    while time.monotonic() < end and not rec:
        http("GET", URL + "/healthz")
        rec = next((e for e in events(logfile) if e.get("event") == "log_recovered"), None)
        time.sleep(0.5)
    need(rec is not None, "the log never resumed after the path was repaired")
    need(rec.get("dropped", 0) >= 1, f"log_recovered doesn't report the dropped lines: {rec}")
    print("OK: requests unaffected while unwritable; log resumed and reported", rec["dropped"], "dropped lines")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    mode = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--mode=")), "main")
    if mode == "rotate":
        mode_rotate(args[0], args[1], int(args[2]), int(args[3]))
    elif mode == "unwritable":
        mode_unwritable(args[0], args[1])
    else:
        mode_main(args[0], args[1])


if __name__ == "__main__":
    main()
