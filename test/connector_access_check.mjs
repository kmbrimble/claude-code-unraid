// Behavioural check of the connector's AUTH_MODE (bearer | access | both).
//
// Spawns its own connectors against a local JWKS server and signs Cf-Access-Jwt-Assertion
// tokens with jose (resolved from the connector's node_modules). Never prints a token.
//
//   node connector_access_check.mjs [path/to/dist/index.js]
//
// Default entry: /opt/claude-code-connector/dist/index.js. Exit 0 if all pass, 1 otherwise.
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const ENTRY = path.resolve(process.argv[2] ?? "/opt/claude-code-connector/dist/index.js");
const { SignJWT, generateKeyPair, exportJWK } = createRequire(ENTRY.replace(/dist\/index\.js$/, "package.json"))("jose");

const TEAM = "team.example.cloudflareaccess.com";
const ISS = `https://${TEAM}`;
const AUD = "a".repeat(64);
const TOKEN = "bearer-" + Math.random().toString(36).slice(2);
const WORK = mkdtempSync(path.join(tmpdir(), "access-check-"));
mkdirSync(path.join(WORK, "p"));

let failures = 0;
const check = (name, ok, detail = "") => { console.log((ok ? "PASS" : "FAIL") + ": " + name + (ok ? "" : `  [${detail}]`)); if (!ok) failures++; };

// --- JWKS server: serves whatever key set `keys` currently holds -------------------------
const mk = async (kid) => {
  const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });
  return { kid, privateKey, jwk: { ...(await exportJWK(publicKey)), kid, alg: "RS256", use: "sig" } };
};
const k1 = await mk("k1"), k2 = await mk("k2"), evil = await mk("k1"); // evil reuses k1's kid
let published = [k1];
let jwksHits = 0;
const jwks = createServer((_q, r) => { jwksHits++; r.setHeader("content-type", "application/json"); r.end(JSON.stringify({ keys: published.map((k) => k.jwk) })); });
await new Promise((ok) => jwks.listen(0, "127.0.0.1", ok));
const JWKS_URL = `http://127.0.0.1:${jwks.address().port}/certs`;

const sign = (key, over = {}, claims = {}) => {
  let j = new SignJWT({ email: "kieren@example.com", ...claims }).setProtectedHeader({ alg: "RS256", kid: key.kid });
  j = j.setIssuer(over.iss ?? ISS).setAudience(over.aud ?? AUD).setSubject("user-1");
  j = j.setIssuedAt(over.iat ?? Math.floor(Date.now() / 1000) - 5);
  if (over.nbf) j = j.setNotBefore(over.nbf);
  return j.setExpirationTime(over.exp ?? Math.floor(Date.now() / 1000) + 300).sign(key.privateKey);
};

