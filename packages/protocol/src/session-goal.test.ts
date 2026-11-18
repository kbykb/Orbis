import { describe, expect, it } from "vitest";
import { RuntimeCommandSchema, RuntimeEventSchema, RuntimeMetadataSchema } from "./index.js";

describe("session goals", () => {
  it("accepts on-demand reads and explicit user edits without native provenance fields", () => {
    for (const command of [
      { type: "session.goal.read" },
      { type: "session.goal.set", objective: "Finish the feature" },
      { type: "session.goal.set", status: "paused" },
      { type: "session.goal.set", status: "active", tokenBudget: null },
    ]) expect(RuntimeCommandSchema.parse(command)).toEqual(command);
    for (const command of [
      { type: "session.goal.set" }, { type: "session.goal.set", objective: "" },
      { type: "session.goal.set", status: "complete" }, { type: "session.goal.set", tokenBudget: 0 },
      { type: "session.goal.set", objective: "edit", origin: "automatic" },
    ]) expect(RuntimeCommandSchema.safeParse(command).success).toBe(false);
  });

  it("preserves native identity, all statuses and explicit goal absence", () => {
    const goal = { threadId: "one", objective: "Finish", tokenBudget: null, tokensUsed: 42,
      timeUsedSeconds: 10, createdAt: 1, updatedAt: 2 };
    for (const status of ["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"]) {
      expect(RuntimeEventSchema.parse({ type: "session.goal", goal: { ...goal, status } })).toEqual({ type: "session.goal", goal: { ...goal, status } });
    }
    expect(RuntimeEventSchema.parse({ type: "session.goal", goal: null })).toEqual({ type: "session.goal", goal: null });
    expect(RuntimeMetadataSchema.parse({ runtimeId: "codex:one", name: "Codex", cwd: "/work", status: "idle", goalSupported: true }).goalSupported).toBe(true);
  });
});
