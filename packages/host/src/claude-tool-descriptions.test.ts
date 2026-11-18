import { appendFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import { CLAUDE_BRIDGE_CAPABILITIES, ClaudeModsBridge } from "./claude-mods-bridge.js";
import { ClaudeSessionHistory } from "./claude-session-history.js";
import { ClaudeTranscriptProjection } from "./claude-transcript.js";

it("shows a native Bash caption while running and hands it to history without a duplicate", async () => {
  const root = await mkdtemp(join(tmpdir(), "orbis-claude-caption-"));
  const path = join(root, "session.jsonl");
  const at = "2026-11-18T10:00:00.000Z";
  const prompt = { type: "user", uuid: "user", parentUuid: null, timestamp: at, message: { role: "user", content: "Check status" } };
  await writeFile(path, JSON.stringify(prompt) + "\n");
  const bridge = new ClaudeModsBridge({ createHistory: (id, config, publish) =>
    new ClaudeSessionHistory(id, config, publish, { locate: async () => path, settleTimeoutMs: 50, settleIntervalMs: 1 }) });
  try {
    const current = bridge.hello({ type: "hello", instanceId: "i", sessionId: "s", cwd: root,
      claudeVersion: "2.1.318", bridgeVersion: "4", interactive: true, capabilities: CLAUDE_BRIDGE_CAPABILITIES });
    if (!current.ok) throw new Error(current.error);
    const send = (event: unknown) => expect(bridge.receiveEvent(current.runtimeId, current.generation, event)).toBe("accepted");
    const sync = () => bridge.sync(current.runtimeId, { type: "session.sync", sessionId: "s", syncId: "caption", range: "preview" });
    await sync();
    send({ type: "turn.start", turnId: "turn" });
    send({ type: "turn.step.row", turnId: "turn", stepIndex: 0, uuid: "call" });
    const args = { command: "printf status", description: "读取服务状态并核对结果" };
    send({ type: "tool.started", toolName: "Bash", toolCallId: "toolu_status", arguments: args });
    const live = await sync();
    expect(live?.live?.messages.map(item => item.message)).toContainEqual(expect.objectContaining({
      messageId: "claude-tool-description:toolu_status", role: "system", content: [{ type: "text", text: args.description }],
    }));
    expect(live?.live?.toolInventory?.totalCount).toBe(1);

    const call = { type: "assistant", uuid: "call", parentUuid: "user", timestamp: at,
      message: { role: "assistant", content: [{ type: "tool_use", id: "toolu_status", name: "Bash", input: args }] } };
    await appendFile(path, JSON.stringify(call) + "\n");
    send({ type: "session.append", uuid: "call", door: "response" });
    send({ type: "turn.step.finished", turnId: "turn", stepIndex: 0, uuids: ["call"] });
    await vi.waitFor(async () => expect((await sync())?.entries.some(entry => entry.entryId === "call")).toBe(true));
    const committed = await sync();
    const captions = committed?.display?.entries.filter(entry => entry.entryId === "claude-tool-description:toolu_status");
    expect(captions).toHaveLength(1);
    expect(captions?.[0]?.message).toMatchObject({ role: "system", content: [{ type: "text", text: args.description }] });
    expect(committed?.live?.messages.some(item => item.message.messageId === "claude-tool-description:toolu_status")).toBe(false);
    expect(await readFile(path, "utf8")).toBe(JSON.stringify(prompt) + "\n" + JSON.stringify(call) + "\n");
  } finally { bridge.close(); await rm(root, { recursive: true, force: true }); }
});

it("does not turn arbitrary tool inputs or blank descriptions into captions", () => {
  const projection = new ClaudeTranscriptProjection();
  projection.push({ type: "assistant", uuid: "call", timestamp: "2026-11-18T10:00:00.000Z", message: { content: [
    { type: "tool_use", id: "a", name: "Bash", input: { command: "printf not-a-caption", description: "  " } },
    { type: "tool_use", id: "b", name: "Unknown", input: { description: "Unknown input" } },
  ] } });
  expect(projection.entries.map(entry => entry.entryId)).toEqual(["call"]);
});
