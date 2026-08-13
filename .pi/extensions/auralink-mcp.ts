import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

/**
 * Project-local Pi extension that bridges Pi tools to the Auralink EQ MCP server.
 *
 * Pi intentionally has no built-in MCP client. This extension speaks the small
 * JSON-RPC-over-stdio subset we need, discovers Auralink's MCP tools, and
 * registers them as first-class Pi tools with their original names
 * (get_agent_eq_guide, upsert_headphone_profile, audition_eq_preset, ...).
 */

type JsonObject = Record<string, unknown>;

type McpTool = {
  name: string;
  title?: string;
  description?: string;
  inputSchema?: JsonObject;
  annotations?: {
    readOnlyHint?: boolean;
    destructiveHint?: boolean;
    idempotentHint?: boolean;
    openWorldHint?: boolean;
  };
};

type PendingRequest = {
  method: string;
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: NodeJS.Timeout;
  abort?: () => void;
};

const MCP_PROTOCOL_VERSION = "2024-11-05";
const REQUEST_TIMEOUT_MS = 60_000;
const START_TIMEOUT_MS = 15_000;
const MAX_TEXT_CHARS = 50_000;
const MAX_LOG_LINES = 80;

const EMPTY_OBJECT_SCHEMA = {
  type: "object",
  properties: {},
  additionalProperties: false,
};

const STATUS_SCHEMA = EMPTY_OBJECT_SCHEMA;

const LIST_SCHEMA = {
  type: "object",
  properties: {
    refresh: {
      type: "boolean",
      default: false,
      description: "Refresh the cached MCP tool/resource/prompt list.",
    },
  },
  additionalProperties: false,
};

const CALL_TOOL_SCHEMA = {
  type: "object",
  properties: {
    toolName: {
      type: "string",
      minLength: 1,
      description: "Auralink MCP tool name, e.g. get_agent_eq_guide or upsert_headphone_profile.",
    },
    arguments: {
      type: "object",
      default: {},
      additionalProperties: true,
      description: "Arguments to pass through to the MCP tool.",
    },
  },
  required: ["toolName"],
  additionalProperties: false,
};

const READ_RESOURCE_SCHEMA = {
  type: "object",
  properties: {
    uri: {
      type: "string",
      minLength: 1,
      description: "MCP resource URI, e.g. eq://agent-guide or eq://safety-rules.",
    },
  },
  required: ["uri"],
  additionalProperties: false,
};

const GET_PROMPT_SCHEMA = {
  type: "object",
  properties: {
    name: {
      type: "string",
      minLength: 1,
      description: "MCP prompt name, e.g. create_headphone_tuning.",
    },
    arguments: {
      type: "object",
      default: {},
      additionalProperties: true,
      description: "Prompt arguments.",
    },
  },
  required: ["name"],
  additionalProperties: false,
};

function expandHome(path: string): string {
  if (path === "~") return process.env.HOME ?? path;
  if (path.startsWith("~/")) return join(process.env.HOME ?? "", path.slice(2));
  return path;
}

function findRepoRoot(startCwd: string): string {
  let current = resolve(startCwd);
  for (let i = 0; i < 8; i += 1) {
    if (existsSync(join(current, "mcp-server", "dist", "index.js"))) return current;
    const parent = dirname(current);
    if (parent === current) break;
    current = parent;
  }

  const explicitRepoRoot = process.env.AURALINK_REPO_ROOT;
  return explicitRepoRoot ? resolve(expandHome(explicitRepoRoot)) : resolve(startCwd);
}

function resolveServerConfig(cwd: string) {
  const explicitServerPath = process.env.AURALINK_MCP_SERVER_PATH;
  const serverPath = explicitServerPath
    ? resolve(expandHome(explicitServerPath))
    : join(findRepoRoot(cwd), "mcp-server", "dist", "index.js");
  const serverCwd = dirname(dirname(serverPath));

  return {
    serverPath,
    serverCwd,
    dataDir: process.env.AURALINK_DATA_DIR
      ? resolve(expandHome(process.env.AURALINK_DATA_DIR))
      : join(serverCwd, "data"),
    controlUrl: process.env.AURALINK_CONTROL_URL ?? "http://127.0.0.1:8765",
    presetsDir: process.env.AURALINK_PRESETS_DIR
      ? resolve(expandHome(process.env.AURALINK_PRESETS_DIR))
      : undefined,
    // Forwarded so the server and the app agree on which collection is in play.
    // Unset means both fall back to the same ~/auralink-collection default.
    collectionDir: process.env.AURALINK_COLLECTION_DIR
      ? resolve(expandHome(process.env.AURALINK_COLLECTION_DIR))
      : undefined,
  };
}

