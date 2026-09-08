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
const DEFAULT_TIMEOUT_MS = Number(process.env.DEFAULT_TIMEOUT_MS ?? 30 * 60_000);
const SKIP_PERMISSIONS = process.env.SKIP_PERMISSIONS === "1";
// Ceiling on any blocking wait. The MCP *client* abandons a single tool call
// after a fixed, client-dependent period (seen at ~60s and at 180s) while the
// job underneath keeps running; waiting longer than that just loses the reply.
const MAX_WAIT_SECONDS = Number(process.env.MAX_WAIT_SECONDS ?? 55);
// Idle timeout: 0 = disabled, so DEFAULT_TIMEOUT_MS keeps its 0.26 semantics.
const IDLE_TIMEOUT_MS = Number(process.env.IDLE_TIMEOUT_MS ?? 0);
// How long a killed job gets to exit on SIGTERM before it is SIGKILLed.
const KILL_GRACE_MS = Number(process.env.KILL_GRACE_MS ?? 10_000);
// Never read more than this from the tail of a session transcript: the live
// ones reach tens of megabytes.
const TAIL_BYTES = 256_000;

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
  timeoutMs: number;
  idleTimeoutMs: number;
  /** Epoch ms of the last observed sign of life (output, or transcript growth). */
  lastActivity: number;
  /** Set when a kill has been started; status only settles once the child closes. */
  terminating?: { kind: "wall_clock" | "idle" | "cancel"; at: string };
  /** True once the grace period expired and SIGKILL was sent. */
  escalated?: boolean;
  /** The signal that actually ended the process, per the `close` event. */
  signal?: string | null;
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
  opts: { timeoutMs?: number; idleTimeoutMs?: number; stdin?: string; env?: NodeJS.ProcessEnv } = {},
): Job {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const idleTimeoutMs = opts.idleTimeoutMs ?? IDLE_TIMEOUT_MS;
  const job: Job = {
    id: randomUUID(),
    kind,
    cwd,
    command: [cmd, ...args].join(" "),
    startedAt: new Date().toISOString(),
    status: "running",
    stdout: "",
    stderr: "",
    timeoutMs,
    idleTimeoutMs,
    lastActivity: Date.now(),
  };
  jobs.set(job.id, job);

  // detached: the child leads its own process group, so a kill reaches its
  // grandchildren too. Without it, killing `bash -lc` orphans the real work,
  // which keeps running AND holds the stdout pipe open so `close` never fires.
  const child = spawn(cmd, args, { cwd, env: { ...process.env, ...opts.env }, shell: false, detached: true });
  const alive = () => child.exitCode === null && child.signalCode === null;
  const signalGroup = (sig: NodeJS.Signals) => {
    try { if (child.pid) process.kill(-child.pid, sig); } catch { try { child.kill(sig); } catch {} }
  };
  /** Graceful stop: SIGTERM, then SIGKILL only if it is still alive after the grace period. */
  const terminate = (reason: NonNullable<Job["terminating"]>["kind"]) => {
    if (job.terminating || !alive()) return;
    job.terminating = { kind: reason, at: new Date().toISOString() };
    signalGroup("SIGTERM");
    setTimeout(() => {
      if (alive()) { job.escalated = true; signalGroup("SIGKILL"); }
    }, KILL_GRACE_MS).unref();
  };
  job.kill = () => terminate("cancel");

  const onOutput = (stream: "stdout" | "stderr") => (d: Buffer) => {
    job[stream] += d.toString();
    job.lastActivity = Date.now();
  };
  child.stdout.on("data", onOutput("stdout"));
  child.stderr.on("data", onOutput("stderr"));
  if (opts.stdin !== undefined) child.stdin.end(opts.stdin);
  else child.stdin.end();

  const wallTimer = setTimeout(() => terminate("wall_clock"), timeoutMs);
  // A `claude -p` job prints nothing until it finishes, so its only usable
  // liveness signal is its session transcript being appended to.
  const idleTimer = idleTimeoutMs > 0 ? setInterval(async () => {
    if (job.terminating || Date.now() - job.lastActivity < idleTimeoutMs) return;
    // Only a Claude job has a transcript. A shell job is judged on its output
    // alone, as run_command advertises — otherwise the newest-file fallback
    // would let an unrelated session in the same project keep it alive.
    const fp = job.kind === "claude" ? await sessionLogPath(job) : null;
    const st = fp ? await fs.stat(fp).catch(() => null) : null;
    if (st && st.mtimeMs > job.lastActivity) { job.lastActivity = st.mtimeMs; return; }
    if (Date.now() - job.lastActivity >= idleTimeoutMs) terminate("idle");
  }, 1000) : undefined;

  const settle = () => {
    clearTimeout(wallTimer);
    if (idleTimer) clearInterval(idleTimer);
    job.finishedAt = new Date().toISOString();
  };
  child.on("close", (code, signal) => {
    settle();
    job.exitCode = code;
    job.signal = signal;
    if (job.status === "running") {
      const killed = job.terminating?.kind;
      job.status = killed === "wall_clock" || killed === "idle" ? "timeout" : code === 0 ? "done" : "error";
    }
  });
  child.on("error", (e) => {
    settle();
    job.status = "error";
    job.stderr += String(e);
  });
  return job;
}

