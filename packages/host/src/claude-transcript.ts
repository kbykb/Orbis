import { open, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { RemoteSessionEntry } from "@orbis/protocol";

/**
 * Claude Code's native transcript (`<config>/projects/<project>/<sessionId>.jsonl`) is the
 * persistent history authority (ADR-0033 §3). This module projects its rows into the
 * standard entry shape; it never writes the file and never infers identity from text.
 */

const TOOL_RESULT_TEXT_LIMIT = 256 * 1024;
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9-]{0,127}$/u;

type Row = Record<string, unknown>;

/** Session facts Claude keeps in metadata rows beside the conversation. */
export type ClaudeTranscriptFacts = {
  /** `/rename` beats the generated title. */
  title?: string;
  /** The Session's permission mode as of its latest `permission-mode` row. */
  permissionMode?: string;
  /** The model of the latest assistant reply. */
  model?: string;
  cwd?: string;
};

/** Incremental projection state; rows must be fed in file order. */
export class ClaudeTranscriptProjection {
  readonly entries: RemoteSessionEntry[] = [];
  readonly facts: ClaudeTranscriptFacts = {};
  /** Every row uuid (rendered or not) → nearest rendered ancestor entry id. */
  readonly #anchor = new Map<string, string | null>();
  readonly #toolNames = new Map<string, string>();
  readonly #ids = new Set<string>();
  #leaf: string | null = null;
  #customTitle = false;

