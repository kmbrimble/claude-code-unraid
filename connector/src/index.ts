/**
 * claude-code-connector
 *
 * MCP server (Streamable HTTP) that lets Claude Cowork / claude.ai drive the
 * Claude Code CLI running inside this container: list projects & sessions,
 * start new sessions in a project folder, resume existing ones, run shell
 * commands, and poll long-running jobs.
 */
import express from "express";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const PORT = Number(process.env.PORT ?? 8765);
const HOST = process.env.HOST ?? "0.0.0.0";
const AUTH_TOKEN = process.env.CONNECTOR_TOKEN ?? ""; // empty = no auth (localhost only!)
const CLAUDE_BIN = process.env.CLAUDE_BIN ?? "claude";
const PROJECTS_ROOT = path.resolve(process.env.PROJECTS_ROOT ?? "/workspace");
const CLAUDE_HOME = process.env.CLAUDE_HOME ?? path.join(os.homedir(), ".claude");
const DEFAULT_TIMEOUT_MS = Number(process.env.DEFAULT_TIMEOUT_MS ?? 5 * 60_000);
const SKIP_PERMISSIONS = process.env.SKIP_PERMISSIONS === "1";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
type Job = {
  id: string;
  kind: "claude" | "shell";
  cwd: string;
  command: string;
  startedAt: string;
  finishedAt?: string;
  status: "running" | "done" | "error" | "timeout";
  exitCode?: number | null;
  stdout: string;
  stderr: string;
  sessionId?: string;
  kill?: () => void;
};
const jobs = new Map<string, Job>();

function safeProjectPath(p: string): string {
  const abs = path.resolve(PROJECTS_ROOT, p);
  if (abs !== PROJECTS_ROOT && !abs.startsWith(PROJECTS_ROOT + path.sep)) throw new Error(`Path escapes PROJECTS_ROOT: ${p}`);
  return abs;
}

/** Claude Code stores sessions under ~/.claude/projects/<cwd with / -> ->/<uuid>.jsonl */
function encodeProjectDir(cwd: string): string {
  return cwd.replace(/[\/.]/g, "-");
}

function runProcess(
  kind: Job["kind"],
  cmd: string,
  args: string[],
  cwd: string,
  opts: { timeoutMs?: number; stdin?: string; env?: NodeJS.ProcessEnv } = {},
): Job {
  const job: Job = {
    id: randomUUID(),
    kind,
    cwd,
    command: [cmd, ...args].join(" "),
    startedAt: new Date().toISOString(),
    status: "running",
    stdout: "",
    stderr: "",
  };
  jobs.set(job.id, job);

  const child = spawn(cmd, args, { cwd, env: { ...process.env, ...opts.env }, shell: false });
  job.kill = () => child.kill("SIGTERM");
  child.stdout.on("data", (d) => (job.stdout += d.toString()));
  child.stderr.on("data", (d) => (job.stderr += d.toString()));
  if (opts.stdin !== undefined) child.stdin.end(opts.stdin);
  else child.stdin.end();

  const timer = setTimeout(() => {
    if (job.status === "running") {
      job.status = "timeout";
      child.kill("SIGKILL");
    }
  }, opts.timeoutMs ?? DEFAULT_TIMEOUT_MS);

  child.on("close", (code) => {
    clearTimeout(timer);
    job.exitCode = code;
    job.finishedAt = new Date().toISOString();
    if (job.status === "running") job.status = code === 0 ? "done" : "error";
  });
  child.on("error", (e) => {
    clearTimeout(timer);
    job.status = "error";
    job.stderr += String(e);
    job.finishedAt = new Date().toISOString();
  });
  return job;
}

function waitForJob(job: Job, maxWaitMs: number): Promise<Job> {
  return new Promise((resolve) => {
    const start = Date.now();
    const tick = () => {
      if (job.status !== "running" || Date.now() - start > maxWaitMs) return resolve(job);
      setTimeout(tick, 250);
    };
    tick();
  });
}

function parseClaudeJson(stdout: string): Record<string, unknown> | null {
  // `--output-format json` prints a single JSON object; be tolerant of stray lines.
  const lines = stdout.trim().split("\n").reverse();
  for (const l of lines) {
    try {
      const o = JSON.parse(l);
      if (o && typeof o === "object") return o;
    } catch {}
  }
  return null;
}

function summariseJob(job: Job, truncate = 20_000) {
  const parsed = job.kind === "claude" ? parseClaudeJson(job.stdout) : null;
  return {
    job_id: job.id,
    status: job.status,
    exit_code: job.exitCode,
    cwd: job.cwd,
    started_at: job.startedAt,
    finished_at: job.finishedAt,
    session_id: (parsed?.session_id as string | undefined) ?? job.sessionId,
    result: parsed?.result ?? undefined,
    cost_usd: parsed?.total_cost_usd,
    num_turns: parsed?.num_turns,
    stdout: parsed ? undefined : job.stdout.slice(-truncate),
    stderr: job.stderr.slice(-truncate) || undefined,
  };
}