/**
 * The session transcript this job is writing, or null.
 *
 * Prefers the file named by the job's session id; falls back to the newest
 * `.jsonl` in the project's session directory, because a resumed session can
 * be recorded under a forked id. The fallback ignores files untouched since
 * the job started, so an unrelated older session is never mistaken for this
 * job's progress — or for it still being alive.
 * ponytail: two concurrent jobs in one project can still cross-feed liveness
 * through the fallback; per-job id tracking if that ever matters.
 */
async function sessionLogPath(job: Job): Promise<string | null> {
  const dir = path.join(CLAUDE_HOME, "projects", encodeProjectDir(job.cwd));
  const startedMs = Date.parse(job.startedAt);
  // The named file existing is not enough: on a resume it always exists, and if
  // the session forks to a new id it stops being written to. Only trust it while
  // it is actually being appended to.
  const preferred = job.sessionId ? path.join(dir, `${job.sessionId}.jsonl`) : null;
  const preferredStat = preferred ? await fs.stat(preferred).catch(() => null) : null;
  if (preferredStat && preferredStat.mtimeMs >= startedMs) return preferred;
  let best: { p: string; m: number } | null = null;
  for (const f of await fs.readdir(dir).catch(() => [] as string[])) {
    if (!f.endsWith(".jsonl")) continue;
    const p = path.join(dir, f);
    const st = await fs.stat(p).catch(() => null);
    if (!st || st.mtimeMs < startedMs) continue;
    if (!best || st.mtimeMs > best.m) best = { p, m: st.mtimeMs };
  }
  // Nothing has been written since this job started: fall back to the named
  // file anyway, so a just-resumed session still shows its history.
  return best?.p ?? (preferredStat ? preferred : null);
}

/** Shape one transcript JSONL line into a {role, ts, text} event, or null if it isn't one. */
function transcriptEvent(line: string): { role: string; ts?: string; text: string } | null {
  try {
    const o = JSON.parse(line);
    if (o.type !== "user" && o.type !== "assistant") return null;
    const c = o.message?.content;
    const parts = typeof c === "string" ? [c] : Array.isArray(c) ? c.map((x: any) =>
      x.type === "text" ? x.text : x.type === "tool_use" ? `[tool_use ${x.name}] ${JSON.stringify(x.input).slice(0, 300)}` : x.type === "tool_result" ? `[tool_result] ${String(typeof x.content === "string" ? x.content : JSON.stringify(x.content)).slice(0, 300)}` : "") : [];
    return { role: o.type, ts: o.timestamp, text: parts.join("\n") };
  } catch { return null; }
}

/** Last N transcript events, read from the tail of the file only — these reach tens of MB. */
async function tailTranscript(fp: string, lastN: number) {
  const fh = await fs.open(fp, "r");
  try {
    const { size } = await fh.stat();
    const want = Math.min(size, TAIL_BYTES);
    const buf = Buffer.alloc(want);
    await fh.read(buf, 0, want, size - want);
    let s = buf.toString("utf8");
    if (size > want) s = s.slice(s.indexOf("\n") + 1); // drop the leading partial line
    const events = s.split("\n").map(transcriptEvent).filter(Boolean);
    return { events: events.slice(-lastN), transcript_path: fp, transcript_bytes: size, tail_bytes_read: want };
  } finally {
    await fh.close();
  }
}

