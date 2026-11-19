import { stateDelta, type AgentStateRequest, type RelayToDeviceMessage } from "@orbis/protocol";
import { AgentStateRegistry, type RegistryChange, type StateScope } from "./agent-state-registry.js";
import { buildAgentStateSnapshotParts } from "./agent-state-snapshot.js";

type BaselineState = ReturnType<AgentStateRegistry["snapshot"]>[number]["state"];
type Subscription = { key: string; deviceId: string; request: AgentStateRequest; scope: StateScope; changed: Set<string>; baseline: Map<string, BaselineState> };
const scopeId = (scope: StateScope): string => JSON.stringify(scope);
// Match the conversation model's 256 current sessions; host/device subscriptions use separate scopes.
const MAX_AGENT_SUBSCRIPTIONS_PER_DEVICE = 256;
const REPLACEABLE_AGENT_DOMAINS = new Set(["identity", "availability", "model", "context", "permissions", "capabilities", "resources", "providerBinding", "workspaceRef"]);
// These are complete current projections. Conversation content and command receipts retain their
// immediate publication path; replacing them could hide a short message or terminal receipt.
const isReplaceable = (scope: StateScope, domain: string): boolean => scope.kind === "host"
  ? domain !== "operations" : scope.kind === "agent" && REPLACEABLE_AGENT_DOMAINS.has(domain);

