#!/usr/bin/env python3
"""Behavioural check of the connector's resource limits (0.38).

Spawns its OWN connectors against a throwaway PROJECTS_ROOT and CLAUDE_HOME with a
stub `claude`, and asserts over real HTTP / MCP: strict numeric env parsing, the
running-job cap, the session cap and idle expiry (which must spare a session with a
running job or an open stream), and the bounded read_file / transcript reads.

  connector_limits_check.py [path/to/dist/index.js]

Default entry: /opt/claude-code-connector/dist/index.js. Exits 0 if every check
passes, 1 otherwise. Never prints a token value.
"""
from http.client import HTTPConnection
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ENTRY = sys.argv[1] if len(sys.argv) > 1 else "/opt/claude-code-connector/dist/index.js"
PORT = 8793
BASE = f"http://127.0.0.1:{PORT}"
TOKEN = "limits-" + os.urandom(8).hex()
COLLECTOR_TOKEN = "collector-" + os.urandom(8).hex()
KEEP = {}

failures = []


def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL") + ": " + name + ("" if ok else f"  [{detail}]"))
    if not ok:
        failures.append(name)


def http(method, path, headers=None, data=None, token=None, timeout=30):
    h = {"content-type": "application/json", "accept": "application/json, text/event-stream"}
    if token:
        h["authorization"] = f"Bearer {token}"
    h.update(headers or {})
    if isinstance(data, (dict, list)):
        data = json.dumps(data).encode()
    elif isinstance(data, str):
        data = data.encode()
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        return r.status, r.headers, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode()


def rpc(sid, method, params=None, id_=1):
    body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if id_ is not None:
        body["id"] = id_
    st, hd, raw = http("POST", "/mcp", {"mcp-session-id": sid} if sid else None, body, TOKEN)
    if id_ is None:
        return hd, None
    raw = raw.strip()
    cands = [raw] if raw.startswith("{") else re.findall(r"^data:\s*(\{.*\})\s*$", raw, re.M)
    for c in map(json.loads, cands):
        if c.get("id") == id_:
            return hd, c
    return hd, None


def start_session():
    hd, _ = rpc(None, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "hardening", "version": "1"}})
    sid = hd["mcp-session-id"]
    rpc(sid, "notifications/initialized", id_=None)
    return sid


def tool(sid, name, args):
    """Returns (content blocks, is_error)."""
    _, resp = rpc(sid, "tools/call", {"name": name, "arguments": args}, id_=int(time.time() * 1000) % 10**9)
    if resp is None:
        return [], True
    if "error" in resp:
        return [{"type": "text", "text": json.dumps(resp["error"])}], True
    r = resp["result"]
    return r.get("content", []), bool(r.get("isError"))


def tool_json(sid, name, args):
    content, err = tool(sid, name, args)
    try:
        return json.loads(content[0]["text"]), err
    except (IndexError, KeyError, ValueError):
        return {"_raw": content}, err


def run(sid, cmd, **kw):
    return tool_json(sid, "run_command", {"project": "p", "command": cmd, "wait_seconds": 20, **kw})[0]


def clean_env():
    """The parent's environment minus anything that would change auth: a live container sets AUTH_MODE/ACCESS_*."""
    drop = ("CONNECTOR_TOKEN", "USAGE_COLLECTOR_TOKEN", "NODE_ENV", "AUTH_MODE")
    return {k: v for k, v in os.environ.items() if k not in drop and not k.startswith("ACCESS_")}


