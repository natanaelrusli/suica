import { describe, expect, it } from "vitest";
import type { ActivityEvent } from "../src/events.ts";
import {
  baselineNotifications,
  buildNotifications,
  clean,
  rereviewNotifications,
} from "../src/format.ts";
import type { HeldMessage } from "../src/teams/types.ts";
import { mr, person } from "./builders.ts";

describe("clean", () => {
  it("flattens newlines and control characters", () => {
    expect(clean("a\nb\u0007c")).toBe("a b c");
  });

  it("removes invisible formatting characters used to spoof names (bidi overrides, zero-width)", () => {
    expect(clean("a‮b​c")).toBe("a b c");
  });

  it("removes leading dashes so the text can never be read as a command-line flag", () => {
    expect(clean("--open evil")).toBe("open evil");
  });

  it("truncates by code points without splitting an emoji", () => {
    expect(clean("x".repeat(200), 10)).toBe(`${"x".repeat(9)}…`);
    expect(clean("😀".repeat(5), 3)).toBe("😀😀…");
  });
});

describe("buildNotifications", () => {
  it("describes a review request with the Author and project", () => {
    const events: ActivityEvent[] = [
      {
        kind: "review-requested",
        mr: mr(7, { title: "Add thing", author: person("alice", "Alice"), projectPath: "g/p" }),
      },
    ];
    expect(buildNotifications(events, 4)).toEqual([
      {
        title: "👀 Diminta review: Add thing",
        body: "Alice · g/p !7",
        url: "https://gitlab.example/g/p/-/merge_requests/7",
        sound: "Glass",
        actions: [
          {
            title: "Review dengan agen",
            suica: ["review", "queue", "g/p!7", "--json"],
          },
        ],
      },
    ]);
  });

  it("merges all activity on one MR into a single notification", () => {
    const target = mr(7, { title: "Add thing" });
    const events: ActivityEvent[] = [
      { kind: "reviewer-state", mr: target, reviewer: person("bob", "Bob"), to: "APPROVED" },
      { kind: "comment", mr: target, noteId: "1", author: person("carol", "Carol") },
      { kind: "comment", mr: target, noteId: "2", author: person("dave", "Dave") },
    ];
    expect(buildNotifications(events, 4)).toEqual([
      {
        title: "💬 !7 Add thing",
        body: "Bob menyetujui; 2 komentar baru dari Carol, Dave",
        url: target.url,
      },
    ]);
  });

  it("falls back to a generic phrase for an unknown review state", () => {
    const events: ActivityEvent[] = [
      { kind: "reviewer-state", mr: mr(1), reviewer: person("bob", "Bob"), to: "SOMETHING_NEW" },
    ];
    expect(buildNotifications(events, 4)[0]?.body).toBe(
      "Bob mengubah status review ke SOMETHING_NEW",
    );
  });

  it("collapses a burst into one summary above the threshold, but not at the threshold", () => {
    const requests = (count: number): ActivityEvent[] =>
      Array.from({ length: count }, (_, index) => ({
        kind: "review-requested" as const,
        mr: mr(index + 1),
      }));
    expect(buildNotifications(requests(4), 4)).toHaveLength(4);
    const summary = buildNotifications(requests(5), 4);
    expect(summary).toEqual([
      {
        title: "📬 5 aktivitas MR baru",
        body: "👀 Diminta review: MR 1 | 👀 Diminta review: MR 2 | 👀 Diminta review: MR 3 +2 lainnya",
      },
    ]);
    expect(summary[0]).not.toHaveProperty("url");
  });

  it("neutralises hostile titles and names", () => {
    const events: ActivityEvent[] = [
      {
        kind: "review-requested",
        mr: mr(1, { title: "--evil\nsecond line", author: person("x", "-n Mallory") }),
      },
    ];
    const [only] = buildNotifications(events, 4);
    expect(only?.title).toBe("👀 Diminta review: evil second line");
    expect(only?.body).toBe("n Mallory · g/p !1");
    expect(only?.title).not.toContain("\n");
  });
});

describe("baselineNotifications", () => {
  it("is silent when nothing is waiting and summarises otherwise", () => {
    expect(baselineNotifications(0)).toEqual([]);
    expect(baselineNotifications(3)).toEqual([
      { title: "🚃 Suica aktif", body: "3 MR menunggu review-mu" },
    ]);
  });
});

describe("rereviewNotifications", () => {
  const held = (id: number, name: string, overrides: Partial<HeldMessage> = {}): HeldMessage => ({
    id,
    kind: "rereview",
    mrKey: "g/p!5",
    mrTitle: "Add thing",
    recipientName: name,
    ...overrides,
  });

  it("asks about one Reviewer and opens that message when clicked", () => {
    expect(rereviewNotifications([held(12, "Bob")])).toEqual([
      {
        title: "🔁 Minta review ulang?",
        body: "Kamu push ke Add thing setelah Bob review. Kirim pesan Teams?",
        url: "suica://message/12",
        sound: "Glass",
      },
    ]);
  });

  it("makes one notification per MR, naming every Reviewer, and opens the message list", () => {
    const notifications = rereviewNotifications([
      held(1, "Bob"),
      held(2, "Carol"),
      held(3, "Dave"),
      held(4, "Erin", { mrKey: "g/p!8", mrTitle: "Other" }),
    ]);
    expect(notifications).toEqual([
      {
        title: "🔁 Minta review ulang?",
        body: "Kamu push ke Add thing setelah Bob, Carol dan Dave review. Kirim pesan Teams?",
        url: "suica://messages",
        sound: "Glass",
      },
      {
        title: "🔁 Minta review ulang?",
        body: "Kamu push ke Other setelah Erin review. Kirim pesan Teams?",
        url: "suica://message/4",
        sound: "Glass",
      },
    ]);
  });

  it("joins two Reviewers with 'dan'", () => {
    expect(rereviewNotifications([held(1, "Bob"), held(2, "Carol")])[0]?.body).toBe(
      "Kamu push ke Add thing setelah Bob dan Carol review. Kirim pesan Teams?",
    );
  });

  it("ignores messages of other kinds, and is silent when nothing was held", () => {
    expect(rereviewNotifications([held(1, "Bob", { kind: "nudge" })])).toEqual([]);
    expect(rereviewNotifications([])).toEqual([]);
  });

  it("cleans and shortens titles and names, and stays inside the body limit", () => {
    const long = "T".repeat(300);
    const names = Array.from({ length: 12 }, (_, index) => `${"N".repeat(60)}${index}`);
    const [notification] = rereviewNotifications([
      held(1, "-n Mallory\nsecond", { mrTitle: `--${long}` }),
      ...names.map((name, index) => held(2 + index, name)),
    ]);
    expect(notification?.body).not.toContain("\n");
    expect(notification?.body).not.toMatch(/T{51}/);
    expect(notification?.body).not.toMatch(/N{61}/);
    expect(notification?.body.startsWith("Kamu push ke T")).toBe(true);
    expect(notification?.body.endsWith(" review. Kirim pesan Teams?")).toBe(true);
    expect([...(notification?.body ?? "")].length).toBeLessThanOrEqual(160);
  });
});
