import { SessionGoalSchema, type SessionGoal } from "@orbis/protocol";
import { object } from "./codex-interactions.js";

/** Project only public goal fields; the runtime envelope already identifies the thread. */
export function codexGoal(value: unknown, threadId: string): SessionGoal | null {
  if (value === null) return null;
  const goal = object(value);
  if (goal.threadId !== threadId) throw new Error("codex_goal_thread_mismatch");
  return SessionGoalSchema.parse({
    threadId: goal.threadId,
    objective: goal.objective,
    status: goal.status,
    tokenBudget: goal.tokenBudget,
    tokensUsed: goal.tokensUsed,
    timeUsedSeconds: goal.timeUsedSeconds,
    createdAt: goal.createdAt,
    updatedAt: goal.updatedAt,
  });
}