function labelize(name: string): string {
  return name
    .split(/[_-]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function truncateText(text: string): string {
  if (text.length <= MAX_TEXT_CHARS) return text;
  return `${text.slice(0, MAX_TEXT_CHARS)}\n\n[truncated to ${MAX_TEXT_CHARS} characters from ${text.length}]`;
}

function toText(value: unknown): string {
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

function normalizeToolSchema(schema: unknown): JsonObject {
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) return EMPTY_OBJECT_SCHEMA;
  const objectSchema = schema as JsonObject;
  if (objectSchema.type === "object") return objectSchema;
  return {
    type: "object",
    properties: {},
    additionalProperties: true,
  };
}

function piContentFromMcpResult(result: unknown) {
  const record = result && typeof result === "object" ? (result as JsonObject) : undefined;
  const rawContent = Array.isArray(record?.content) ? record.content : undefined;

  if (!rawContent?.length) {
    return [{ type: "text" as const, text: truncateText(toText(result)) }];
  }

  return rawContent.map((item) => {
    if (item && typeof item === "object") {
      const block = item as JsonObject;
      if (block.type === "text" && typeof block.text === "string") {
        return { type: "text" as const, text: truncateText(block.text) };
      }
    }
    return { type: "text" as const, text: truncateText(toText(item)) };
  });
}

function mcpErrorText(result: unknown): string {
  const content = piContentFromMcpResult(result)
    .map((part) => part.text)
    .join("\n");
  return content || "Auralink MCP returned an error.";
}

class AuralinkMcpClient {
  private child?: ChildProcessWithoutNullStreams;
  private startPromise?: Promise<void>;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private stdoutBuffer = "";
  private stderrLines: string[] = [];
  private toolCache?: McpTool[];
  private resourceCache?: unknown;
  private promptCache?: unknown;

  constructor(private readonly config: ReturnType<typeof resolveServerConfig>) {}

  get status() {
    return {
      serverPath: this.config.serverPath,
      serverCwd: this.config.serverCwd,
      controlUrl: this.config.controlUrl,
      dataDir: this.config.dataDir,
      presetsDir: this.config.presetsDir ?? "<mcp default: ~/Library/Application Support/Auralink/presets>",
      running: Boolean(this.child && !this.child.killed),
      cachedTools: this.toolCache?.map((tool) => tool.name) ?? [],
      recentServerLogs: this.stderrLines.slice(-12),
    };
  }

  async ensureStarted(signal?: AbortSignal): Promise<void> {
    if (this.child && !this.child.killed) {
      if (this.startPromise) await this.startPromise;
      return;
    }
    if (!this.startPromise) {
      this.startPromise = this.start(signal).finally(() => {
        this.startPromise = undefined;
      });
    }
    await this.startPromise;
  }

  async listTools(signal?: AbortSignal, refresh = false): Promise<McpTool[]> {
    if (!refresh && this.toolCache) return this.toolCache;
    await this.ensureStarted(signal);
    const result = (await this.request("tools/list", {}, signal)) as { tools?: McpTool[] };
    this.toolCache = Array.isArray(result.tools) ? result.tools : [];
    return this.toolCache;
  }

  async callTool(name: string, args: unknown, signal?: AbortSignal): Promise<unknown> {
    await this.ensureStarted(signal);
    return this.request("tools/call", { name, arguments: args ?? {} }, signal);
  }

  async listResources(signal?: AbortSignal, refresh = false): Promise<unknown> {
    if (!refresh && this.resourceCache) return this.resourceCache;
    await this.ensureStarted(signal);
    const [resources, templates] = await Promise.all([
      this.request("resources/list", {}, signal).catch((error) => ({ error: String(error) })),
      this.request("resources/templates/list", {}, signal).catch((error) => ({ error: String(error) })),
    ]);
    this.resourceCache = { resources, templates };
    return this.resourceCache;
  }

  async readResource(uri: string, signal?: AbortSignal): Promise<unknown> {
    await this.ensureStarted(signal);
    return this.request("resources/read", { uri }, signal);
  }

  async listPrompts(signal?: AbortSignal, refresh = false): Promise<unknown> {
    if (!refresh && this.promptCache) return this.promptCache;
    await this.ensureStarted(signal);
    this.promptCache = await this.request("prompts/list", {}, signal);
    return this.promptCache;
  }

  async getPrompt(name: string, args: unknown, signal?: AbortSignal): Promise<unknown> {
    await this.ensureStarted(signal);
    return this.request("prompts/get", { name, arguments: args ?? {} }, signal);
  }

  stop(): void {
    const child = this.child;
    if (!child) return;
    this.child = undefined;
    this.startPromise = undefined;
    this.rejectAll(new Error("Auralink MCP client stopped."));
    child.kill("SIGTERM");
    setTimeout(() => {
      if (!child.killed) child.kill("SIGKILL");
    }, 1_500).unref();
  }

  private async start(signal?: AbortSignal): Promise<void> {
    if (!existsSync(this.config.serverPath)) {
      throw new Error(
        `Auralink MCP server not found at ${this.config.serverPath}. Run: cd mcp-server && npm ci && npm run build`
      );
    }

    this.stdoutBuffer = "";
    this.child = spawn(process.execPath, [this.config.serverPath], {
      cwd: this.config.serverCwd,
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        AURALINK_CONTROL_URL: this.config.controlUrl,
        AURALINK_DATA_DIR: this.config.dataDir,
        ...(this.config.presetsDir ? { AURALINK_PRESETS_DIR: this.config.presetsDir } : {}),
        ...(this.config.collectionDir
          ? { AURALINK_COLLECTION_DIR: this.config.collectionDir }
          : {}),
      },
    });

    this.child.stdout.setEncoding("utf8");
    this.child.stderr.setEncoding("utf8");
    this.child.stdout.on("data", (chunk) => this.handleStdout(chunk));
    this.child.stderr.on("data", (chunk) => this.captureLog(String(chunk)));
    this.child.on("error", (error) => this.rejectAll(error));
    this.child.on("exit", (code, signalName) => {
      this.child = undefined;
      this.toolCache = undefined;
      this.resourceCache = undefined;
      this.promptCache = undefined;
      this.rejectAll(new Error(`Auralink MCP exited (code ${code ?? "?"}, signal ${signalName ?? "?"}).`));
    });

    try {
      await this.request(
        "initialize",
        {
          protocolVersion: MCP_PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: { name: "pi-auralink-mcp", version: "0.1.0-alpha.0" },
        },
        signal,
        START_TIMEOUT_MS
      );
      this.notify("notifications/initialized", {});
    } catch (caught) {
      const child = this.child;
      this.child = undefined;
      child?.kill("SIGTERM");
      throw caught;
    }
  }

  private request(
    method: string,
    params: unknown,
    signal?: AbortSignal,
    timeoutMs = REQUEST_TIMEOUT_MS
  ): Promise<unknown> {
    const child = this.child;
    if (!child || child.killed) {
      return Promise.reject(new Error("Auralink MCP server is not running."));
    }

    if (signal?.aborted) {
      return Promise.reject(new Error("Auralink MCP request aborted."));
    }

    const id = this.nextId++;
    const payload = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";

    return new Promise((resolve, reject) => {
      let abort: (() => void) | undefined;
      let timer: NodeJS.Timeout;
      const cleanup = () => {
        clearTimeout(timer);
        if (signal && abort) signal.removeEventListener("abort", abort);
        this.pending.delete(id);
      };

      timer = setTimeout(() => {
        cleanup();
        reject(new Error(`Auralink MCP request timed out: ${method}`));
      }, timeoutMs);
      timer.unref();

      abort = signal
        ? () => {
            cleanup();
            reject(new Error(`Auralink MCP request aborted: ${method}`));
          }
        : undefined;

      if (signal && abort) signal.addEventListener("abort", abort, { once: true });

      this.pending.set(id, {
        method,
        resolve: (value) => {
          cleanup();
          resolve(value);
        },
        reject: (error) => {
          cleanup();
          reject(error);
        },
        timer,
        abort,
      });

      child.stdin.write(payload, (error) => {
        if (!error) return;
        const pending = this.pending.get(id);
        if (pending) pending.reject(error instanceof Error ? error : new Error(String(error)));
      });
    });
  }

  private notify(method: string, params: unknown): void {
    const child = this.child;
    if (!child || child.killed) return;
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }

  private handleStdout(chunk: string): void {
    this.stdoutBuffer += chunk;
    for (;;) {
      const newline = this.stdoutBuffer.indexOf("\n");
      if (newline < 0) break;
      const line = this.stdoutBuffer.slice(0, newline).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      this.handleMessageLine(line);
    }
  }

  private handleMessageLine(line: string): void {
    let message: JsonObject;
    try {
      message = JSON.parse(line) as JsonObject;
    } catch {
      this.captureLog(`[stdout] ${line}`);
      return;
    }

    if (typeof message.id !== "number") return;
    const pending = this.pending.get(message.id);
    if (!pending) return;

    if (message.error && typeof message.error === "object") {
      const error = message.error as JsonObject;
      pending.reject(new Error(`${pending.method}: ${error.message ?? JSON.stringify(error)}`));
      return;
    }
    pending.resolve(message.result);
  }

  private captureLog(chunk: string): void {
    const lines = chunk
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    if (!lines.length) return;
    this.stderrLines.push(...lines);
    if (this.stderrLines.length > MAX_LOG_LINES) {
      this.stderrLines.splice(0, this.stderrLines.length - MAX_LOG_LINES);
    }
  }

  private rejectAll(error: Error): void {
    for (const pending of this.pending.values()) {
      pending.reject(error);
    }
    this.pending.clear();
  }
}

export default function auralinkMcpExtension(pi: ExtensionAPI) {
  let client: AuralinkMcpClient | undefined;
  const registeredMcpTools = new Set<string>();

  const stopClient = () => {
    client?.stop();
    client = undefined;
  };
  process.once("exit", stopClient);

  function getClient(ctx: ExtensionContext): AuralinkMcpClient {
    if (!client) client = new AuralinkMcpClient(resolveServerConfig(ctx.cwd));
    return client;
  }

  function registerDiscoveredTool(tool: McpTool): void {
    if (!tool.name || registeredMcpTools.has(tool.name)) return;
    registeredMcpTools.add(tool.name);

    const destructive = tool.annotations?.destructiveHint === true;
    const readOnly = tool.annotations?.readOnlyHint === true;
    const description = tool.description ?? `Auralink EQ MCP tool: ${tool.name}`;

    pi.registerTool({
      name: tool.name,
      label: tool.title ?? labelize(tool.name),
      description,
      promptSnippet: `Auralink EQ MCP: ${description.slice(0, 180)}`,
      promptGuidelines: [
        destructive
          ? `Use ${tool.name} only after the user explicitly asks for that live-audio or destructive change; never pass confirmed:true without explicit user confirmation.`
          : `Use ${tool.name} only for Auralink EQ tasks; explain whether it reads disk, writes presets, or affects live audio.`,
      ],
      parameters: normalizeToolSchema(tool.inputSchema) as any,
      executionMode: readOnly ? "parallel" : "sequential",
      async execute(_toolCallId, params, signal, _onUpdate, ctx) {
        const result = await getClient(ctx).callTool(tool.name, params ?? {}, signal);
        if ((result as JsonObject | undefined)?.isError === true) {
          throw new Error(mcpErrorText(result));
        }
        return {
          content: piContentFromMcpResult(result),
          details: { mcpTool: tool.name, result },
        };
      },
    });
  }

  function activateDiscoveredTools(tools: McpTool[]): void {
    const active = new Set(pi.getActiveTools());
    let changed = false;
    for (const tool of tools) {
      if (!active.has(tool.name)) {
        active.add(tool.name);
        changed = true;
      }
    }
    if (changed) pi.setActiveTools([...active]);
  }

  async function discoverAndRegister(ctx: ExtensionContext, refresh = false): Promise<McpTool[]> {
    const tools = await getClient(ctx).listTools(ctx.signal, refresh);
    for (const tool of tools) registerDiscoveredTool(tool);
    activateDiscoveredTools(tools);
    return tools;
  }

  pi.registerTool({
    name: "auralink_mcp_status",
    label: "Auralink MCP Status",
    description: "Show the Pi ↔ Auralink EQ MCP bridge status, server path, cached tool list, and recent MCP server logs.",
    promptSnippet: "Inspect the Auralink EQ MCP bridge status and cached tool list.",
    promptGuidelines: ["Use auralink_mcp_status when Auralink MCP tools appear missing or fail to connect."],
    parameters: STATUS_SCHEMA as any,
    async execute(_toolCallId, _params, signal, _onUpdate, ctx) {
      const c = getClient(ctx);
      let tools: McpTool[] | undefined;
      let error: string | undefined;
      try {
        tools = await c.listTools(signal);
        for (const tool of tools) registerDiscoveredTool(tool);
        activateDiscoveredTools(tools);
      } catch (caught) {
        error = caught instanceof Error ? caught.message : String(caught);
      }
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                ...c.status,
                registeredPiTools: [...registeredMcpTools],
                discoveredTools: tools?.map((tool) => tool.name),
                error,
              },
              null,
              2
            ),
          },
        ],
        details: { status: c.status, registeredMcpTools: [...registeredMcpTools], error },
      };
    },
  });

  pi.registerTool({
    name: "auralink_mcp_list_tools",
    label: "Auralink MCP List Tools",
    description: "List Auralink EQ MCP tools and register them as first-class Pi tools if needed.",
    promptSnippet: "List and refresh Auralink EQ MCP tool definitions.",
    promptGuidelines: ["Use auralink_mcp_list_tools if a specific Auralink MCP tool is not visible yet."],
    parameters: LIST_SCHEMA as any,
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const tools = await getClient(ctx).listTools(signal, Boolean((params as JsonObject).refresh));
      for (const tool of tools) registerDiscoveredTool(tool);
      activateDiscoveredTools(tools);
      return {
        content: [{ type: "text", text: JSON.stringify({ tools }, null, 2) }],
        details: { tools },
      };
    },
  });

  pi.registerTool({
    name: "auralink_mcp_call_tool",
    label: "Auralink MCP Call Tool",
    description: "Fallback passthrough for calling any Auralink EQ MCP tool by name. Prefer the first-class tool names when they are available.",
    promptSnippet: "Fallback: call an Auralink EQ MCP tool by name with raw arguments.",
    promptGuidelines: [
      "Prefer first-class Auralink MCP tools over auralink_mcp_call_tool when available.",
      "Never use auralink_mcp_call_tool to pass confirmed:true unless the user explicitly requested the live-audio change.",
    ],
    parameters: CALL_TOOL_SCHEMA as any,
    executionMode: "sequential",
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const input = params as { toolName: string; arguments?: JsonObject };
      const result = await getClient(ctx).callTool(input.toolName, input.arguments ?? {}, signal);
      if ((result as JsonObject | undefined)?.isError === true) {
        throw new Error(mcpErrorText(result));
      }
      return {
        content: piContentFromMcpResult(result),
        details: { mcpTool: input.toolName, result },
      };
    },
  });

  pi.registerTool({
    name: "auralink_mcp_list_resources",
    label: "Auralink MCP List Resources",
    description: "List Auralink EQ MCP resources and resource templates (eq://agent-guide, eq://safety-rules, headphones, etc.).",
    promptSnippet: "List Auralink EQ MCP resources and resource templates.",
    promptGuidelines: ["Use auralink_mcp_list_resources when you need an eq:// resource URI."],
    parameters: LIST_SCHEMA as any,
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const result = await getClient(ctx).listResources(signal, Boolean((params as JsonObject).refresh));
      return {
        content: [{ type: "text", text: truncateText(JSON.stringify(result, null, 2)) }],
        details: { result },
      };
    },
  });

  pi.registerTool({
    name: "auralink_mcp_read_resource",
    label: "Auralink MCP Read Resource",
    description: "Read an Auralink EQ MCP resource by URI, such as eq://agent-guide or eq://safety-rules.",
    promptSnippet: "Read an Auralink EQ MCP eq:// resource by URI.",
    promptGuidelines: ["Use auralink_mcp_read_resource to read Auralink MCP resources that are not exposed as dedicated tools."],
    parameters: READ_RESOURCE_SCHEMA as any,
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const input = params as { uri: string };
      const result = await getClient(ctx).readResource(input.uri, signal);
      return {
        content: [{ type: "text", text: truncateText(JSON.stringify(result, null, 2)) }],
        details: { result },
      };
    },
  });

  pi.registerTool({
    name: "auralink_mcp_list_prompts",
    label: "Auralink MCP List Prompts",
    description: "List Auralink EQ MCP prompts for guided tuning workflows.",
    promptSnippet: "List Auralink EQ MCP prompts for guided tuning workflows.",
    promptGuidelines: ["Use auralink_mcp_list_prompts to discover guided Auralink EQ prompt names."],
    parameters: LIST_SCHEMA as any,
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const result = await getClient(ctx).listPrompts(signal, Boolean((params as JsonObject).refresh));
      return {
        content: [{ type: "text", text: truncateText(JSON.stringify(result, null, 2)) }],
        details: { result },
      };
    },
  });

  pi.registerTool({
    name: "auralink_mcp_get_prompt",
    label: "Auralink MCP Get Prompt",
    description: "Fetch a guided Auralink EQ MCP prompt by name and arguments.",
    promptSnippet: "Fetch a guided Auralink EQ MCP prompt by name and arguments.",
    promptGuidelines: ["Use auralink_mcp_get_prompt only when a guided Auralink EQ prompt is more appropriate than direct tool use."],
    parameters: GET_PROMPT_SCHEMA as any,
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const input = params as { name: string; arguments?: JsonObject };
      const result = await getClient(ctx).getPrompt(input.name, input.arguments ?? {}, signal);
      return {
        content: [{ type: "text", text: truncateText(JSON.stringify(result, null, 2)) }],
        details: { result },
      };
    },
  });

  pi.registerCommand("auralink-mcp", {
    description: "Show Auralink EQ MCP bridge status and discover tools.",
    handler: async (args, ctx) => {
      const refresh = args.trim() === "refresh";
      const c = getClient(ctx);
      try {
        const tools = await discoverAndRegister(ctx, refresh);
        ctx.ui.notify(`Auralink MCP ready: ${tools.length} tools from ${c.status.serverPath}`, "info");
      } catch (caught) {
        const message = caught instanceof Error ? caught.message : String(caught);
        ctx.ui.notify(`Auralink MCP unavailable: ${message}`, "warning");
      }
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    client = new AuralinkMcpClient(resolveServerConfig(ctx.cwd));
    ctx.ui.setStatus("auralink-mcp", "Auralink MCP: connecting");
    try {
      const tools = await discoverAndRegister(ctx);
      ctx.ui.setStatus("auralink-mcp", `Auralink MCP: ${tools.length} tools`);
      ctx.ui.notify(`Auralink MCP tools loaded (${tools.length}).`, "info");
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : String(caught);
      ctx.ui.setStatus("auralink-mcp", "Auralink MCP: offline");
      ctx.ui.notify(`Auralink MCP unavailable: ${message}`, "warning");
    }
  });

  pi.on("before_agent_start", (event) => {
    if (registeredMcpTools.size === 0) return;
    return {
      systemPrompt:
        event.systemPrompt +
        "\n\nAuralink EQ MCP tools are available in this session. Auralink controls the user's live audio: " +
        "read get_agent_eq_guide/get_tuning_guidance before tuning, prefer get_autoeq_correction for named headphones, " +
        "and only call live-audio/destructive tools (audition/apply/rollback/routing/delete) after explicit user confirmation. " +
        "Never claim live sound changed unless get_current_audio_state reports active routing through Auralink.",
    };
  });

  pi.on("session_shutdown", () => {
    process.off("exit", stopClient);
    stopClient();
  });
}
