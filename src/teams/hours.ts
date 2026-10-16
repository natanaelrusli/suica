import type { Config } from "../config.ts";

type WorkingHours = Config["teams"]["workingHours"];

function minutesOfDay(clock: string): number {
  const match = /^(\d\d):(\d\d)$/.exec(clock);
  return Number(match?.[1]) * 60 + Number(match?.[2]);
}

/** Local time of the Mac. Days are ISO numbers: Monday is 1, Sunday is 7. */
export function isWithinWorkingHours(now: Date, hours: WorkingHours): boolean {
  const isoDay = now.getDay() === 0 ? 7 : now.getDay();
  if (!hours.days.includes(isoDay)) return false;
  const current = now.getHours() * 60 + now.getMinutes();
  return current >= minutesOfDay(hours.start) && current < minutesOfDay(hours.end);
}