function claudeArgs(o: {
  prompt: string;
  resume?: string;
  sessionId?: string;
  model?: string;
  maxTurns?: number;
  allowedTools?: string[];
  systemPrompt?: string;
  permissionMode?: string;
}): string[] {
  // No --verbose: with --output-format json it turns the output into an array
  // of every message rather than the single result object we parse.
  const a = ["-p", "--output-format", "json"];
  if (o.resume) a.push("--resume", o.resume);
  if (o.sessionId) a.push("--session-id", o.sessionId);
  if (o.model) a.push("--model", o.model);
  if (o.maxTurns) a.push("--max-turns", String(o.maxTurns));
  if (o.allowedTools?.length) a.push("--allowedTools", o.allowedTools.join(","));
  if (o.systemPrompt) a.push("--append-system-prompt", o.systemPrompt);
  if (o.permissionMode) a.push("--permission-mode", o.permissionMode);
  else if (SKIP_PERMISSIONS) a.push("--dangerously-skip-permissions");
  a.push(o.prompt);
  return a;
}

const text = (v: unknown) => ({ content: [{ type: "text" as const, text: typeof v === "string" ? v : JSON.stringify(v, null, 2) }] });

// ---------------------------------------------------------------------------
// MCP server + tools
// ---------------------------------------------------------------------------
function buildServer(): McpServer {
  const server = new McpServer({ name: "claude-code-connector", version: "0.1.0" });

  server.registerTool(
    "list_projects",
    {
      title: "List project folders",
      description: `List directories under PROJECTS_ROOT (${PROJECTS_ROOT}) that can host Claude Code sessions.`,
      inputSchema: { depth: z.number().int().min(1).max(3).default(1).describe("How many levels deep to list") },
    },
    async ({ depth }) => {
      const out: string[] = [];
      async function walk(dir: string, d: number) {
        let ents;
        try { ents = await fs.readdir(dir, { withFileTypes: true }); } catch { return; }
        for (const e of ents) {
          if (!e.isDirectory() || e.name.startsWith(".") || e.name === "node_modules") continue;
          const full = path.join(dir, e.name);
          out.push(path.relative(PROJECTS_ROOT, full));
          if (d < depth) await walk(full, d + 1);
        }
      }
      await walk(PROJECTS_ROOT, 1);
      return text({ projects_root: PROJECTS_ROOT, projects: out });
    },
  );

  server.registerTool(
    "list_sessions",
    {
      title: "List Claude Code sessions",
      description: "List existing Claude Code sessions (from ~/.claude/projects). Optionally filter to one project folder. Returns session_id, project, last modified, first user prompt.",
      inputSchema: {
        project: z.string().optional().describe("Project path relative to PROJECTS_ROOT, or absolute. Omit for all."),
        limit: z.number().int().min(1).max(200).default(30),
      },
    },
    async ({ project, limit }) => {
      const root = path.join(CLAUDE_HOME, "projects");
      let dirs: string[];
      try { dirs = await fs.readdir(root); } catch { return text({ sessions: [], note: `${root} not found` }); }
      if (project) {
        const enc = encodeProjectDir(safeProjectPath(project));
        dirs = dirs.filter((d) => d === enc);
      }
      const sessions: any[] = [];
      for (const d of dirs) {
        const pdir = path.join(root, d);
        let files: string[] = [];
        try { files = (await fs.readdir(pdir)).filter((f) => f.endsWith(".jsonl")); } catch { continue; }
        for (const f of files) {
          const fp = path.join(pdir, f);
          const st = await fs.stat(fp);
          let firstPrompt = "";
          let cwd = "";
          try {
            const head = (await fs.readFile(fp, "utf8")).split("\n").slice(0, 40);
            for (const line of head) {
              try {
                const o = JSON.parse(line);
                if (!cwd && o.cwd) cwd = o.cwd;
                if (o.type === "user" && !firstPrompt) {
                  const c = o.message?.content;
                  firstPrompt = typeof c === "string" ? c : Array.isArray(c) ? c.map((x: any) => x.text ?? "").join(" ") : "";
                }
                if (cwd && firstPrompt) break;
              } catch {}
            }
          } catch {}
          sessions.push({
            session_id: f.replace(/\.jsonl$/, ""),
            project_dir_key: d,
            cwd,
            modified: st.mtime.toISOString(),
            size_bytes: st.size,
            first_prompt: firstPrompt.slice(0, 200),
          });
        }
      }
      sessions.sort((a, b) => (a.modified < b.modified ? 1 : -1));
      return text({ sessions: sessions.slice(0, limit) });
    },
  );

  server.registerTool(
    "get_session_transcript",
    {
      title: "Read a session transcript",
      description: "Return the most recent N messages (user/assistant text) from a Claude Code session's JSONL log.",
      inputSchema: {
        session_id: z.string(),
        project: z.string().optional().describe("Project path (speeds lookup). Omit to search all."),
        last_n: z.number().int().min(1).max(200).default(30),
      },
    },
    async ({ session_id, project, last_n }) => {
      const root = path.join(CLAUDE_HOME, "projects");
      const candidates = project ? [encodeProjectDir(safeProjectPath(project))] : await fs.readdir(root);
      for (const d of candidates) {
        const fp = path.join(root, d, `${session_id}.jsonl`);
        try {
          const lines = (await fs.readFile(fp, "utf8")).trim().split("\n");
          const msgs: any[] = [];
          for (const l of lines) {
            try {
              const o = JSON.parse(l);
              if (o.type !== "user" && o.type !== "assistant") continue;
              const c = o.message?.content;
              const parts = typeof c === "string" ? [c] : Array.isArray(c) ? c.map((x: any) =>
                x.type === "text" ? x.text : x.type === "tool_use" ? `[tool_use ${x.name}] ${JSON.stringify(x.input).slice(0, 300)}` : x.type === "tool_result" ? `[tool_result] ${String(typeof x.content === "string" ? x.content : JSON.stringify(x.content)).slice(0, 300)}` : "") : [];
              msgs.push({ role: o.type, ts: o.timestamp, text: parts.join("\n") });
            } catch {}
          }
          return text({ session_id, project_dir_key: d, messages: msgs.slice(-last_n) });
        } catch {}
      }
      return text({ error: `Session ${session_id} not found` });
    },
  );

  const claudeCommon = {
    project: z.string().describe("Project folder, relative to PROJECTS_ROOT or absolute."),
    prompt: z.string().describe("The instruction to send to Claude Code."),
    model: z.string().optional().describe("e.g. sonnet, opus, or a full model id"),
    max_turns: z.number().int().min(1).max(200).optional(),
    allowed_tools: z.array(z.string()).optional().describe('e.g. ["Read","Edit","Bash(git *)"]'),
    permission_mode: z.enum(["default", "acceptEdits", "plan", "bypassPermissions"]).optional(),
    append_system_prompt: z.string().optional(),
    wait_seconds: z.number().min(0).max(600).default(120).describe("How long to block waiting for completion before returning a job_id to poll."),
    timeout_seconds: z.number().min(10).max(3600).optional().describe("Hard kill after this many seconds."),
  };

  server.registerTool(
    "start_session",
    {
      title: "Start a new Claude Code session",
      description: "Create a new Claude Code session in a project folder and send it a prompt. Returns the session_id (use with continue_session) and the result. If it takes longer than wait_seconds, returns a job_id to poll with get_job.",
      inputSchema: claudeCommon,
    },
    async (a) => {
      const cwd = safeProjectPath(a.project);
      await fs.mkdir(cwd, { recursive: true });
      const sessionId = randomUUID();
      const job = runProcess("claude", CLAUDE_BIN, claudeArgs({
        prompt: a.prompt, sessionId, model: a.model, maxTurns: a.max_turns, allowedTools: a.allowed_tools,
        systemPrompt: a.append_system_prompt, permissionMode: a.permission_mode,
      }), cwd, { timeoutMs: a.timeout_seconds ? a.timeout_seconds * 1000 : undefined });
      job.sessionId = sessionId;
      await waitForJob(job, a.wait_seconds * 1000);
      return text(summariseJob(job));
    },
  );

  server.registerTool(
    "continue_session",
    {
      title: "Continue an existing Claude Code session",
      description: "Resume an existing session by session_id (see list_sessions) and send it a new prompt, preserving its full context.",
      inputSchema: { ...claudeCommon, session_id: z.string() },
    },
    async (a) => {
      const cwd = safeProjectPath(a.project);
      const job = runProcess("claude", CLAUDE_BIN, claudeArgs({
        prompt: a.prompt, resume: a.session_id, model: a.model, maxTurns: a.max_turns, allowedTools: a.allowed_tools,
        systemPrompt: a.append_system_prompt, permissionMode: a.permission_mode,
      }), cwd, { timeoutMs: a.timeout_seconds ? a.timeout_seconds * 1000 : undefined });
      job.sessionId = a.session_id;
      await waitForJob(job, a.wait_seconds * 1000);
      return text(summariseJob(job));
    },
  );

  server.registerTool(
    "run_command",
    {
      title: "Run a shell command in a project folder",
      description: "Run an arbitrary shell command (bash -lc) inside the container, in the given project folder. Use for git status, tests, builds, etc.",
      inputSchema: {
        project: z.string(),
        command: z.string(),
        wait_seconds: z.number().min(0).max(600).default(60),
        timeout_seconds: z.number().min(1).max(3600).default(600),
      },
    },
    async (a) => {
      const cwd = safeProjectPath(a.project);
      const job = runProcess("shell", "bash", ["-lc", a.command], cwd, { timeoutMs: a.timeout_seconds * 1000 });
      await waitForJob(job, a.wait_seconds * 1000);
      return text(summariseJob(job));
    },
  );

  server.registerTool(
    "get_job",
    {
      title: "Poll a running job",
      description: "Get status/output of a job started by start_session, continue_session or run_command.",
      inputSchema: { job_id: z.string(), wait_seconds: z.number().min(0).max(600).default(0) },
    },
    async ({ job_id, wait_seconds }) => {
      const job = jobs.get(job_id);
      if (!job) return text({ error: "unknown job_id" });
      await waitForJob(job, wait_seconds * 1000);
      return text(summariseJob(job));
    },
  );

  server.registerTool(
    "list_jobs",
    { title: "List jobs", description: "List all jobs known to this connector (running and finished).", inputSchema: {} },
    async () => text({ jobs: [...jobs.values()].map((j) => ({ job_id: j.id, kind: j.kind, status: j.status, cwd: j.cwd, session_id: j.sessionId, started_at: j.startedAt, command: j.command.slice(0, 200) })) }),
  );

  server.registerTool(
    "cancel_job",
    { title: "Cancel a job", description: "Send SIGTERM to a running job.", inputSchema: { job_id: z.string() } },
    async ({ job_id }) => {
      const job = jobs.get(job_id);
      if (!job) return text({ error: "unknown job_id" });
      job.kill?.();
      return text({ job_id, status: job.status });
    },
  );

  server.registerTool(
    "read_file",
    {
      title: "Read a file from a project",
      description: "Read a text file inside PROJECTS_ROOT.",
      inputSchema: { path: z.string().describe("Relative to PROJECTS_ROOT or absolute within it"), max_bytes: z.number().int().default(100_000) },
    },
    async ({ path: p, max_bytes }) => {
      const fp = safeProjectPath(p);
      const buf = await fs.readFile(fp);
      return text(buf.subarray(0, max_bytes).toString("utf8"));
    },
  );

  return server;
}

