/// The menu bar panel's two lists.
public enum PanelTab: Hashable, Sendable {
    case needsYou, recent

    /// Needs you when something waits for the Owner, Recent otherwise.
    public static func opening(badgeCount: Int) -> PanelTab { badgeCount > 0 ? .needsYou : .recent }
}

/// Why an MR is on the Overview's review widget, in the order the widget lists them.
public enum ReviewShortcutReason: Sendable {
    case readyToApprove, changed, waiting
}

/// The one button a review widget row offers.
public enum ReviewShortcutAction: Sendable {
    case agentReview, rereview, open
}

public struct ReviewShortcut: Identifiable, Equatable, Sendable {
    public let mr: ReviewSummary
    public let reason: ReviewShortcutReason

    public var id: String { mr.key }

    public var action: ReviewShortcutAction {
        if mr.offersRereview { return .rereview }
        return mr.offersReview ? .agentReview : .open
    }
}

extension ReviewListDocument {
    /// Up to `limit` non-draft MRs, one row each: ready to approve, then changed since the agent's
    /// review, then waiting for the Owner (every MR when the Owner is unknown), each in GitLab's order.
    public func shortcuts(limit: Int = 5) -> [ReviewShortcut] {
        let open = mergeRequests.filter { !$0.draft }
        let ordered: [(ReviewShortcutReason, (ReviewSummary) -> Bool)] = [
            (.readyToApprove, { $0.readyToApprove }),
            (.changed, { $0.changedSinceReview != nil }),
            (.waiting, { me == nil || (myState($0) ?? "UNREVIEWED") == "UNREVIEWED" }),
        ]
        var seen = Set<String>()
        var rows: [ReviewShortcut] = []
        for (reason, matches) in ordered {
            for mr in open where matches(mr) && seen.insert(mr.key).inserted {
                rows.append(ReviewShortcut(mr: mr, reason: reason))
            }
        }
        return Array(rows.prefix(limit))
    }

    public var readyToApproveCount: Int { mergeRequests.filter { !$0.draft && $0.readyToApprove }.count }

    /// MRs whose Agent Review waits to be posted.
    public var readyToPost: [ReviewSummary] { mergeRequests.filter { $0.agentReview?.isReady == true } }

    /// Open review requests by where they stand for the Owner; every non-draft waits without `me`.
    public var tally: ReviewTally {
        let open = mergeRequests.filter { !$0.draft }
        let waiting = open.filter { me == nil || (myState($0) ?? "UNREVIEWED") == "UNREVIEWED" }.count
        return ReviewTally(waiting: waiting, reviewed: open.count - waiting, drafts: mergeRequests.count - open.count)
    }

    /// The Owner's own open MRs: how many every Reviewer approved and how many have a fix to confirm.
    public var yourTally: YourTally {
        YourTally(
            open: yourMergeRequests.count, approved: yourMergeRequests.filter(\.approvedByAll).count,
            fixesReady: yourMergeRequests.filter { $0.fix?.status == "ready" }.count)
    }
}

public struct ReviewTally: Equatable, Sendable {
    public let waiting: Int
    public let reviewed: Int
    public let drafts: Int
}

public struct YourTally: Equatable, Sendable {
    public let open: Int
    public let approved: Int
    public let fixesReady: Int
}

/// The one word the Overview's status bar leads with, worst first.
public enum AgentHealth: Equatable, Sendable {
    case ok, pollFailed, paused, stopped, missing

    /// `lastPollOK` is nil before the first poll, which is not a failure.
    public init(running: Bool, loaded: Bool, paused: Bool, lastPollOK: Bool?) {
        if !running {
            self = loaded ? .stopped : .missing
        } else if paused {
            self = .paused
        } else {
            self = lastPollOK == false ? .pollFailed : .ok
        }
    }
}

/// The Overview's week at a glance.
public struct WeekSummary: Equatable, Sendable {
    /// Oldest first, at most seven.
    public let days: [DayStats]
    public let reviewRequests: Int
    public let nudgesSent: Int
    /// Share of the last seven days' polls that succeeded; nil without polls.
    public let pollSuccess: Double?
}

extension StatsDocument {
    public var week: WeekSummary {
        let days = Array(days.suffix(7))
        let polls = polls7d.ok + polls7d.failed
        return WeekSummary(
            days: days, reviewRequests: days.reduce(0) { $0 + $1.reviewRequests },
            nudgesSent: days.reduce(0) { $0 + $1.nudgesSent },
            pollSuccess: polls == 0 ? nil : Double(polls7d.ok) / Double(polls))
    }
}
