#!/usr/bin/env python3
"""Drive the connector's real MCP endpoint to prove read_file's image support
behaviourally (issue #18), the same way test/connector_timeout_check.py does
for the wait/timeout contract: initialize, then call read_file for real and
assert on what comes back, not on the source.

Usage: connector_image_check.py <token> <project_subdir>

Expects, under <PROJECTS_ROOT>/<project_subdir>/ (populated by test/smoke.sh
via `docker cp` before this runs):
  sample.png   - a real PNG
  sample.jpg   - a real JPEG
  sample.txt   - a plain text file
  oversized.png - a file with a valid PNG magic header but larger than the
                  connector's image size cap
"""
import base64
import json
import re
import sys
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
    if not raw:
        return new_sid, None
    if raw.startswith("{"):
        candidates = [raw]
    else:
        candidates = re.findall(r"^data:\s*(\{.*\})\s*$", raw, re.MULTILINE)
    objs = [json.loads(c) for c in candidates]
    if id_ is None:
        return new_sid, None
    for o in objs:
        if o.get("id") == id_:
            return new_sid, o
    return new_sid, (objs[-1] if objs else None)


def connect(token):
    sid, _ = call(token, None, "initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "smoke", "version": "1"},
    }, id_=1)
    if not sid:
        sys.exit("FAIL: no mcp-session-id from initialize")
    call(token, sid, "notifications/initialized")
    return sid


def read_file(token, sid, path, next_id):
    _, resp = call(token, sid, "tools/call", {"name": "read_file", "arguments": {"path": path}}, id_=next_id)
    result = resp.get("result")
    if result is None:
        sys.exit(f"FAIL: read_file({path!r}) returned no result: {resp}")
    return result


def main():
    token, subdir = sys.argv[1], sys.argv[2]
    sid = connect(token)
    next_id = [2]

    def call_next(path):
        next_id[0] += 1
        return read_file(token, sid, f"{subdir}/{path}", next_id[0])

    # PNG: single image block, correct mimeType, byte-identical base64.
    with open(f"/projects/{subdir}/sample.png", "rb") as f:
        expected_png = f.read()
    r = call_next("sample.png")
    block = r["content"][0]
    assert block["type"] == "image", f"FAIL: PNG did not return an image block: {r}"
    assert block["mimeType"] == "image/png", f"FAIL: wrong mimeType for PNG: {block}"
    assert base64.b64decode(block["data"]) == expected_png, "FAIL: PNG base64 does not round-trip byte-identical"
    print("PASS: PNG returns byte-identical image block")

    # JPEG: same shape.
    with open(f"/projects/{subdir}/sample.jpg", "rb") as f:
        expected_jpg = f.read()
    r = call_next("sample.jpg")
    block = r["content"][0]
    assert block["type"] == "image", f"FAIL: JPEG did not return an image block: {r}"
    assert block["mimeType"] == "image/jpeg", f"FAIL: wrong mimeType for JPEG: {block}"
    assert base64.b64decode(block["data"]) == expected_jpg, "FAIL: JPEG base64 does not round-trip byte-identical"
    print("PASS: JPEG returns byte-identical image block")

    # Text files must behave exactly as before: a text block, unchanged content.
    with open(f"/projects/{subdir}/sample.txt", "rb") as f:
        expected_txt = f.read().decode("utf8")
    r = call_next("sample.txt")
    block = r["content"][0]
    assert block["type"] == "text", f"FAIL: text file did not return a text block: {r}"
    assert block["text"] == expected_txt, "FAIL: text file content changed"
    print("PASS: text file still returns unchanged text content")

    # Over the image size cap: a clear error, not a truncated/corrupt image.
    r = call_next("oversized.png")
    is_error = r.get("isError") is True
    msg = r["content"][0].get("text", "") if r.get("content") else ""
    assert is_error, f"FAIL: oversized image was not rejected: {r}"
    assert msg, "FAIL: oversized image rejection carries no message"
    print(f"PASS: oversized image rejected with a clear error: {msg!r}")

    # Path outside PROJECTS_ROOT must still be refused.
    next_id[0] += 1
    r = read_file(token, sid, "/etc/passwd", next_id[0])
    assert r.get("isError") is True, f"FAIL: path outside PROJECTS_ROOT was not refused: {r}"
    print("PASS: path outside PROJECTS_ROOT still refused")


if __name__ == "__main__":
    main()
