import { describe, expect, it, vi } from "vitest";
import { applyStateDelta, type AgentStateSnapshot, type RelayToDeviceMessage } from "@orbis/protocol";
import { AgentStateRegistry, type StateScope } from "./agent-state-registry.js";
import { AgentStateSubscriptions } from "./agent-state-subscriptions.js";
import { buildAgentStateSnapshot } from "./agent-state-snapshot.js";

const scope: StateScope = { kind: "agent", key: { hostId: "h", agentKind: "pi", sessionId: "s" } };
const fact = (value: unknown, revision = 1) => ({ source: { producer: "adapter" as const, sourceId: "s", sourceEpoch: "e", sourceRevision: revision }, availability: "ready" as const, completeness: "complete" as const, value });
const snapshot = (message: RelayToDeviceMessage): AgentStateSnapshot => {
  if (message.type !== "agent.state.snapshot") throw Error("snapshot");
  return message;
};
const menu = (revision: number, size = 10_000) => ({ padding: "x".repeat(size), revision });
const subscribe = (requestId: string, domains: string[]) => ({ type: "agent.state.request" as const, requestId, subscribe: true,
  stateFormat: "compact-v2" as const, domains });

describe("model subscriptions", () => {
  // FT-G06: negotiated peers receive exact collection edits; legacy peers and
  // new source generations always receive self-contained recovery values.
  it("FT-G06 sends versioned collection changes and preserves terminal records", async () => {
    const registry = new AgentStateRegistry({ modelEpoch: "model" });
    const messages: Array<{ device: string; message: RelayToDeviceMessage }> = [];
    const subscriptions = new AgentStateSubscriptions(registry, (device, message) => { messages.push({ device, message }); });
    const before = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`q${i}`, { queueId: `q${i}`, text: "body".repeat(100), state: "accepted" }]));
    registry.commitValue(scope, "delivery", fact(before));
    for (const device of ["compact", "legacy"]) subscriptions.register(device, scope, { type: "agent.state.request", requestId: device,
      subscribe: true, domains: ["delivery"], ...(device === "compact" ? { stateFormat: "compact-v2" as const } : {}) });
    const after: Record<string, unknown> = { ...before, q0: { ...before.q0!, state: "delivered" } }; delete after.q1;
    registry.commitValue(scope, "delivery", fact(after, 2));
    await Promise.resolve();
    const compact = messages.find(x => x.device === "compact")!.message;
    const legacy = messages.find(x => x.device === "legacy")!.message;
    if (compact.type !== "agent.state.snapshot" || legacy.type !== "agent.state.snapshot") throw Error("snapshot");
    const row = compact.domains[0]!;
    expect(row.delta?.baseRevision).toBe(1); expect(row.value).toBeNull();
    expect(applyStateDelta(before, row.delta!.operations)).toEqual(after);
    expect(Buffer.byteLength(JSON.stringify(row))).toBeLessThan(Buffer.byteLength(JSON.stringify(legacy.domains[0])) / 10);
    expect(legacy.domains[0]!.value).toEqual(after); expect(legacy.domains[0]!.delta).toBeUndefined();
    registry.commitValue(scope, "delivery", { ...fact(after, 3), source: { ...fact(after, 3).source, sourceEpoch: "replacement" } });
    await Promise.resolve();
    const replaced = messages.at(-2)!.message;
    expect(replaced).toMatchObject({ domains: [{ value: after }] });
    if (replaced.type === "agent.state.snapshot") expect(replaced.domains[0]!.delta).toBeUndefined();
    subscriptions.close();
  });
  it("publishes a committed cross-domain transaction with execution separate, scoped to its device and selected domains", async () => {
    const registry = new AgentStateRegistry();
    const received: Array<{ device: string; message: RelayToDeviceMessage }> = [];
    const subscriptions = new AgentStateSubscriptions(registry, (device, message) => { received.push({ device, message }); });
    subscriptions.register("a", scope, { type: "agent.state.request", requestId: "r", subscribe: true, domains: ["execution", "interactions"] });
    subscriptions.register("b", { kind: "device", key: { hostId: "h", deviceId: "b" } }, { type: "agent.state.request", requestId: "private", subscribe: true });
    registry.commitTransaction([
      { kind: "value", scope, domain: "execution", fact: fact({ phase: "idle" }) },
      { kind: "value", scope, domain: "interactions", fact: fact({}) },
      { kind: "value", scope, domain: "model", fact: fact({ id: "model" }) },
    ]);
    expect(received).toEqual([]);
    await Promise.resolve();
    expect(received).toHaveLength(2);
    expect(received[0]?.device).toBe("a");
    expect(received[0]?.message).toMatchObject({ requestId: "r", update: true,
      domains: [{ domain: "execution", projectionComplete: true }] });
    expect(received[1]?.message).toMatchObject({ requestId: "r", update: true,
      domains: [{ domain: "interactions", projectionComplete: true }] });
    subscriptions.clearDevice("a");
    registry.commitValue(scope, "execution", fact({ phase: "running" }, 2));
    await Promise.resolve();
    expect(received).toHaveLength(2);
    subscriptions.close();
  });
  it("keeps other scopes isolated and bounds subscriptions", () => {
    const registry = new AgentStateRegistry();
    const subscriptions = new AgentStateSubscriptions(registry, () => {});
    for (let i = 0; i < 256; i++) expect(subscriptions.register("a", { kind: "agent", key: { hostId: "h", agentKind: "pi", sessionId: `s${i}` } },
      { type: "agent.state.request", requestId: `r${i}`, subscribe: true })).toBe(true);
    expect(subscriptions.register("a", { kind: "agent", key: { hostId: "h", agentKind: "pi", sessionId: "overflow" } },
      { type: "agent.state.request", requestId: "full", subscribe: true })).toBe(false);
    expect(subscriptions.register("a", { kind: "host" }, { type: "agent.state.request", requestId: "host", subscribe: true })).toBe(true);
    expect(subscriptions.register("a", { kind: "device", key: { hostId: "h", deviceId: "a" } },
      { type: "agent.state.request", requestId: "device", subscribe: true })).toBe(true);
    expect(subscriptions.register("b", { kind: "host" }, { type: "agent.state.request", requestId: "other", subscribe: true })).toBe(true);
    subscriptions.close();
  });
  it("replaces a runtime's previous session subscription without exhausting capacity or publishing its old scope", async () => {
    const registry = new AgentStateRegistry();
    const received: RelayToDeviceMessage[] = [];
    const subscriptions = new AgentStateSubscriptions(registry, (_, message) => { received.push(message); });
    const sessionScope = (i: number): StateScope => ({ kind: "agent", key: { hostId: "h", agentKind: "pi", sessionId: `s${i}` } });
    for (let i = 0; i < 70; i++) expect(subscriptions.register("a", sessionScope(i), {
      type: "agent.state.request", requestId: `r${i}`, runtimeId: "runtime", sessionId: `s${i}`, subscribe: true,
    })).toBe(true);
    registry.commitValue(sessionScope(0), "execution", fact({ phase: "idle" }));
    registry.commitValue(sessionScope(69), "execution", fact({ phase: "running" }));
    await Promise.resolve();
    expect(received).toHaveLength(1);
    expect(received[0]).toMatchObject({ requestId: "r69", runtimeId: "runtime", sessionId: "s69",
      domains: [{ domain: "execution", value: { phase: "running" } }] });
    subscriptions.close();
  });
  it("answers applied domain versions without changing content revisions", () => {
    const registry = new AgentStateRegistry({ modelEpoch: "model" });
    registry.commitValue(scope, "execution", fact({ phase: "idle" }));
    const snapshot = buildAgentStateSnapshot({ registry, scope, requestId: "read", known: [{ domain: "execution", modelEpoch: "model", revision: 1 }] });
    expect(snapshot.domains).toEqual([]);
    expect(snapshot.unchanged).toEqual(["execution"]);
    expect(registry.read(scope, "execution")?.revision).toBe(1);
  });
  it("retains only the latest replaceable state across ticks without building or projecting blocked snapshots", async () => {
    const registry = new AgentStateRegistry();
    const received: AgentStateSnapshot[] = [];
    let writable = false;
    const project = vi.fn((_device: string, _scope: StateScope, _domain: string, value: unknown) => value);
    const subscriptions = new AgentStateSubscriptions(registry, (_device, message) => { received.push(snapshot(message)); }, project, () => writable);
    subscriptions.register("a", scope, subscribe("r", ["capabilities"]));
    const build = vi.spyOn(registry, "snapshot");
    for (let i = 1; i <= 6; i++) {
      registry.commitValue(scope, "capabilities", fact(menu(i), i));
      await Promise.resolve();
    }
    expect(received).toEqual([]);
    expect(build).not.toHaveBeenCalled();
    expect(project).not.toHaveBeenCalled();
    writable = true;
    for (let i = 0; i < 10; i++) subscriptions.notifyWritable("a");
    await Promise.resolve();
    expect(received).toHaveLength(1);
    expect(received[0]).toMatchObject({ update: true, domains: [{ domain: "capabilities", revision: 6, value: menu(6) }] });
    const reads = build.mock.calls.length;
    subscriptions.notifyWritable("a");
    await Promise.resolve();
    expect(build).toHaveBeenCalledTimes(reads);
    subscriptions.close();
  });
  it("computes a resumed delta from the last successful baseline directly to the latest projection", async () => {
    const registry = new AgentStateRegistry({ modelEpoch: "model" });
    const received: AgentStateSnapshot[] = [];
    let writable = true;
    registry.commitValue(scope, "capabilities", fact(menu(1)));
    const subscriptions = new AgentStateSubscriptions(registry, (_device, message) => { received.push(snapshot(message)); }, undefined, () => writable);
    subscriptions.register("a", scope, subscribe("r", ["capabilities"]));
    registry.commitValue(scope, "capabilities", fact(menu(2), 2));
    await Promise.resolve();
    writable = false;
    for (let i = 3; i <= 7; i++) {
      registry.commitValue(scope, "capabilities", fact(menu(i), i));
      await Promise.resolve();
    }
    expect(received).toHaveLength(1);
    writable = true;
    subscriptions.notifyWritable("a");
    await Promise.resolve();
    const row = received[1]!.domains[0]!;
    expect(row.delta?.baseRevision).toBe(2);
    expect(row.revision).toBe(7);
    expect(applyStateDelta(menu(2), row.delta!.operations)).toEqual(menu(7));
    subscriptions.close();
  });
  it("does not advance a refused send's baseline or retry it until another change or writable notice", async () => {
    const registry = new AgentStateRegistry();
    const attempts: AgentStateSnapshot[] = [];
    let accepts = false;
    registry.commitValue(scope, "capabilities", fact(menu(1)));
    const subscriptions = new AgentStateSubscriptions(registry, (_device, message) => { attempts.push(snapshot(message)); return accepts; });
    subscriptions.register("a", scope, subscribe("r", ["capabilities"]));
    registry.commitValue(scope, "capabilities", fact(menu(2), 2));
    await Promise.resolve(); await Promise.resolve();
    expect(attempts).toHaveLength(1);
    registry.commitValue(scope, "capabilities", fact(menu(3), 3));
    await Promise.resolve();
    accepts = true;
    subscriptions.notifyWritable("a");
    await Promise.resolve();
    const row = attempts.at(-1)!.domains[0]!;
    expect(row.delta?.baseRevision).toBe(1);
    expect(applyStateDelta(menu(1), row.delta!.operations)).toEqual(menu(3));
    subscriptions.close();
  });
  it("retains unsent domains when backpressure returns between snapshot parts", async () => {
    const registry = new AgentStateRegistry();
    const received: AgentStateSnapshot[] = [];
    let writable = true;
    const subscriptions = new AgentStateSubscriptions(registry, (_device, message) => {
      received.push(snapshot(message));
      writable = false;
    }, undefined, () => writable);
    subscriptions.register("a", scope, subscribe("r", ["capabilities", "resources"]));
    registry.commitTransaction([
      { kind: "value", scope, domain: "capabilities", fact: fact(menu(1, 300_000)) },
      { kind: "value", scope, domain: "resources", fact: fact(menu(1, 300_000)) },
    ]);
    await Promise.resolve();
    expect(received.map(part => part.domains.map(row => row.domain))).toEqual([["capabilities"]]);
    writable = true;
    subscriptions.notifyWritable("a");
    await Promise.resolve();
    expect(received.map(part => part.domains.map(row => row.domain))).toEqual([["capabilities"], ["resources"]]);
    writable = true;
    subscriptions.notifyWritable("a");
    await Promise.resolve();
    expect(received).toHaveLength(2);
    subscriptions.close();
  });
  it("publishes execution, live content, and delivery while retaining blocked capabilities", async () => {
    const registry = new AgentStateRegistry();
    const received: AgentStateSnapshot[] = [];
    let writable = false;
    const subscriptions = new AgentStateSubscriptions(registry, (_device, message) => { received.push(snapshot(message)); }, undefined, () => writable);
    subscriptions.register("a", scope, subscribe("r", ["execution", "live", "delivery", "capabilities"]));
    for (let i = 1; i <= 3; i++) {
      registry.commitTransaction([
        { kind: "value", scope, domain: "execution", fact: fact({ phase: "running", step: i }, i) },
        { kind: "value", scope, domain: "live", fact: fact({ text: `short message ${i}` }, i) },
        { kind: "value", scope, domain: "delivery", fact: fact({ receipt: i }, i) },
        { kind: "value", scope, domain: "capabilities", fact: fact(menu(i), i) },
      ]);
      await Promise.resolve();
    }
    expect(received).toHaveLength(6);
    expect(received.flatMap(part => part.domains).filter(row => row.domain === "execution").map(row => row.revision)).toEqual([1, 2, 3]);
    expect(received.flatMap(part => part.domains).filter(row => row.domain === "live").map(row => row.revision)).toEqual([1, 2, 3]);
    expect(received.flatMap(part => part.domains).filter(row => row.domain === "delivery").map(row => row.revision)).toEqual([1, 2, 3]);
    writable = true;
    subscriptions.notifyWritable("a");
    await Promise.resolve();
    expect(received.at(-1)).toMatchObject({ domains: [{ domain: "capabilities", revision: 3 }] });
    subscriptions.close();
  });
  it.each(["unsubscribe", "replace", "clear", "close"] as const)("does not send stale pending state after %s", async action => {
    const registry = new AgentStateRegistry();
    const received: AgentStateSnapshot[] = [];
    let writable = false;
    const subscriptions = new AgentStateSubscriptions(registry, (_device, message) => { received.push(snapshot(message)); }, undefined, () => writable);
    subscriptions.register("a", scope, subscribe("old", ["capabilities"]));
    registry.commitValue(scope, "capabilities", fact(menu(1)));
    await Promise.resolve();
    if (action === "unsubscribe") subscriptions.register("a", scope, { ...subscribe("old", ["capabilities"]), subscribe: false });
    else if (action === "replace") subscriptions.register("a", scope, subscribe("new", ["capabilities"]));
    else if (action === "clear") subscriptions.clearDevice("a");
    else subscriptions.close();
    writable = true;
    subscriptions.notifyWritable("a");
    await Promise.resolve();
    expect(received).toEqual([]);
    if (action === "replace") {
      registry.commitValue(scope, "capabilities", fact(menu(2), 2));
      await Promise.resolve();
      expect(received[0]).toMatchObject({ requestId: "new", domains: [{ revision: 2 }] });
    }
    subscriptions.close();
  });
  it("revisits only the device named by a writable notification", async () => {
    const registry = new AgentStateRegistry();
    const received: Array<{ device: string; message: AgentStateSnapshot }> = [];
    const writable = new Set<string>();
    const canSend = vi.fn((device: string) => writable.has(device));
    const subscriptions = new AgentStateSubscriptions(registry, (device, message) => { received.push({ device, message: snapshot(message) }); }, undefined, canSend);
    for (const device of ["a", "b"]) subscriptions.register(device, scope, subscribe(device, ["capabilities"]));
    registry.commitValue(scope, "capabilities", fact(menu(1)));
    await Promise.resolve();
    canSend.mockClear();
    writable.add("a");
    subscriptions.notifyWritable("a");
    await Promise.resolve();
    expect(received.map(row => row.device)).toEqual(["a"]);
    expect(canSend.mock.calls.every(([device]) => device === "a")).toBe(true);
    writable.add("b");
    subscriptions.notifyWritable("b");
    await Promise.resolve();
    expect(received.map(row => row.device)).toEqual(["a", "b"]);
    subscriptions.close();
  });
  it("keeps the sent baseline when sending synchronously commits a newer revision", async () => {
    const registry = new AgentStateRegistry();
    const received: AgentStateSnapshot[] = [];
    registry.commitValue(scope, "capabilities", fact(menu(1)));
    const subscriptions = new AgentStateSubscriptions(registry, (_device, message) => {
      received.push(snapshot(message));
      if (received.length === 1) registry.commitValue(scope, "capabilities", fact(menu(3), 3));
    });
    subscriptions.register("a", scope, subscribe("r", ["capabilities"]));
    registry.commitValue(scope, "capabilities", fact(menu(2), 2));
    await Promise.resolve(); await Promise.resolve();
    expect(received).toHaveLength(2);
    expect(received[1]!.domains[0]!.delta?.baseRevision).toBe(2);
    expect(applyStateDelta(menu(2), received[1]!.domains[0]!.delta!.operations)).toEqual(menu(3));
    subscriptions.close();
  });
  it("preserves a newer dirty revision of a later snapshot part during an earlier send", async () => {
    const registry = new AgentStateRegistry();
    const received: AgentStateSnapshot[] = [];
    for (const domain of ["capabilities", "resources"] as const) registry.commitValue(scope, domain, fact(menu(1, 300_000)));
    const subscriptions = new AgentStateSubscriptions(registry, (_device, message) => {
      received.push(snapshot(message));
      if (received.length === 1) registry.commitValue(scope, "resources", fact(menu(3, 300_000), 3));
    });
    subscriptions.register("a", scope, subscribe("r", ["capabilities", "resources"]));
    registry.commitTransaction([
      { kind: "value", scope, domain: "capabilities", fact: fact(menu(2, 300_000), 2) },
      { kind: "value", scope, domain: "resources", fact: fact(menu(2, 300_000), 2) },
    ]);
    await Promise.resolve(); await Promise.resolve();
    expect(received.map(part => part.domains.map(row => [row.domain, row.revision]))).toEqual([
      [["capabilities", 2]], [["resources", 2]], [["resources", 3]],
    ]);
    const final = received[2]!.domains[0]!;
    expect(final.delta?.baseRevision).toBe(2);
    expect(applyStateDelta(menu(2, 300_000), final.delta!.operations)).toEqual(menu(3, 300_000));
    subscriptions.close();
  });
});
