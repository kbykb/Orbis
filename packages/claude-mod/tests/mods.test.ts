import { expect, mock, test } from "claude-code/testing";
import { setup } from "./fixtures.ts";

// Verify the Orbis bridge delivers ordered tool events without replacing the native result.
test("forwards native tool events without replacing the tool result", async ($, on) => {
  const { clock, world } = setup(on);
  world.toolResult = "orbis-test-result";
  await $.session.start({ cwd: "/workspace", surface: "terminal", isInteractive: true });
  await clock.settle();

  const result = await $.tool.call({ tool: "Bash", tool_use_id: "tool-delivery", command: "echo this command must not run" });
  expect(world.toolCalls).toHaveLength(1);
  expect(result.result).toBe("orbis-test-result");
  const deliveries = world.requests.filter(request => request.url.endsWith("/event")
    && ["tool.started", "tool.finished"].includes((request.body.event as { type: string })?.type));
  expect(deliveries.map(request => request.body)).toEqual([
    { runtimeId: "claude:same-native-session", generation: "first-generation",
      event: { type: "tool.started", toolCallId: "tool-delivery", toolName: "Bash", arguments: { command: "echo this command must not run" } } },
    { runtimeId: "claude:same-native-session", generation: "first-generation",
      event: { type: "tool.finished", toolCallId: "tool-delivery", toolName: "Bash", result: "orbis-test-result", isError: false } },
  ]);
});

test("commits stored progress before a long main tool starts, without waiting for the next request", async ($, on) => {
  const { clock, world } = setup(on);
  mock.session(on);
  on("turn.step", async function* (_$, event) {
    yield { kind: "text", index: 0, text: "Checking server status." };
    return { turnId: event.turnId, index: event.index, answer: "Checking server status.", toolUses: [], stopReason: "tool_use", usage: null };
  });
  await $.session.start({ cwd: "/workspace", surface: "terminal", isInteractive: true });
  await clock.settle();
  await $.turn.start({ text: "check", turnId: "main" });
  const stream = $.turn.step({ turnId: "main", index: 0, model: "test", messageCount: 1 });
  for await (const chunk of stream) void chunk;
  await stream.result;
  await $.session.append({ door: "response", uuid: "native-progress", origin: { kind: "model", model: "test" },
    message: { type: "assistant", role: "assistant", content: [{ type: "text", text: "Checking server status." }] } });
  const events = () => world.requests.flatMap(request => request.body.event ? [request.body.event as Record<string, unknown>] : []);
  expect(events().some(event => event.type === "turn.step.finished")).toBe(false);
  world.toolDelay = 10_000;
  const running = $.tool.call({ tool: "Bash", tool_use_id: "long-tool", command: "must not execute" });
  await clock.settle();
  const delivered = events();
  expect(delivered.find(event => event.type === "turn.step.finished")).toEqual({ type: "turn.step.finished", turnId: "main", stepIndex: 0, uuids: ["native-progress"] });
  expect(delivered.findIndex(event => event.type === "turn.step.finished")).toBeLessThan(delivered.findIndex(event => event.type === "tool.started"));
  expect(delivered.some(event => event.type === "tool.finished" || event.type === "turn.complete")).toBe(false);
  await clock.advance(10_000);
  await running;
});

test("does not seal a step when native tools start before its final streamed chunks arrive", async ($, on) => {
  const { clock, world } = setup(on);
  mock.session(on);
  world.toolDelay = 10_000;
  let running: Promise<unknown> | undefined;
  on("turn.step", async function* (_$, event) {
    await $.session.append({ door: "response", uuid: "interleaved-progress", origin: { kind: "model", model: "test" },
      message: { type: "assistant", role: "assistant", content: [{ type: "text", text: "Visible progress." }] } });
    running = $.tool.call({ tool: "Bash", tool_use_id: "interleaved-tool", command: "must not execute" });
    await clock.settle();
    yield { kind: "text", index: 0, text: "Visible progress." };
    return { turnId: event.turnId, index: event.index, answer: "Visible progress.", toolUses: [], stopReason: "tool_use", usage: null };
  });
  await $.session.start({ cwd: "/workspace", surface: "terminal", isInteractive: true });
  await clock.settle();
  await $.turn.start({ text: "check", turnId: "main" });
  const stream = $.turn.step({ turnId: "main", index: 0, model: "test", messageCount: 1 });
  for await (const chunk of stream) void chunk;
  await stream.result;
  const delivered = world.requests.flatMap(request => request.body.event ? [request.body.event as Record<string, unknown>] : []);
  const started = delivered.findIndex(event => event.type === "tool.started");
  const chunks = delivered.findIndex(event => event.type === "turn.step.chunks");
  const finished = delivered.findIndex(event => event.type === "turn.step.finished");
  expect(started).toBeGreaterThanOrEqual(0);
  expect(chunks).toBeGreaterThan(started);
  expect(finished).toBeGreaterThan(chunks);
  expect(delivered[finished]).toEqual({ type: "turn.step.finished", turnId: "main", stepIndex: 0, uuids: ["interleaved-progress"] });
  expect(delivered.some(event => event.type === "tool.finished")).toBe(false);
  await clock.advance(10_000);
  await running;
});
