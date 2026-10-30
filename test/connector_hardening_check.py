#!/usr/bin/env python3
"""Behavioural check of the connector's Phase 1 hardening (0.36).

Spawns its OWN connector (so it needs no particular container settings and runs
equally in a smoke container or on a dev box) against a throwaway PROJECTS_ROOT
and CLAUDE_HOME, with a stub `claude`, then asserts on what comes back over real
HTTP / MCP. Never prints a token value.

  connector_hardening_check.py [path/to/dist/index.js]

Default entry: /opt/claude-code-connector/dist/index.js. Exits 0 if every check
passes, 1 otherwise; every check is attempted so one run shows the whole picture.
"""
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
PORT = 8791
BASE = f"http://127.0.0.1:{PORT}"
TOKEN = "hardening-" + os.urandom(8).hex()
COLLECTOR_TOKEN = "collector-" + os.urandom(8).hex()
KEEP = {"GH_TOKEN": "kept-gh", "CLAUDE_CODE_OAUTH_TOKEN": "kept-oauth",
        "CUSTOM_API_KEY": "kept-custom", "OPENROUTER_API_KEY": "kept-openrouter"}
UUID_RE = re.compile(r"^[0-9a-f-]{36}$")

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


def spawn(extra_env=None):
    env = {k: v for k, v in os.environ.items() if k not in ("CONNECTOR_TOKEN", "USAGE_COLLECTOR_TOKEN", "NODE_ENV")}
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


WORK = tempfile.mkdtemp(prefix="hardening-")
ROOT = os.path.join(WORK, "projects")
HOME = os.path.join(WORK, "claude-home")
OUTSIDE = os.path.join(WORK, "outside")
ARGV_LOG = os.path.join(WORK, "argv.log")
ENV_LOG = os.path.join(WORK, "env.log")
STUB = os.path.join(WORK, "fake-claude")
for d in (os.path.join(ROOT, "p"), os.path.join(HOME, "projects"), OUTSIDE, os.path.join(WORK, "log")):
    os.makedirs(d)
with open(STUB, "w") as f:
    f.write(f'#!/bin/bash\nprintf "%s\\0" "$@" >> {ARGV_LOG}\nprintf "\\n" >> {ARGV_LOG}\nenv > {ENV_LOG}\n'
            'echo \'{"session_id":"x","result":"ok","total_cost_usd":0,"num_turns":1}\'\n')
os.chmod(STUB, 0o755)
with open(os.path.join(OUTSIDE, "secret.txt"), "w") as f:
    f.write("outside-secret")
os.symlink(OUTSIDE, os.path.join(ROOT, "p", "escape"))
os.symlink(OUTSIDE, os.path.join(ROOT, "link-project"))

