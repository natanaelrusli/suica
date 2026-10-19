import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import type { TokenUsageEntry } from "../src/store.ts";

const DAY = 24 * 3_600_000;
const NOW = Date.UTC(2026, 9, 16, 12);
const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDb(): string {
  const folder = mkdtempSync(join(tmpdir(), "suica-usage-"));
  folders.push(folder);
  return join(folder, "state.db");
}
function entry(at: number, overrides: Partial<TokenUsageEntry> = {}): TokenUsageEntry {
  return {
    at,
    purpose: "review",
    inputTokens: 10,
    outputTokens: 2,
    cacheReadTokens: 3,
    cacheCreationTokens: 4,
    ...overrides,
  };
}

describe("token usage", () => {
  it("records runs, returns them in order and drops rows past the 90-day retention", () => {
    const store = openStore(tempDb());
    store.recordTokenUsage(entry(NOW - 100 * DAY));
    store.recordTokenUsage(entry(NOW, { purpose: "reply" }));
    store.recordTokenUsage(entry(NOW - DAY));
    expect(store.loadTokenUsage(0)).toEqual([entry(NOW - DAY), entry(NOW, { purpose: "reply" })]);
    expect(store.loadTokenUsage(NOW)).toEqual([entry(NOW, { purpose: "reply" })]);
    store.close();
  });

  it("upgrades a schema 4 database to the current schema with an empty ledger", () => {
    const path = tempDb();
    openStore(path).close();
    const raw = new DatabaseSync(path);
    raw.exec("DROP TABLE token_usage; PRAGMA user_version = 4");
    raw.close();
    const store = openStore(path);
    expect(store.loadTokenUsage(0)).toEqual([]);
    store.close();
    const check = new DatabaseSync(path);
    expect(check.prepare("PRAGMA user_version").get()?.["user_version"]).toBe(8);
    check.close();
  });
});

describe("agent reviews", () => {
  it("marks runs cut off by a stop as failed and leaves the rest alone", () => {
    const store = openStore(tempDb());
    const running = store.queueAgentReview("g/p!1", "manual", NOW) ?? 0;
    const queued = store.queueAgentReview("g/p!2", "auto", NOW) ?? 0;
    store.transitionAgentReview(running, ["queued"], "running", {}, NOW);
    expect(store.failInterruptedAgentReviews(NOW + 1)).toBe(1);
    expect(store.getAgentReview(running)).toMatchObject({ status: "failed", updatedAt: NOW + 1 });
    expect(store.getAgentReview(running)?.detail).toMatch(/interrupted/);
    expect(store.getAgentReview(queued)?.status).toBe("queued");
    expect(store.countAgentReviews("auto", NOW)).toBe(1);
    store.close();
  });

  it("puts a post cut off more than 15 minutes ago back to ready, and leaves a live one alone", () => {
    const store = openStore(tempDb());
    const stale = store.queueAgentReview("g/p!1", "manual", NOW) ?? 0;
    const live = store.queueAgentReview("g/p!2", "manual", NOW) ?? 0;
    const minute = 60_000;
    store.transitionAgentReview(stale, ["queued"], "posting", { detail: "" }, NOW);
    store.transitionAgentReview(live, ["queued"], "posting", { detail: "" }, NOW + 5 * minute);
    expect(store.recoverStalePostings(NOW + 15 * minute)).toBe(0);
    expect(store.recoverStalePostings(NOW + 16 * minute)).toBe(1);
    expect(store.getAgentReview(stale)).toMatchObject({
      status: "ready",
      updatedAt: NOW + 16 * minute,
    });
    expect(store.getAgentReview(stale)?.detail).toMatch(
      /Check the MR in GitLab before posting again/,
    );
    expect(store.getAgentReview(live)?.status).toBe("posting");
    // The post that was cut off cannot mark it posted any more.
    expect(store.transitionAgentReview(stale, ["posting"], "posted", {}, NOW + 17 * minute)).toBe(
      false,
    );
    store.close();
  });
});

describe("schema 7", () => {
  it("adds the title, model and start columns to an agent_review table made by schema 6", () => {
    const path = tempDb();
    openStore(path).close();
    const raw = new DatabaseSync(path);
    raw.exec(`DROP TABLE agent_review;
      CREATE TABLE agent_review (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mr_key TEXT NOT NULL, trigger TEXT NOT NULL, status TEXT NOT NULL,
        cli TEXT, head_sha TEXT, body TEXT, detail TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
      );
      INSERT INTO agent_review (mr_key, trigger, status, created_at, updated_at)
        VALUES ('g/p!1', 'manual', 'posted', 1, 1);
      PRAGMA user_version = 6;`);
    raw.close();
    const store = openStore(path);
    expect(store.getAgentReview(1)).toMatchObject({
      status: "posted",
      mrTitle: null,
      model: null,
      startedAt: null,
    });
    const id = store.queueAgentReview("g/p!2", "auto", NOW, "Add thing") ?? 0;
    store.transitionAgentReview(id, ["queued"], "running", { startedAt: NOW, model: "opus" }, NOW);
    expect(store.agentReviewActivity().running).toMatchObject({
      mrTitle: "Add thing",
      model: "opus",
      startedAt: NOW,
    });
    store.close();
    const check = new DatabaseSync(path);
    expect(check.prepare("PRAGMA user_version").get()?.["user_version"]).toBe(8);
    check.close();
  });
});
