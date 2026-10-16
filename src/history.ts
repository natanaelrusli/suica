import { UNREVIEWED } from "./domain.ts";
import type { Snapshot } from "./domain.ts";
import { myReviewState, reviewerKey } from "./events.ts";
import type { ActivityEvent, PreviousState } from "./events.ts";
import type { HistoryEvent } from "./store.ts";

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
      rows.push({ kind: "owner-reviewed", mrKey: mr.key, username: "", at });
    }
  }
  return rows;
}