  get leafId(): string | null { return this.#leaf; }
  has(uuid: string): boolean { return this.#anchor.has(uuid); }

  push(row: Row): void {
    this.#observeFacts(row);
    const uuid = text(row.uuid);
    if (uuid === undefined || this.#anchor.has(uuid)) return;
    const parentUuid = text(row.parentUuid);
    const parent = parentUuid === undefined ? null : this.#anchor.get(parentUuid) ?? null;
    // Sidechains are subagent transcripts; they never join the main conversation path.
    if (row.isSidechain === true) { this.#anchor.set(uuid, parent); return; }
    const timestamp = text(row.timestamp) ?? new Date(0).toISOString();
    const produced = this.#project(row, uuid, timestamp);
    let previous = parent;
    for (const entry of produced) {
      if (this.#ids.has(entry.entryId)) continue;
      this.#ids.add(entry.entryId);
      this.entries.push({ ...entry, parentId: previous });
      previous = entry.entryId;
    }
    this.#anchor.set(uuid, previous);
    if (produced.length > 0) this.#leaf = previous;
  }

  #observeFacts(row: Row): void {
    const customTitle = row.type === "custom-title" ? text(row.customTitle) : undefined;
    const aiTitle = row.type === "ai-title" ? text(row.aiTitle) : undefined;
    const permissionMode = row.type === "permission-mode" ? text(row.permissionMode) : undefined;
    if (customTitle !== undefined) {
      this.facts.title = customTitle;
      this.#customTitle = true;
    } else if (aiTitle !== undefined && !this.#customTitle) this.facts.title = aiTitle;
    if (permissionMode !== undefined) this.facts.permissionMode = permissionMode;
    if (typeof row.cwd === "string" && row.cwd.length > 0 && row.isSidechain !== true) this.facts.cwd = row.cwd;
    const model = row.type === "assistant" && row.isSidechain !== true ? text(record(row.message)?.model) : undefined;
    // `<synthetic>` marks replies the CLI wrote itself (errors, interruptions), not a model.
    if (model !== undefined && !model.startsWith("<")) this.facts.model = model;
  }

  #project(row: Row, uuid: string, timestamp: string): Omit<RemoteSessionEntry, "parentId">[] {
    const millis = Date.parse(timestamp);
    const at = Number.isSafeInteger(millis) && millis >= 0 ? millis : 0;
    const attachment = row.type === "attachment" ? record(row.attachment) : undefined;
    if (attachment?.type === "queued_command" && attachment.commandMode === "task-notification"
        && record(attachment.origin)?.kind === "task-notification") {
      return [messageEntry(uuid, timestamp, taskNotification(plainText(attachment.prompt) ?? "", at))];
    }
    const message = record(row.message);
    if (message === undefined || row.isMeta === true) return [];
    if (row.type === "user") {
      // Claude persists background completions as user rows, but their origin is
      // the session task runner. Keep actual user text (including XML) untouched.
      if (record(row.origin)?.kind === "task-notification" && row.promptSource === "system") {
        return [messageEntry(uuid, timestamp, taskNotification(plainText(message.content) ?? "", at))];
      }
      const summary = row.isCompactSummary === true ? plainText(message.content) : undefined;
      if (summary !== undefined) return [{ entryId: uuid, type: "compaction", timestamp, data: { summary } }];
      const content = message.content;
      const tagged = taggedRow(plainText(content));
      if (tagged === null) return [];
      if (tagged !== undefined) return [messageEntry(uuid, timestamp, { ...tagged, timestamp: at })];
      if (typeof content === "string") {
        return content.trim().length === 0 ? [] : [messageEntry(uuid, timestamp, { role: "user", content, timestamp: at })];
      }
      if (!Array.isArray(content)) return [];
      const texts = content.flatMap(block => {
        const item = record(block);
        return item?.type === "text" && typeof item.text === "string" && item.text.trim().length > 0 ? [{ type: "text", text: item.text }] : [];
      });
      const result: Omit<RemoteSessionEntry, "parentId">[] = [];
      if (texts.length > 0) result.push(messageEntry(uuid, timestamp, { role: "user", content: texts, timestamp: at }));
      const results = content.filter(block => record(block)?.type === "tool_result");
      results.forEach((block, index) => {
        const item = record(block)!;
        const toolCallId = text(item.tool_use_id);
        if (toolCallId === undefined) return;
        const toolName = this.#toolNames.get(toolCallId);
        const id = results.length === 1 && texts.length === 0 ? uuid : `${uuid}:result:${index}`;
        result.push(messageEntry(id, timestamp, { role: "toolResult", toolCallId, ...(toolName === undefined ? {} : { toolName }),
          content: [{ type: "text", text: clip(plainText(item.content) ?? "") }], isError: item.is_error === true, timestamp: at }));
      });
      return result;
    }
    if (row.type === "assistant") {
      if (!Array.isArray(message.content)) return [];
      const blocks = message.content.flatMap((block): Record<string, unknown>[] => {
        const item = record(block);
        if (item?.type === "text" && typeof item.text === "string" && item.text.length > 0) return [{ type: "text", text: item.text }];
        // Hidden thinking is persisted as an empty string plus a signature; there is nothing to show.
        if (item?.type === "thinking" && typeof item.thinking === "string" && item.thinking.length > 0) {
          // The TUI marks only narration blocks as summary. thinkingDisplay is
          // a session preference shared by ordinary thinking, not this distinction.
          return isNativeNarration(item.signature) && item.thinking.trim().length > 0
            ? [{ type: "text", text: item.thinking.trim() }]
            : [{ type: "thinking", thinking: item.thinking }];
        }
        if (item?.type === "tool_use" && typeof item.id === "string" && typeof item.name === "string") {
          this.#toolNames.set(item.id, item.name);
          return [{ type: "toolCall", id: item.id, name: item.name, arguments: item.input ?? {} }];
        }
        return [];
      });
      if (blocks.length === 0) return [];
      const model = text(message.model);
      return [messageEntry(uuid, timestamp, { role: "assistant", content: blocks, timestamp: at, ...(model === undefined ? {} : { model }) })];
    }
    return [];
  }
}

/**
 * Reads appended transcript bytes. A shrunk or replaced file restarts the projection;
 * an unterminated last line waits for the next read.
 */
export class ClaudeTranscriptReader {
  readonly #path: string;
  #projection = new ClaudeTranscriptProjection();
  #offset = 0;
  #pending = "";
  #inode: number | undefined;

  constructor(path: string) { this.#path = path; }
  get path(): string { return this.#path; }
  get projection(): ClaudeTranscriptProjection { return this.#projection; }

  /** Returns true when previously read entries were discarded (the source must re-baseline). */
  async read(): Promise<boolean> {
    const info = await stat(this.#path);
    let reset = false;
    if (info.size < this.#offset || (this.#inode !== undefined && info.ino !== this.#inode)) {
      this.#projection = new ClaudeTranscriptProjection();
      this.#offset = 0;
      this.#pending = "";
      reset = true;
    }
    this.#inode = info.ino;
    if (info.size === this.#offset) return reset;
    const handle = await open(this.#path, "r");
    try {
      const length = info.size - this.#offset;
      const buffer = Buffer.alloc(length);
      const { bytesRead } = await handle.read(buffer, 0, length, this.#offset);
      this.#offset += bytesRead;
      const chunk = this.#pending + buffer.subarray(0, bytesRead).toString("utf8");
      const lines = chunk.split("\n");
      this.#pending = lines.pop() ?? "";
      for (const line of lines) {
        if (line.trim().length === 0) continue;
        let row: unknown;
        try { row = JSON.parse(line); } catch { continue; }
        const value = record(row);
        if (value !== undefined) this.#projection.push(value);
      }
    } finally {
      await handle.close();
    }
    return reset;
  }
}

/** `CLAUDE_CONFIG_DIR` reported by the bridge, else the default `~/.claude`. */
export function claudeConfigDir(reported?: string): string {
  return reported !== undefined && reported.trim().length > 0 ? reported : join(homedir(), ".claude");
}

/** Locates the Session's transcript without re-deriving Claude's project-directory encoding. */
export async function findClaudeTranscript(sessionId: string, configDir: string): Promise<string | undefined> {
  if (!SESSION_ID.test(sessionId)) return undefined;
  const projects = join(configDir, "projects");
  let names: string[];
  try { names = await readdir(projects); } catch { return undefined; }
  for (const name of names) {
    const candidate = join(projects, name, `${sessionId}.jsonl`);
    try { if ((await stat(candidate)).isFile()) return candidate; } catch { /* not this project */ }
  }
  return undefined;
}

/**
 * Slash commands, their local output and `!` shell runs are stored as user rows wrapped in
 * Claude's own tags. Show what the person ran and what it printed, not the markup.
 * `null` is a recognised row with nothing to show.
 */
function taggedRow(value: string | undefined): Record<string, unknown> | null | undefined {
  if (value === undefined || !value.trimStart().startsWith("<")) return undefined;
  const tag = (name: string): string | undefined => new RegExp(`<${name}>([\\s\\S]*?)</${name}>`, "u").exec(value)?.[1];
  const joined = (...parts: (string | undefined)[]): string =>
    parts.flatMap(part => part === undefined ? [] : [part.replace(ANSI, "").trim()]).filter(part => part.length > 0).join("\n");
  const name = tag("command-name")?.trim();
  if (name !== undefined && name.length > 0) {
    const args = tag("command-args")?.trim();
    const command = name.startsWith("/") ? name : `/${name}`;
    return { role: "user", content: args ? `${command} ${args}` : command };
  }
  if (tag("local-command-stdout") !== undefined || tag("local-command-stderr") !== undefined) {
    const output = joined(tag("local-command-stdout"), tag("local-command-stderr"));
    return output.length === 0 ? null : { role: "bashExecution", command: "", output };
  }
  const input = tag("bash-input")?.trim();
  if (input !== undefined) return input.length === 0 ? null : { role: "bashExecution", command: input, output: "" };
  if (tag("bash-stdout") !== undefined || tag("bash-stderr") !== undefined) {
    const output = joined(tag("bash-stdout"), tag("bash-stderr"));
    return output.length === 0 ? null : { role: "bashExecution", command: "", output: clip(output) };
  }
  return undefined;
}

// eslint-disable-next-line no-control-regex -- Claude stores colored command output verbatim.
const ANSI = /\u001b\[[0-9;?]*[A-Za-z]/gu;

function messageEntry(entryId: string, timestamp: string, message: Record<string, unknown>): Omit<RemoteSessionEntry, "parentId"> {
  return { entryId, type: "message", timestamp, data: { message } };
}

/** Claude Code 2.1.318's summary presentation hint; never forward the signature. */
function isNativeNarration(signature: unknown): boolean {
  if (typeof signature !== "string" || signature.length === 0) return false;
  let value: Uint8Array | undefined;
  try { value = Buffer.from(atob(signature), "binary"); } catch { return false; }
  for (const field of [2, 1, 8]) {
    value = protobufBytes(value, field);
    if (value === undefined) return false;
  }
  return Buffer.from(value).toString("utf8") === "narration";
}

/** Read the native length-delimited label, skipping the envelope's other wire fields. */
function protobufBytes(bytes: Uint8Array, field: number): Uint8Array | undefined {
  let offset = 0;
  let found: Uint8Array | undefined;
  const varint = (): number | undefined => {
    let value = 0;
    let factor = 1;
    for (let i = 0; i < 10 && offset < bytes.length; i++, factor *= 128) {
      const byte = bytes[offset++]!;
      value += (byte & 127) * factor;
      if ((byte & 128) === 0) return value;
    }
    return undefined;
  };
  while (offset < bytes.length) {
    const tag = varint();
    if (tag === undefined) return undefined;
    const wire = tag % 8;
    if (wire === 0) { if (varint() === undefined) return undefined; }
    else if (wire === 1) offset += 8;
    else if (wire === 5) offset += 4;
    else if (wire === 2) {
      const length = varint();
      if (length === undefined || length > bytes.length - offset) return undefined;
      if (Math.floor(tag / 8) === field) found = bytes.subarray(offset, offset + length);
      offset += length;
    } else return undefined;
    if (offset > bytes.length) return undefined;
  }
  return found;
}

function taskNotification(body: string, timestamp: number): Record<string, unknown> {
  const status = /<status>([^<]*)<\/status>/u.exec(body)?.[1];
  const title = status === "completed" ? "后台任务已完成" : status === "failed" ? "后台任务失败"
    : status === "killed" || status === "cancelled" ? "后台任务已停止" : "后台任务状态已更新";
  const summary = /<summary>([\s\S]*?)<\/summary>/u.exec(body)?.[1];
  const command = summary === undefined ? undefined : /^Background command "([\s\S]*)" (?:completed|failed)/u.exec(summary)?.[1];
  return { role: "system", content: command ? `${title}：${clip(command)}` : title, timestamp };
}

function plainText(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return undefined;
  const parts = value.flatMap(block => {
    const item = record(block);
    return item?.type === "text" && typeof item.text === "string" ? [item.text] : [];
  });
  return parts.length === 0 ? undefined : parts.join("\n");
}

function clip(value: string): string {
  return value.length <= TOOL_RESULT_TEXT_LIMIT ? value : `${value.slice(0, TOOL_RESULT_TEXT_LIMIT)}… [truncated]`;
}

function record(value: unknown): Row | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Row : undefined;
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= 256 ? value : undefined;
}