def spawn(extra_env=None):
    env = clean_env()
    env["NODE_ENV"] = "development"  # non-production on purpose: it is the mode that prints stacks
    env.update({
        "PORT": str(PORT), "HOST": "127.0.0.1", "CONNECTOR_TOKEN": TOKEN,
        "USAGE_COLLECTOR_TOKEN": COLLECTOR_TOKEN, "PROJECTS_ROOT": ROOT, "CLAUDE_HOME": HOME,
        "CLAUDE_BIN": STUB, "CONNECTOR_LOG_FILE": os.path.join(WORK, "log", "c.jsonl"),
        "MAX_WAIT_SECONDS": "20", **KEEP, **(extra_env or {}),
    })
    p = subprocess.Popen(["node", ENTRY], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            if http("GET", "/healthz")[0] == 200:
                return p
        except OSError:
            time.sleep(0.1)
    p.kill()
    sys.exit("FAIL: connector did not start")


def stop(p):
    p.terminate()
    p.wait(10)


WORK = tempfile.mkdtemp(prefix="limits-")
ROOT = os.path.join(WORK, "projects")
HOME = os.path.join(WORK, "claude-home")
STUB = os.path.join(WORK, "fake-claude")
LOG = os.path.join(WORK, "log", "c.jsonl")
for d in (os.path.join(ROOT, "p"), os.path.join(HOME, "projects", "p-dir"), os.path.join(WORK, "log")):
    os.makedirs(d)
with open(STUB, "w") as f:
    f.write('#!/bin/bash\necho \'{"session_id":"x","result":"ok"}\'\n')
os.chmod(STUB, 0o755)


def log_events():
    try:
        return [json.loads(l) for l in open(LOG) if l.strip()]
    except OSError:
        return []


def alive(sid):
    _, resp = rpc(sid, "ping")
    return bool(resp) and "result" in resp


# 1. Strict numeric env parsing: a bad value fails startup and names the variable.
for var, val in (("PORT", "abc"), ("DEFAULT_TIMEOUT_MS", "-5"), ("OUTPUT_CAP_BYTES", "1e3"),
                 ("MAX_WAIT_SECONDS", "0"), ("MAX_RUNNING_JOBS", "0"), ("SESSION_IDLE_MS", "99999999999999"),
                 ("KILL_GRACE_MS", "12ms"), ("MAX_READ_BYTES", "1.5")):
    env = {**clean_env(), "CONNECTOR_TOKEN": TOKEN, "HOST": "127.0.0.1", "PROJECTS_ROOT": ROOT,
           "CLAUDE_HOME": HOME, "CONNECTOR_LOG_FILE": LOG, "PORT": str(PORT), var: val}
    r = subprocess.run(["node", ENTRY], env=env, capture_output=True, text=True, timeout=20)
    check(f"{var}={val} fails startup naming the variable", r.returncode != 0 and var in r.stderr, (r.returncode, r.stderr[:150]))

# 2. Running-job cap, read_file clamp, bounded transcript reads.
proc = spawn({"MAX_RUNNING_JOBS": "2", "MAX_READ_BYTES": "1000", "IDLE_TIMEOUT_MS": "0"})
try:
    sid = start_session()
    j1 = tool_json(sid, "run_command", {"project": "p", "command": "sleep 6", "wait_seconds": 0})[0]
    j2 = tool_json(sid, "run_command", {"project": "p", "command": "sleep 6", "wait_seconds": 0})[0]
    content, err = tool(sid, "run_command", {"project": "p", "command": "echo hi", "wait_seconds": 1})
    check("a job over MAX_RUNNING_JOBS is refused with a capacity error",
          err and "Capacity exceeded" in json.dumps(content) and j1.get("job_id") and j2.get("job_id"), content[:1])
    content, err = tool(sid, "start_session", {"project": "p", "prompt": "hi", "wait_seconds": 1})
    check("start_session is refused too (shared cap)", err and "Capacity exceeded" in json.dumps(content), content[:1])
    time.sleep(0.5)  # the log is written off the request path
    check("job_cap_hit is logged", any(e["event"] == "job_cap_hit" for e in log_events()))
    tool_json(sid, "cancel_job", {"job_id": j1["job_id"]})
    time.sleep(1)
    check("a slot frees once a job finishes", run(sid, "echo ok").get("stdout", "").strip() == "ok")

    with open(os.path.join(ROOT, "p", "f.txt"), "w") as f:
        f.write("a" * 5000)
    content, err = tool(sid, "read_file", {"path": "p/f.txt", "max_bytes": 999999})
    check("read_file rejects max_bytes above MAX_READ_BYTES", err, content[:1])
    content, err = tool(sid, "read_file", {"path": "p/f.txt", "max_bytes": 1000})
    check("read_file honours max_bytes up to the cap", not err and len(content[0]["text"]) == 1000, content[:1])
    content, err = tool(sid, "read_file", {"path": "p/f.txt"})
    check("read_file default never exceeds the cap", not err and len(content[0]["text"]) <= 1000, content[:1])

    good = "11111111-2222-4333-8444-555555555555"
    fp = os.path.join(HOME, "projects", "p-dir", good + ".jsonl")
    first = json.dumps({"type": "user", "cwd": "/projects/p", "message": {"content": "FIRST-PROMPT"}}) + "\n"
    filler = (json.dumps({"type": "assistant", "message": {"content": "x" * 900}}) + "\n") * 25_000  # ~22 MB
    last = json.dumps({"type": "assistant", "message": {"content": "LAST-MESSAGE"}}) + "\n"
    with open(fp, "w") as f:
        f.write(first + filler + last)
    r = tool_json(sid, "get_session_transcript", {"session_id": good, "last_n": 5})[0]
    msgs = r.get("messages", [])
    check("get_session_transcript reads only a bounded tail of a ~22 MB file",
          len(msgs) == 5 and "LAST-MESSAGE" in msgs[-1]["text"] and r.get("tail_bytes_read", 10**9) <= 256_000, {k: r.get(k) for k in ("tail_bytes_read", "transcript_bytes")})
    t0 = time.time()
    r = tool_json(sid, "list_sessions", {})[0]
    s = (r.get("sessions") or [{}])[0]
    check("list_sessions still returns first prompt and cwd from a bounded head read",
          s.get("first_prompt") == "FIRST-PROMPT" and s.get("cwd") == "/projects/p", s)
finally:
    stop(proc)

# 3. Session cap, idle expiry, and what must be spared.
proc = spawn({"MAX_SESSIONS": "3", "SESSION_IDLE_MS": "3000"})
conn = None
try:
    s1 = start_session()
    tool_json(s1, "run_command", {"project": "p", "command": "sleep 9", "wait_seconds": 0})  # s1: busy, and soon the oldest
    s2 = start_session()
    s3 = start_session()
    conn = HTTPConnection("127.0.0.1", PORT, timeout=30)  # s3 keeps an SSE stream open
    conn.request("GET", "/mcp", headers={"authorization": f"Bearer {TOKEN}", "mcp-session-id": s3, "accept": "text/event-stream"})
    conn.getresponse()
    s4 = start_session()  # cap hit: evicts the longest-idle non-busy session, which is s2 (s1 is busy)
    check("over MAX_SESSIONS the longest-idle non-busy session is evicted", not alive(s2))
    check("session_cap_hit is logged", any(e["event"] == "session_cap_hit" for e in log_events()))
    time.sleep(5)  # SESSION_IDLE_MS is 3 s; none of s1, s3, s4 has been touched since
    check("an idle session with no job or stream is expired", http("POST", "/mcp", {"mcp-session-id": s4}, {"jsonrpc": "2.0", "id": 1, "method": "ping"}, TOKEN)[0] == 404)
    check("a session with a running job survives idle expiry", alive(s1))
    check("a session with an open stream survives idle expiry", alive(s3))
    check("idle_expired is logged as a close reason", any(e.get("reason") == "idle_expired" for e in log_events()))
finally:
    if conn:
        conn.close()
    stop(proc)

shutil.rmtree(WORK, ignore_errors=True)
print(f"\n{len(failures)} failed" if failures else "\nall limits checks passed")
sys.exit(1 if failures else 0)