/** Coalesced complete-domain publications. No I/O or source RPC occurs inside Registry commits. */
export class AgentStateSubscriptions {
  readonly #entries = new Map<string, Subscription>();
  readonly #byDevice = new Map<string, Map<string, Subscription>>();
  readonly #pending = new Map<string, Set<Subscription>>();
  readonly #scheduledDevices = new Set<string>();
  readonly #unsubscribe: () => void;
  #scheduled = false;
  #closed = false;
  /**
   * `project` adapts a domain value to what one device can parse (ADR-0076 DSH-DESKTOP-06). It runs
   * before delta computation and on the stored baseline, so a delta always moves the device's own view.
   */
  constructor(readonly registry: AgentStateRegistry, readonly send: (deviceId: string, message: RelayToDeviceMessage) => boolean | void,
    readonly project?: (deviceId: string, scope: StateScope, domain: string, value: unknown) => unknown,
    readonly canSend: (deviceId: string) => boolean = () => true) {
    this.#unsubscribe = registry.subscribe(change => this.#changed(change));
  }
  #projected<T extends { value: unknown }>(deviceId: string, scope: StateScope, domain: string, state: T): T {
    return this.project === undefined || state.value === null ? state : { ...state, value: this.project(deviceId, scope, domain, state.value) };
  }
  register(deviceId: string, scope: StateScope, request: AgentStateRequest): boolean {
    const key = JSON.stringify([deviceId, scopeId(scope)]);
    if (request.subscribe === false) { this.#remove(key); return true; }
    if (request.subscribe !== true) return true;
    // A runtime can switch Sessions without changing runtimeId. Replace its old routing subscription.
    const replaced = scope.kind === "agent" && request.runtimeId !== undefined
      ? [...this.#byDevice.get(deviceId) ?? []].filter(([entryKey, entry]) => entryKey !== key &&
        entry.scope.kind === "agent" && entry.request.runtimeId === request.runtimeId)
      : [];
    if (scope.kind === "agent" && !this.#entries.has(key) &&
        [...this.#byDevice.get(deviceId)?.values() ?? []].filter(entry => entry.scope.kind === "agent").length - replaced.length >= MAX_AGENT_SUBSCRIPTIONS_PER_DEVICE) return false;
    for (const [entryKey] of replaced) this.#remove(entryKey);
    this.#remove(key);
    const entry: Subscription = { key, deviceId, scope: structuredClone(scope), request: structuredClone(request), changed: new Set(), baseline: new Map(request.stateFormat === "compact-v2" ? this.registry.snapshot(scope).filter(({ domain }) => !request.domains || request.domains.includes(domain)).map(({ domain, state }) => [domain, this.#projected(deviceId, scope, domain, state)]) : []) };
    this.#entries.set(key, entry);
    let device = this.#byDevice.get(deviceId);
    if (!device) this.#byDevice.set(deviceId, device = new Map());
    device.set(key, entry);
    return true;
  }
  clearDevice(deviceId: string): void {
    for (const key of this.#byDevice.get(deviceId)?.keys() ?? []) this.#entries.delete(key);
    this.#byDevice.delete(deviceId);
    this.#pending.delete(deviceId);
    this.#scheduledDevices.delete(deviceId);
  }
  #remove(key: string): void {
    const entry = this.#entries.get(key);
    if (!entry) return;
    this.#entries.delete(key);
    const device = this.#byDevice.get(entry.deviceId);
    device?.delete(key);
    if (device?.size === 0) this.#byDevice.delete(entry.deviceId);
    const pending = this.#pending.get(entry.deviceId);
    pending?.delete(entry);
    if (pending?.size === 0) {
      this.#pending.delete(entry.deviceId);
      this.#scheduledDevices.delete(entry.deviceId);
    }
  }
  interestedRuntimes(domain: string): Set<string> {
    return new Set([...this.#entries.values()].filter(entry => entry.scope.kind === "agent" &&
      (entry.request.domains === undefined || entry.request.domains.includes(domain))).flatMap(entry => entry.request.runtimeId ? [entry.request.runtimeId] : []));
  }
  supportsSharedContent(deviceId: string): boolean {
    return [...this.#byDevice.get(deviceId)?.values() ?? []].some(entry => entry.request.stateFormat === "compact-v2");
  }
  interestedInCatalog(): boolean {
    return [...this.#entries.values()].some(entry => entry.scope.kind === "host" &&
      (entry.request.domains === undefined || entry.request.domains.includes("catalog")));
  }
  owns(deviceId: string, runtimeId: string, domain: string): boolean {
    return [...this.#byDevice.get(deviceId)?.values() ?? []].some(entry => entry.scope.kind === "agent" &&
      entry.request.runtimeId === runtimeId && (entry.request.domains === undefined || entry.request.domains.includes(domain)));
  }
  #changed(change: RegistryChange): void {
    if (this.#closed || change.kind === "reset") return;
    for (const entry of this.#entries.values()) {
      if (scopeId(entry.scope) !== scopeId(change.scope)) continue;
      if (entry.request.domains && !entry.request.domains.includes(change.domain)) continue;
      entry.changed.add(change.domain);
      let pending = this.#pending.get(entry.deviceId);
      if (!pending) this.#pending.set(entry.deviceId, pending = new Set());
      pending.add(entry);
      this.#schedule(entry.deviceId);
    }
  }
  /** Called after this device's transport drains. Only its dirty subscriptions are revisited. */
  notifyWritable(deviceId: string): void { this.#schedule(deviceId); }
  #schedule(deviceId: string): void {
    if (this.#closed || ![...this.#pending.get(deviceId) ?? []].some(entry => entry.changed.size > 0)) return;
    this.#scheduledDevices.add(deviceId);
    if (this.#scheduled) return;
    this.#scheduled = true;
    queueMicrotask(() => {
      this.#scheduled = false;
      if (this.#closed) return;
      const devices = [...this.#scheduledDevices];
      this.#scheduledDevices.clear();
      for (const device of devices) for (const entry of [...this.#pending.get(device) ?? []]) this.#publish(entry);
    });
  }
  #publish(entry: Subscription): void {
    if (this.#entries.get(entry.key) !== entry || entry.changed.size === 0) return;
    // A synchronous send may itself commit newer facts. Keep those in a separate set so that an
    // older part cannot consume their dirty markers or move the delta baseline past what was sent.
    const pending = entry.changed;
    entry.changed = new Set();
    const groups = [
      [...pending].filter(domain => !isReplaceable(entry.scope, domain)),
      [...pending].filter(domain => isReplaceable(entry.scope, domain)),
    ];
    for (const domains of groups) {
      if (domains.length === 0) continue;
      const replaceable = isReplaceable(entry.scope, domains[0]!);
      if (replaceable && !this.canSend(entry.deviceId)) continue;
      for (const part of buildAgentStateSnapshotParts({ registry: this.registry, scope: entry.scope,
        requestId: entry.request.requestId, identity: entry.request, domains, update: true, stateFormat: entry.request.stateFormat })) {
        if (this.#entries.get(entry.key) !== entry) return;
        if (replaceable && !this.canSend(entry.deviceId)) break;
        const baseline = new Map<string, BaselineState>();
        if (this.project !== undefined) for (const current of part.domains) {
          if (current.value !== null) current.value = this.project(entry.deviceId, entry.scope, current.domain, current.value) as typeof current.value;
        }
        if (entry.request.stateFormat === "compact-v2") for (const current of part.domains) {
          baseline.set(current.domain, { ...current });
          const old = entry.baseline.get(current.domain);
          if (old && old.modelEpoch === current.modelEpoch && old.revision < current.revision &&
            old.availability === "ready" && current.availability === "ready" &&
            old.source.producer === current.source.producer && old.source.sourceEpoch === current.source.sourceEpoch && old.source.sourceId === current.source.sourceId) {
            const operations = stateDelta(old.value, current.value);
            const delta = operations && { baseRevision: old.revision, operations };
            if (delta && Buffer.byteLength(JSON.stringify(delta)) < Buffer.byteLength(JSON.stringify(current.value)) * 0.8) {
              current.delta = delta; current.value = null;
            }
          }
        }
        if (this.send(entry.deviceId, part) === false) break;
        for (const current of part.domains) {
          pending.delete(current.domain);
          const state = baseline.get(current.domain);
          if (state) entry.baseline.set(current.domain, state);
        }
        for (const current of part.missing) { pending.delete(current.domain); entry.baseline.delete(current.domain); }
        for (const domain of part.unchanged ?? []) pending.delete(domain);
      }
    }
    if (this.#entries.get(entry.key) !== entry) return;
    for (const domain of pending) entry.changed.add(domain);
    if (entry.changed.size === 0) {
      const device = this.#pending.get(entry.deviceId);
      device?.delete(entry);
      if (device?.size === 0) this.#pending.delete(entry.deviceId);
    }
  }
  close(): void {
    this.#closed = true;
    this.#unsubscribe();
    this.#entries.clear();
    this.#byDevice.clear();
    this.#pending.clear();
    this.#scheduledDevices.clear();
  }
}
