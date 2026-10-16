/// Every string the app shows. English only; Teams messages are not part of the app.
public enum Copy {
    public static let appName = "Suica"
    public static let running = "Polling"
    public static let paused = "Paused"
    public static func tracked(_ count: Int) -> String { "\(count) of your MRs are tracked" }
    public static func waitingForYou(_ count: Int) -> String {
        "\(count) MRs are waiting for your review"
    }
    public static let attentionHeading = "Needs your attention"
    public static let recentHeading = "Recent"
    public static let attentionEmpty = "Nothing is waiting for you."
    public static func moreHidden(_ count: Int) -> String {
        "and \(count) more (see suica pending --all)"
    }
    public static let teamsDisabled = "Teams is off. Set teams.enabled to true in the config."
    public static let send = "Send…"
    public static let skip = "Skip"
    public static let retry = "Retry"
    public static let pause = "Pause polling"
    public static let resume = "Resume polling"
    public static let refresh = "Refresh"
    public static let quit = "Quit"
    public static func confirmTitle(_ name: String) -> String { "Send this message to \(name)?" }
    public static let confirmSend = "Send"
    public static let confirmCancel = "Cancel"
    public static let maybeSent = "May have been delivered: check Teams"
    public static let notRetried = "Not retried automatically"
    public static let needsPeople = "Add this person to teams.people, then Retry"
    public static let agentUnreachable =
        "Can't reach the agent. Check that the repository and Node still exist, then Refresh."
    public static let agentTimedOut = "The agent took too long to answer."
    public static let agentOutdated = "The agent speaks a newer protocol. Rebuild the app."

    // MARK: Window

    public static let openWindow = "Open Suica…"
    public static let overview = "Overview"
    public static let messages = "Messages"
    public static let statistics = "Statistics"
    public static let configuration = "Configuration"
    public static let agentRunning = "Agent running"
    public static let agentStopped = "Agent installed but not running"
    public static let agentNotInstalled = "Agent not installed. Run scripts/install-launchagent.sh."
    public static func lastPoll(_ relative: String, ok: Bool) -> String {
        "Last poll \(relative): \(ok ? "ok" : "failed")"
    }
    public static let noPollYet = "No poll recorded yet."
    public static let restartAgent = "Restart agent"
    public static let restartFailed = "Restarting the agent failed."
    public static let restartToApply = "Saved. Restart the agent to apply the changes."
    public static let save = "Save"
    public static let discard = "Discard changes"
    public static let reload = "Reload"
    public static let resetToDefault = "Use default"
    public static let configConflict =
        "The config file changed on disk. Reload to see it; your edits are kept until then."
    public static let configBadRequest = "This version of the app doesn't match the agent. Rebuild the app."
    public static let configSaveFailed = "Saving failed. The config file was not changed."
    public static let openConfig = "Open config in editor"
    public static let openTemplates = "Open templates folder"
    public static let revealInFinder = "Show in Finder"

    // MARK: Statistics

    public static let polls24h = "Polls, last 24 hours"
    public static let reviewRequests = "Review requests"
    public static let activity = "Activity on your MRs"
    public static let nudgesSent = "Nudges sent"
    public static let noticesSent = "Review notices sent"
    public static let ownerTurnaround = "Your time to review"
    public static let reviewerTurnaround = "Reviewers' time after a nudge"
    public static let noData = "Not enough data yet"
    public static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    public static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "nudge": "Nudge"
        case "reminder": "Reminder"
        case "notice": "Review notice"
        default: kind
        }
    }

    public static func flash(for code: String) -> String {
        switch code {
        case "sent": "Message sent."
        case "busy": "Another process is already sending this message."
        case "obsolete": "Skipped: the message is no longer needed."
        case "unresolved": "Couldn't find this person in Teams. Add them to teams.people, then Retry."
        case "failed": "Sending failed and will not be retried automatically."
        case "retry-later": "Teams is unreachable. The message is still waiting."
        case "lookup-error": "The Teams lookup failed. Add this person to teams.people."
        case "not-pending": "This message is no longer waiting for approval."
        case "not-found": "Message not found."
        case "skipped": "Message skipped."
        case "retried": "Message queued again."
        case "restarted": "Agent restarted."
        case "not-installed": agentNotInstalled
        case "nothing": "Nothing to do."
        default: "Done."
        }
    }
}
