import { APPROVED, UNREVIEWED } from "./domain.ts";
import type { Snapshot } from "./domain.ts";
import { myReviewState, reviewerKey } from "./events.ts";
import type { ActivityEvent, PreviousState } from "./events.ts";
import type { FirstApproval, HistoryEvent } from "./store.ts";

/**
 * The history rows for one poll, derived from what the poll already detected. `at` is stamped on
 * every row; nothing is recorded before the baseline, so the first poll never invents history.
 */
export function historyEvents(
  snapshot: Snapshot,
  previous: PreviousState,
  events: readonly ActivityEvent[],
  at: number,
): HistoryEvent[] {
  if (!previous.baselineDone) return [];
  const rows: HistoryEvent[] = [];
  for (const event of events) {
    switch (event.kind) {
      case "review-requested":
        rows.push({ kind: "review-requested", mrKey: event.mr.key, username: "", at });
        break;
      case "comment":
        rows.push({ kind: "activity", mrKey: event.mr.key, username: "", at });
        break;
      case "reviewer-state": {
        rows.push({ kind: "activity", mrKey: event.mr.key, username: "", at });
        const username = event.reviewer.username;
        const before = previous.reviewerStates.get(reviewerKey(event.mr.key, username));
        if (before === undefined || before === UNREVIEWED) {
          rows.push({ kind: "reviewer-reviewed", mrKey: event.mr.key, username, at });
        }
        break;
      }
    }
  }
  for (const mr of snapshot.reviewRequested) {
    if (mr.draft) continue;
    if (
      previous.myReviewStates.get(mr.key) === UNREVIEWED &&
      myReviewState(snapshot, mr) !== UNREVIEWED
    ) {
      rows.push({ kind: "owner-reviewed", mrKey: mr.key, username: mr.author.username, at });
    }
  }
  return rows;
}

/**
 * The approvals of the Owner's MRs this poll saw, for the slowest approvals in the statistics.
 * The store keeps only the first per MR. An MR without a usable `createdAt` is left out.
 */
export function firstApprovals(events: readonly ActivityEvent[], at: number): FirstApproval[] {
  const rows: FirstApproval[] = [];
  for (const event of events) {
    if (event.kind !== "reviewer-state" || event.to !== APPROVED) continue;
    const openedAt = Date.parse(event.mr.createdAt ?? "");
    if (Number.isNaN(openedAt)) continue;
    rows.push({
      mrKey: event.mr.key,
      title: event.mr.title,
      url: event.mr.url,
      openedAt,
      approvedAt: at,
      approver: event.reviewer,
    });
  }
  return rows;
}