proc = spawn({"JOB_RETENTION_MS": "3000", "MAX_FINISHED_JOBS": "6"})
try:
    sid = start_session()

    # 1. Child env: the two connector secrets are gone, the legitimate ones stay.
    out = run(sid, "printenv CONNECTOR_TOKEN USAGE_COLLECTOR_TOKEN; echo rc=$?")
    check("child env has no CONNECTOR_TOKEN / USAGE_COLLECTOR_TOKEN",
          TOKEN not in json.dumps(out) and COLLECTOR_TOKEN not in json.dumps(out) and "rc=1" in out.get("stdout", ""),
          "a secret reached the child" if TOKEN in json.dumps(out) or COLLECTOR_TOKEN in json.dumps(out) else out)
    env_dump = run(sid, "env").get("stdout", "")
    check("child env has no NODE_ENV (the connector's own mode must not leak into builds)", "NODE_ENV" not in env_dump, "NODE_ENV leaked")
    check("child env still has GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, CUSTOM_API_KEY, OPENROUTER_API_KEY",
          all(f"{k}={v}" in env_dump for k, v in KEEP.items()), [k for k, v in KEEP.items() if f"{k}={v}" not in env_dump])
    tool_json(sid, "start_session", {"project": "p", "prompt": "hi", "wait_seconds": 10})
    claude_env = open(ENV_LOG).read() if os.path.exists(ENV_LOG) else ""
    check("a Claude job's env has neither secret but keeps CLAUDE_CODE_OAUTH_TOKEN",
          "CLAUDE_CODE_OAUTH_TOKEN=kept-oauth" in claude_env and TOKEN not in claude_env and COLLECTOR_TOKEN not in claude_env,
          "stub env not captured" if not claude_env else "")

    # 2. Pre-auth surface.
    big = "x" * (5 * 1024 * 1024)
    st, hd, body = http("POST", "/mcp", data='{"bad json', timeout=30)
    check("unauthenticated malformed JSON -> 401, no stack or paths",
          st == 401 and not re.search(r"\bat \S+ \(|node_modules|/opt/|\.js:\d+|SyntaxError", body), (st, body[:200]))
    # The server answers 401 without reading the body, so the client may see the socket
    # close mid-upload: that is a rejection too. What must not happen is a 413 (the body
    # was parsed first) or a 200.
    try:
        st, hd, body = http("POST", "/mcp", data=big)
    except OSError:
        st, hd = 401, {}
    check("unauthenticated oversized body is rejected before parsing (401, not 413)", st == 401, st)
    hd = http("GET", "/nope")[1]
    check("x-powered-by header absent", "x-powered-by" not in {k.lower() for k in hd.keys()}, dict(hd))
    st, hd, body = http("POST", "/mcp", data='{"bad json', token=TOKEN)
    check("authenticated malformed JSON -> generic 400, no stack or paths",
          st == 400 and not re.search(r"\bat \S+ \(|node_modules|/opt/|\.js:\d+|SyntaxError|stack", body), (st, body[:200]))
    st, _, body = http("POST", "/mcp", data=big, token=TOKEN)
    check("authenticated oversized body -> generic 413", st == 413 and "node_modules" not in body, (st, body[:120]))
    st, _, _ = http("POST", "/mcp", data={"jsonrpc": "2.0", "id": 1, "method": "ping"}, token=TOKEN[:-1] + "X")
    check("same-length wrong token -> 401", st == 401, st)
    st, _, _ = http("POST", "/mcp", data={}, token=TOKEN + "X")
    check("longer wrong token -> 401", st == 401, st)
    st, _, _ = http("POST", "/mcp", data={}, token="")
    check("no token -> 401", st == 401, st)
    check("correct token still authenticates", sid is not None)

    # 4. healthz.
    st, _, body = http("GET", "/healthz")
    check("/healthz returns exactly {ok:true}", st == 200 and json.loads(body) == {"ok": True}, body)

    # 5a. Output cap.
    res = run(sid, "head -c 3000000 /dev/zero | tr '\\0' a; echo end >&2", timeout_seconds=60)
    check("a 3 MB stdout is capped and the truncation is reported",
          res.get("exit_code") == 0 and res.get("stdout_truncated_chars", 0) >= 1_900_000, {k: res.get(k) for k in ("exit_code", "stdout_truncated_chars")})

    # 5b. Eviction: count cap (6) and retention (3 s).
    for i in range(10):
        run(sid, f"echo n{i}")
    jobs = tool_json(sid, "list_jobs", {})[0].get("jobs", [])
    check("finished jobs are capped at MAX_FINISHED_JOBS", len([j for j in jobs if j["status"] != "running"]) <= 6, len(jobs))
    running = tool_json(sid, "run_command", {"project": "p", "command": "sleep 8", "wait_seconds": 0})[0]
    time.sleep(3.5)
    run(sid, "true")
    jobs = tool_json(sid, "list_jobs", {})[0].get("jobs", [])
    ids = {j["job_id"] for j in jobs}
    check("a running job is never evicted", running.get("job_id") in ids)
    check("finished jobs older than JOB_RETENTION_MS are evicted", len(ids) <= 3, len(ids))

    # 5c. read_file: stops at max_bytes; a sparse 3 GB file cannot be slurped.
    big_file = os.path.join(ROOT, "p", "huge.bin")
    with open(big_file, "wb") as f:
        f.truncate(3 * 1024**3)
        f.seek(0)
        f.write(b"HEADER-ok")
    content, err = tool(sid, "read_file", {"path": "p/huge.bin", "max_bytes": 9})
    check("read_file reads only max_bytes of a 3 GB file", not err and content and content[0].get("text") == "HEADER-ok", content[:1])
    os.remove(big_file)

    # 5d. session_id validation.
    pdir = os.path.join(HOME, "projects", "p-dir")
    os.makedirs(pdir)
    good = "11111111-2222-4333-8444-555555555555"
    line = json.dumps({"type": "user", "message": {"content": "hi"}})
    for p_ in (os.path.join(pdir, good + ".jsonl"), os.path.join(HOME, "outside-transcript.jsonl")):
        with open(p_, "w") as f:
            f.write(line + "\n")
    r = tool_json(sid, "get_session_transcript", {"session_id": good})[0]
    check("get_session_transcript still serves a valid UUID", bool(r.get("messages")), r)
    r, err = tool_json(sid, "get_session_transcript", {"session_id": "../../outside-transcript"})
    check("get_session_transcript refuses a path-traversing session_id", err or "messages" not in r, r)

    # 5e. symlinks.
    for tname, args in (("read_file", {"path": "p/escape/secret.txt"}), ("read_file", {"path": "link-project/secret.txt"}),
                        ("run_command", {"project": "p/escape", "command": "cat secret.txt", "wait_seconds": 5}),
                        ("run_command", {"project": "link-project", "command": "cat secret.txt", "wait_seconds": 5})):
        content, err = tool(sid, tname, args)
        check(f"{tname} via a symlink out of PROJECTS_ROOT is refused ({args.get('path') or args.get('project')})",
              "outside-secret" not in json.dumps(content), content[:1])
    check("a normal in-root project still works", run(sid, "echo fine").get("stdout", "").strip() == "fine")
    os.makedirs(os.path.join(ROOT, "new-proj-parent"), exist_ok=True)
    r = tool_json(sid, "start_session", {"project": "brand/new", "prompt": "hello", "wait_seconds": 10})[0]
    check("start_session still creates a not-yet-existing project dir", r.get("status") == "done" and os.path.isdir(os.path.join(ROOT, "brand", "new")), r)

    # 5f. `--` before the prompt.
    open(ARGV_LOG, "w").close()
    tool_json(sid, "start_session", {"project": "p", "prompt": "--dangerously-skip-permissions -rf", "wait_seconds": 10})
    argv = open(ARGV_LOG, "rb").read().split(b"\n")[0].split(b"\0")[:-1]
    check("the prompt follows a `--` so a leading dash cannot become a flag",
          argv[-2:] == [b"--", b"--dangerously-skip-permissions -rf"], argv[-3:])
finally:
    stop(proc)

# The connector is spawned with NODE_ENV=development on purpose (Express's non-production
# mode is the one that prints stacks), so the error handler is tested on its own merits. The entrypoint's
# NODE_ENV=production and the 0600 log file are asserted by test/smoke.sh.
shutil.rmtree(WORK, ignore_errors=True)
print(f"\n{len(failures)} failed" if failures else "\nall hardening checks passed")
sys.exit(1 if failures else 0)
