import { z } from "zod";

/** Native Codex goal state. Timestamps keep the app-server's original units. */
export const SessionGoalSchema = z.strictObject({
  threadId: z.string().min(1).max(256),
  objective: z.string().min(1).max(100_000),
  status: z.enum(["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"]),
  tokenBudget: z.number().int().nonnegative().nullable(),
  tokensUsed: z.number().int().nonnegative(),
  timeUsedSeconds: z.number().nonnegative(),
  createdAt: z.number().nonnegative(),
  updatedAt: z.number().nonnegative(),
});
export type SessionGoal = z.infer<typeof SessionGoalSchema>;

export const SessionGoalReadSchema = z.strictObject({ type: z.literal("session.goal.read") });
export const SessionGoalSetSchema = z.strictObject({
  type: z.literal("session.goal.set"),
  objective: SessionGoalSchema.shape.objective.optional(),
  status: z.enum(["active", "paused"]).optional(),
  tokenBudget: z.number().int().positive().nullable().optional(),
}).refine(value => value.objective !== undefined || value.status !== undefined || value.tokenBudget !== undefined,
  { message: "A goal update requires an objective, status, or token budget" });
export const SessionGoalEventSchema = z.strictObject({
  type: z.literal("session.goal"),
  goal: SessionGoalSchema.nullable(),
});