// --- connector harness --------------------------------------------------------------------
let nextPort = 8811;
async function start(env) {
  const port = nextPort++;
  const log = path.join(WORK, `log-${port}.jsonl`);
  const e = { ...process.env, PORT: String(port), HOST: "127.0.0.1", PROJECTS_ROOT: WORK, CLAUDE_HOME: WORK,
    CONNECTOR_LOG_FILE: log, ACCESS_JWKS_URL: JWKS_URL, ACCESS_JWKS_COOLDOWN_MS: "1500", ...env };
  for (const k of ["CONNECTOR_TOKEN", "AUTH_MODE", "ACCESS_TEAM_DOMAIN", "ACCESS_AUD", "ACCESS_ALLOWED_EMAILS"]) if (!(k in env)) delete e[k];
  const p = spawn("node", [ENTRY], { env: e, stdio: "ignore" });
  for (let i = 0; i < 100; i++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/healthz`)).ok) return { p, port, log }; } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  p.kill(); throw new Error("connector did not start: " + JSON.stringify(Object.keys(env)));
}
const INIT = { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } } };
const post = async (c, headers) => {
  const r = await fetch(`http://127.0.0.1:${c.port}/mcp`, { method: "POST", body: JSON.stringify(INIT),
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream", ...headers } });
  await r.text();
  return r.status;
};
const stop = (c) => c.p.kill("SIGKILL");
const ACC = { AUTH_MODE: "access", ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD };
const H = "cf-access-jwt-assertion";

try {
  // ---- access mode
  const a = await start(ACC);
  check("access: valid JWT accepted", (await post(a, { [H]: await sign(k1) })) === 200);
  check("access: missing header -> 401", (await post(a, {})) === 401);
  check("access: bearer header ignored (no token configured) -> 401", (await post(a, { authorization: "Bearer " + TOKEN })) === 401);
  check("access: wrong aud -> 401", (await post(a, { [H]: await sign(k1, { aud: "b".repeat(64) }) })) === 401);
  check("access: wrong iss -> 401", (await post(a, { [H]: await sign(k1, { iss: "https://evil.cloudflareaccess.com" }) })) === 401);
  const now = Math.floor(Date.now() / 1000);
  check("access: expired -> 401", (await post(a, { [H]: await sign(k1, { iat: now - 900, exp: now - 600 }) })) === 401);
  check("access: not-yet-valid (nbf) -> 401", (await post(a, { [H]: await sign(k1, { nbf: now + 3600 }) })) === 401);
  check("access: bad signature (right kid, other key) -> 401", (await post(a, { [H]: await sign(evil) })) === 401);
  check("access: garbage header -> 401", (await post(a, { [H]: "not.a.jwt" })) === 401);
  check("access: /healthz stays open", (await fetch(`http://127.0.0.1:${a.port}/healthz`)).ok);

  // rotation: unknown kid triggers a refetch; the refetch is rate-limited
  await new Promise((r) => setTimeout(r, 1600)); // let the refetch cooldown lapse
  published = [k1, k2];
  check("access: key rotated in (unknown kid -> refetch) accepted", (await post(a, { [H]: await sign(k2) })) === 200);
  const before = jwksHits;
  const ghost = await mk("ghost");
  for (let i = 0; i < 5; i++) await post(a, { [H]: await sign(ghost) });
  check("access: unknown-kid flood does not hammer the JWKS endpoint", jwksHits - before <= 1, `hits=${jwksHits - before}`);

  // log carries the email, never the token
  await new Promise((r) => setTimeout(r, 300));
  const jwt = await sign(k1);
  await post(a, { [H]: jwt });
  await new Promise((r) => setTimeout(r, 300));
  const logTxt = readFileSync(a.log, "utf8");
  check("access: req_end logs the authenticated email", logTxt.split("\n").some((l) => l.includes('"req_end"') && l.includes('"auth_email":"kieren@example.com"')));
  check("access: log never contains the JWT", !logTxt.includes(jwt.split(".")[2]));
  stop(a);

  // ---- email allowlist
  const al = await start({ ...ACC, ACCESS_ALLOWED_EMAILS: "Kieren@Example.com, other@example.com" });
  check("allowlist: listed email (case-insensitive) accepted", (await post(al, { [H]: await sign(k1) })) === 200);
  check("allowlist: unlisted email -> 401", (await post(al, { [H]: await sign(k1, {}, { email: "mallory@example.com" }) })) === 401);
  check("allowlist: no email claim -> 401", (await post(al, { [H]: await sign(k1, {}, { email: undefined }) })) === 401);
  stop(al);

  // ---- both
  const b = await start({ ...ACC, AUTH_MODE: "both", CONNECTOR_TOKEN: TOKEN });
  check("both: bearer accepted", (await post(b, { authorization: "Bearer " + TOKEN })) === 200);
  check("both: JWT accepted", (await post(b, { [H]: await sign(k1) })) === 200);
  check("both: neither -> 401", (await post(b, {})) === 401);
  check("both: wrong bearer + no JWT -> 401", (await post(b, { authorization: "Bearer nope" })) === 401);
  stop(b);

  // ---- bearer (default and explicit): unchanged, JWT ignored
  for (const env of [{ CONNECTOR_TOKEN: TOKEN }, { CONNECTOR_TOKEN: TOKEN, AUTH_MODE: "bearer" }]) {
    const d = await start(env);
    const tag = env.AUTH_MODE ?? "default";
    check(`bearer(${tag}): token accepted`, (await post(d, { authorization: "Bearer " + TOKEN })) === 200);
    check(`bearer(${tag}): no credentials -> 401`, (await post(d, {})) === 401);
    check(`bearer(${tag}): valid JWT alone does NOT authenticate`, (await post(d, { [H]: await sign(k1) })) === 401);
    stop(d);
  }

  // ---- config errors fail closed at startup
  const bad = async (env, name) => {
    const clean = { ...process.env }; for (const k of ["CONNECTOR_TOKEN", "AUTH_MODE", "ACCESS_TEAM_DOMAIN", "ACCESS_AUD"]) delete clean[k];
    const p = spawn("node", [ENTRY], { env: { ...clean, PORT: String(nextPort++), HOST: "127.0.0.1", PROJECTS_ROOT: WORK, CLAUDE_HOME: WORK,
      CONNECTOR_LOG_FILE: path.join(WORK, "bad.jsonl"), ...env }, stdio: "ignore" });
    const code = await new Promise((r) => { const t = setTimeout(() => { p.kill("SIGKILL"); r("running"); }, 4000); p.on("exit", (c) => { clearTimeout(t); r(c); }); });
    check(name, code !== "running" && code !== 0, String(code));
  };
  await bad({ AUTH_MODE: "access" }, "config: access without team domain/aud refuses to start");
  await bad({ AUTH_MODE: "both", ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD }, "config: both without CONNECTOR_TOKEN refuses to start");
  await bad({ AUTH_MODE: "acess", ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD }, "config: unknown AUTH_MODE refuses to start");
} finally {
  jwks.close();
}
process.exit(failures ? 1 : 0);
