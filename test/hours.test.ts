import { describe, expect, it } from "vitest";
import { isWithinWorkingHours } from "../src/teams/hours.ts";

const hours = { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] };
// Local times: 2026-10-14 is a Wednesday, 2026-10-17 a Saturday, 2026-10-18 a Sunday.
const at = (day: number, hour: number, minute = 0): Date => new Date(2026, 9, day, hour, minute);

describe("isWithinWorkingHours", () => {
  it("includes the start minute and excludes the end minute on a working day", () => {
    expect(isWithinWorkingHours(at(14, 8, 59), hours)).toBe(false);
    expect(isWithinWorkingHours(at(14, 9, 0), hours)).toBe(true);
    expect(isWithinWorkingHours(at(14, 16, 59), hours)).toBe(true);
    expect(isWithinWorkingHours(at(14, 17, 0), hours)).toBe(false);
  });

  it("is false on days that are not listed", () => {
    expect(isWithinWorkingHours(at(17, 10), hours)).toBe(false);
    expect(isWithinWorkingHours(at(18, 10), hours)).toBe(false);
  });

  it("numbers Sunday as 7 in a custom day list", () => {
    expect(isWithinWorkingHours(at(18, 10), { ...hours, days: [7] })).toBe(true);
    expect(isWithinWorkingHours(at(17, 10), { ...hours, days: [6, 7] })).toBe(true);
  });
});
