import type { Config } from "./config.ts";

export interface DelayInput {
  readonly idleSeconds: number;
  readonly failureStreak: number;
  readonly polling: Config["polling"];
}

export function nextDelaySeconds(input: DelayInput): number {
  const { idleSeconds, failureStreak, polling } = input;
  const base =
    idleSeconds >= polling.idleAfterSeconds ? polling.idleSeconds : polling.activeSeconds;
  return Math.min(base * 2 ** failureStreak, Math.max(polling.maxBackoffSeconds, base));
}
