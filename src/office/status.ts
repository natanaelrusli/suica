import { IDLE_AFTER_MS, type OfficeStatus, type RecentAction } from "./types.ts";

export interface ActivityFacts {
  readonly now: number;
  readonly lastActivityAt: number;
  /** The log says the agent waits for the Owner (a permission, a question). */
  readonly waiting?: boolean;
  /** The log says the agent finished its turn. */
  readonly finished?: boolean;
}

/** For agents that report no status themselves: derive it from the log's last activity. */
export function classifyByActivity(facts: ActivityFacts): OfficeStatus {
  if (facts.waiting === true) return "waiting";
  if (facts.finished === true) return "idle";
  return facts.now - facts.lastActivityAt > IDLE_AFTER_MS ? "idle" : "working";
}

/** A tool call made this recently is shown; older, and the agent is thinking about the result. */
const FRESH_TOOL_MS = 20_000;

/** The bubble's text: the current tool call while working, the pending one while waiting. */
export function activityFor(
  status: OfficeStatus,
  actions: readonly RecentAction[],
  now: number,
): string {
  const last = actions.at(-1);
  if (status === "working") {
    return last !== undefined && now - last.at <= FRESH_TOOL_MS ? last.text : "Thinking";
  }
  return status === "waiting" ? (last?.text ?? "") : "";
}