/** Blocking waits are capped: past MAX_WAIT_SECONDS the client has already given up on the call. */
function clampWait(requested: number) {
  const applied = Math.min(requested, MAX_WAIT_SECONDS);
  if (applied >= requested) return { applied, note: undefined };
  return {
    applied,
    note: {
      requested_seconds: requested,
      applied_seconds: applied,
      max_wait_seconds: MAX_WAIT_SECONDS,
      reason: `Clamped to MAX_WAIT_SECONDS (${MAX_WAIT_SECONDS}s): the MCP client abandons a blocking tool call before then. The job keeps running — poll get_job with the job_id above.`,
    },
  };
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

function jobDeadlines(job: Job) {
  const startedMs = Date.parse(job.startedAt);
  const endMs = job.finishedAt ? Date.parse(job.finishedAt) : Date.now();
  return {
    elapsed_seconds: Math.round((endMs - startedMs) / 100) / 10,
    timeout_seconds: job.timeoutMs / 1000,
    deadline_at: new Date(startedMs + job.timeoutMs).toISOString(),
    idle_timeout_seconds: job.idleTimeoutMs > 0 ? job.idleTimeoutMs / 1000 : undefined,
  };
}

function timeoutInfo(job: Job) {
  if (job.status !== "timeout") return undefined;
  const kind = job.terminating?.kind === "idle" ? "idle" : "wall_clock";
  const seconds = kind === "idle" ? job.idleTimeoutMs / 1000 : job.timeoutMs / 1000;
  const ending = job.escalated
    ? `it ignored SIGTERM and was SIGKILLed after the ${KILL_GRACE_MS / 1000}s grace period, so no cleanup ran`
    : `it exited on SIGTERM within the ${KILL_GRACE_MS / 1000}s grace period`;
  return {
    kind,
    seconds,
    signal: job.signal ?? (job.escalated ? "SIGKILL" : "SIGTERM"),
    escalated: !!job.escalated,
    message: kind === "idle"
      ? `Killed after ${seconds}s with no output and no session-transcript activity: ${ending}. Pass a larger idle_timeout_seconds (or 0 to disable the idle timer) for work that is legitimately quiet for long stretches.`
      : `Killed after exceeding its ${seconds}s wall-clock timeout: SIGTERM first, then SIGKILL if still alive — ${ending}. Pass a larger timeout_seconds next time to allow more time.`,
  };
}

function summariseJob(job: Job, truncate = 20_000) {
  const parsed = job.kind === "claude" ? parseClaudeJson(job.stdout) : null;
  return {
    ...jobDeadlines(job),
    terminating: job.terminating && !job.finishedAt ? job.terminating : undefined,
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
    timeout: timeoutInfo(job),
  };
}

/** summariseJob plus, on request, the tail of the session transcript this job is writing. */
async function summariseJobWithProgress(job: Job, progressEvents: number) {
  const base = summariseJob(job);
  if (!progressEvents || job.kind !== "claude") return base;
  const fp = await sessionLogPath(job);
  if (!fp) return { ...base, progress: { events: [], note: "No session transcript found yet for this job." } };
  try {
    return { ...base, progress: await tailTranscript(fp, progressEvents) };
  } catch (e) {
    return { ...base, progress: { events: [], note: `Could not read ${fp}: ${e}` } };
  }
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
          const msgs = (await fs.readFile(fp, "utf8")).trim().split("\n").map(transcriptEvent).filter(Boolean);
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
    wait_seconds: z.number().min(0).max(600).default(MAX_WAIT_SECONDS).describe(
      `How long to block waiting for completion before returning a job_id to poll. Clamped at ` +
      `runtime to MAX_WAIT_SECONDS (currently ${MAX_WAIT_SECONDS}s) because the MCP client gives up ` +
      `on a blocking call before then; the clamp is reported in the result and the job keeps running.`,
    ),
    idle_timeout_seconds: z.number().min(0).max(3600).optional().describe(
      `Kill the job after this many seconds with no output and no session-transcript activity — a ` +
      `stalled job, as opposed to a merely long one. 0 disables it. If omitted, IDLE_TIMEOUT_MS ` +
      `applies (currently ${IDLE_TIMEOUT_MS / 1000}s; 0 means no idle timer).`,
    ),
    progress_events: z.number().int().min(0).max(50).default(0).describe(
      "If >0, include the last N events from this session's live transcript in the result.",
    ),
    timeout_seconds: z.number().min(10).max(3600).optional().describe(
      `Kill (SIGTERM, then SIGKILL after ${KILL_GRACE_MS / 1000}s if it hasn't exited) after this ` +
      `many seconds of wall clock. If omitted, the ` +
      `connector's effective default applies (currently ${DEFAULT_TIMEOUT_MS / 1000}s, set by the ` +
      `DEFAULT_TIMEOUT_MS env var). A killed job's result explains the kill; pass a larger value here ` +
      `for anything that might run long, such as a build.`,
    ),
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
      }), cwd, {
        timeoutMs: a.timeout_seconds ? a.timeout_seconds * 1000 : undefined,
        idleTimeoutMs: a.idle_timeout_seconds !== undefined ? a.idle_timeout_seconds * 1000 : undefined,
      });
      job.sessionId = sessionId;
      const wait = clampWait(a.wait_seconds);
      await waitForJob(job, wait.applied * 1000);
      return text({ ...await summariseJobWithProgress(job, a.progress_events), wait_clamped: wait.note });
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
      }), cwd, {
        timeoutMs: a.timeout_seconds ? a.timeout_seconds * 1000 : undefined,
        idleTimeoutMs: a.idle_timeout_seconds !== undefined ? a.idle_timeout_seconds * 1000 : undefined,
      });
      job.sessionId = a.session_id;
      const wait = clampWait(a.wait_seconds);
      await waitForJob(job, wait.applied * 1000);
      return text({ ...await summariseJobWithProgress(job, a.progress_events), wait_clamped: wait.note });
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
        wait_seconds: z.number().min(0).max(600).default(MAX_WAIT_SECONDS).describe(
          `Clamped at runtime to MAX_WAIT_SECONDS (currently ${MAX_WAIT_SECONDS}s); the job keeps running, poll get_job.`,
        ),
        idle_timeout_seconds: z.number().min(0).max(3600).optional().describe(
          "Kill the command after this many seconds with no output. 0 disables it; omitted uses IDLE_TIMEOUT_MS.",
        ),
        timeout_seconds: z.number().min(1).max(3600).default(600).describe(
          `Kill (SIGTERM, then SIGKILL after ${KILL_GRACE_MS / 1000}s if it hasn't exited) after this many seconds. Defaults to 600s if omitted.`,
        ),
      },
    },
    async (a) => {
      const cwd = safeProjectPath(a.project);
      const job = runProcess("shell", "bash", ["-lc", a.command], cwd, {
        timeoutMs: a.timeout_seconds * 1000,
        idleTimeoutMs: a.idle_timeout_seconds !== undefined ? a.idle_timeout_seconds * 1000 : undefined,
      });
      const wait = clampWait(a.wait_seconds);
      await waitForJob(job, wait.applied * 1000);
      return text({ ...summariseJob(job), wait_clamped: wait.note });
    },
  );

  server.registerTool(
    "get_job",
    {
      title: "Poll a running job",
      description: `Get status/output of a job started by start_session, continue_session or run_command. Pass progress_events to see what a running Claude session is doing right now: a job with --output-format json prints nothing until it finishes, so its live transcript is the only view into it.`,
      inputSchema: {
        job_id: z.string(),
        wait_seconds: z.number().min(0).max(600).default(0).describe(
          `Clamped at runtime to MAX_WAIT_SECONDS (currently ${MAX_WAIT_SECONDS}s).`,
        ),
        progress_events: z.number().int().min(0).max(50).default(0).describe(
          "If >0, include the last N events from this job's live session transcript (tail-read only).",
        ),
      },
    },
    async ({ job_id, wait_seconds, progress_events }) => {
      const job = jobs.get(job_id);
      if (!job) return text({ error: "unknown job_id" });
      const wait = clampWait(wait_seconds);
      await waitForJob(job, wait.applied * 1000);
      return text({ ...await summariseJobWithProgress(job, progress_events), wait_clamped: wait.note });
    },
  );

  server.registerTool(
    "list_jobs",
    {
      title: "List jobs",
      description: "List all jobs known to this connector (running and finished), with each job's own deadline, plus the connector-wide wait/timeout settings. This is the recovery path after a blocking call was cut short by the client.",
      inputSchema: {},
    },
    async () => text({
      settings: {
        max_wait_seconds: MAX_WAIT_SECONDS,
        default_timeout_seconds: DEFAULT_TIMEOUT_MS / 1000,
        idle_timeout_seconds: IDLE_TIMEOUT_MS / 1000,
        kill_grace_seconds: KILL_GRACE_MS / 1000,
      },
      jobs: [...jobs.values()].map((j) => ({
        job_id: j.id, kind: j.kind, status: j.status, cwd: j.cwd, session_id: j.sessionId,
        started_at: j.startedAt, finished_at: j.finishedAt, ...jobDeadlines(j),
        command: j.command.slice(0, 200),
      })),
    }),
  );

  server.registerTool(
    "cancel_job",
    {
      title: "Cancel a job",
      description: `Gracefully stop a running job with SIGTERM, escalating to a hard SIGKILL only if it is still alive after ${KILL_GRACE_MS / 1000}s, so it cannot hang forever on an unresponsive child.`,
      inputSchema: { job_id: z.string() },
    },
    async ({ job_id }) => {
      const job = jobs.get(job_id);
      if (!job) return text({ error: "unknown job_id" });
      job.kill?.();
      return text({ job_id, status: job.status, terminating: job.terminating, grace_seconds: KILL_GRACE_MS / 1000 });
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