// ---------------------------------------------------------------------------
// HTTP transport (Streamable HTTP, stateful sessions)
// ---------------------------------------------------------------------------
const app = express();
app.use(express.json({ limit: "4mb" }));

app.get("/healthz", (_req, res) => res.json({ ok: true, projects_root: PROJECTS_ROOT }));

app.use("/mcp", (req, res, next) => {
  if (!AUTH_TOKEN) return next();
  const h = req.header("authorization") ?? "";
  if (h === `Bearer ${AUTH_TOKEN}`) return next();
  res.status(401).json({ error: "unauthorized" });
});

const transports = new Map<string, StreamableHTTPServerTransport>();

app.post("/mcp", async (req, res) => {
  const sid = req.header("mcp-session-id");
  let transport = sid ? transports.get(sid) : undefined;

  if (!transport) {
    if (sid) {
      // Session id was supplied but isn't known (e.g. the connector restarted
      // and its in-memory session map was wiped). Per the MCP Streamable HTTP
      // spec, 404 tells a compliant client to re-initialise automatically.
      res.status(404).json({ jsonrpc: "2.0", error: { code: -32001, message: "Session not found" }, id: null });
      return;
    }
    if (!isInitializeRequest(req.body)) {
      res.status(400).json({ jsonrpc: "2.0", error: { code: -32000, message: "Bad request: no valid session" }, id: null });
      return;
    }
    transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
      onsessioninitialized: (id) => { transports.set(id, transport!); },
    });
    transport.onclose = () => { if (transport?.sessionId) transports.delete(transport.sessionId); };
    await buildServer().connect(transport);
  }
  await transport.handleRequest(req, res, req.body);
});

const handleSessionReq = async (req: express.Request, res: express.Response) => {
  const sid = req.header("mcp-session-id");
  if (!sid) { res.status(400).send("Invalid or missing session ID"); return; }
  const t = transports.get(sid);
  if (!t) { res.status(404).send("Session not found"); return; }
  await t.handleRequest(req, res);
};
app.get("/mcp", handleSessionReq);
app.delete("/mcp", handleSessionReq);

app.listen(PORT, HOST, () => {
  console.log(`claude-code-connector listening on http://${HOST}:${PORT}/mcp  (projects: ${PROJECTS_ROOT}, auth: ${AUTH_TOKEN ? "bearer" : "none"})`);
});
