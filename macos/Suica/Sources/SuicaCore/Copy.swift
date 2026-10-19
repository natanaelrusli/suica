import Foundation

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
    public static let teamsPreviewHeading = "As it will look in Teams"
    // Message templates
    public static let messageTemplates = "Message templates"
    public static let templateSaved = "Template saved. Restart the agent to use it for new messages."
    public static let templateReset = "Built-in template restored. Restart the agent to use it for new messages."
    public static let templateNotSaved = "The template was not saved."
    public static let templateCustom = "Custom"
    public static let templateBuiltIn = "Built-in"
    public static let templateResetToDefault = "Use built-in"
    public static let templateRevert = "Revert"
    public static let templateInsert = "Insert placeholder"
    public static let templateHint =
        "Sent to Teams as Markdown: **bold**, [text](url) and line breaks work. Messages already waiting keep the text they were written with."
    public static func templatePreviewNote(_ recipient: String) -> String {
        "Preview with a sample MR and \(recipient) as the recipient."
    }
    public static func templateUnknown(_ names: [String]) -> String {
        "Unknown placeholder\(names.count == 1 ? "" : "s"): \(names.map { "{{\($0)}}" }.joined(separator: ", ")). The agent would refuse to start with it."
    }
    public static func templateTitle(_ name: String) -> String {
        switch name {
        case "nudge": "Nudge"
        case "reminder": "Reminder"
        case "rereview": "Re-review Nudge"
        case "notice.approved": "Review Notice: approved"
        case "notice.changes": "Review Notice: changes requested"
        case "notice.comments": "Review Notice: comments"
        case "notice.findings": "Review Notice: Agent Review findings"
        default: name
        }
    }
    public static func templateWhen(_ name: String) -> String {
        switch name {
        case "nudge": "To a Reviewer of your MR, asking them to review it."
        case "reminder": "To a Reviewer who has not reviewed yet, teams.reminderAfterHours after the nudge."
        case "rereview": "To a Reviewer who already reviewed, after you push new commits."
        case "notice.approved": "To the Author, after you approve their MR."
        case "notice.changes": "To the Author, after you request changes."
        case "notice.comments": "To the Author, after you leave comments."
        case "notice.findings": "To the Author, after an Agent Review is posted on their MR, with its findings per severity."
        default: ""
        }
    }
    public static func placeholderHelp(_ name: String) -> String {
        switch name {
        case "mr.link": "The MR title as a link to the MR"
        case "mr.title": "The MR title"
        case "mr.url": "The MR's address"
        case "mr.iid": "The MR number"
        case "mr.project": "The project path"
        case "person.name": "The recipient's name"
        case "owner.name": "Your name"
        case "review.findings": "What the Agent Review found, per severity (findings notice only)"
        default: name
        }
    }
    public static let teamsChatSubtitle = "Chat"
    public static let teamsNow = "Now"
    public static let confirmCancel = "Cancel"
    public static let maybeSent = "May have been delivered: check Teams"
    public static let notRetried = "Not retried automatically"
    public static let needsPeople = "Add this person to teams.people, then Retry"
    public static let agentUnreachable =
        "Can't reach the suica CLI. Check that it is still installed (scripts/install-cli.sh), then Refresh."
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
    public static let agentNotInstalled = "Agent not installed. Run suica agent install."
    public static func lastPoll(_ relative: String, ok: Bool) -> String {
        "Last poll \(relative): \(ok ? "ok" : "failed")"
    }
    public static let noPollYet = "No poll recorded yet."
    public static let restartAgent = "Restart agent"
    public static let restartFailed = "Restarting the agent failed."
    public static let restartToApply = "Saved. Restart the agent to apply the changes."
    public static let save = "Save"
    public static let discard = "Discard changes"
    public static let unsavedChanges = "You have unsaved changes."
    public static let fixInvalidInput = "Fix the fields marked in red before saving."
    public static let reload = "Reload"
    public static let resetToDefault = "Use default"
    public static let configConflict =
        "The config file changed on disk. Reload to see it; your edits are kept until then."
    public static let configBadRequest = "This version of the app doesn't match the agent. Rebuild the app."
    public static let configSaveFailed = "Saving failed. The config file was not changed."
    public static let configInvalid = "The config has problems. Nothing was saved."
    public static let openConfig = "Open config in editor"
    public static let openTemplates = "Open templates folder"
    public static let revealInFinder = "Show in Finder"

    public static let storage = "Storage"
    public static let addItem = "Add"
    public static let removeItem = "Remove"
    public static let username = "Username"
    public static let email = "Email"
    public static let invalidNumber = "Enter a whole number."
    public static let invalidClock = "Use the 24-hour format HH:MM, for example 09:30."
    public static let unsetInFile = "Not set in the file."
    public static let readOnlyField = "This setting can't be edited here."
    public static let configMissing = "No config file yet. Saving creates it."
    public static let configIssuesHeading = "The config on disk has problems"
    public static let defaultOption = "Default"
    public static let teamsOn = "Teams is on"
    public static let teamsOff = "Teams is off"
    public static func needsAttention(_ count: Int) -> String { "\(count) need your attention" }
    public static func pid(_ pid: Int) -> String { "pid \(pid)" }
    public static func pollIntervals(active: Int, idle: Int) -> String {
        "Every \(active) s while MRs are active, \(idle) s when idle"
    }
    public static let agentHeading = "Background agent"
    public static let pollingHeading = "GitLab polling"
    public static let filesHeading = "Files"
    public static let configPath = "Config file"
    public static let statePath = "State database"
    public static let logsPath = "Logs folder"
    public static let templatesPath = "Templates folder"
    public static func pollsOkFailed(ok: Int, failed: Int) -> String { "\(ok) ok / \(failed) failed" }
    public static func p90(_ text: String) -> String { "90th percentile \(text)" }
    public static func median(_ text: String) -> String { "Median \(text)" }
    public static let pollHealth = "Poll health"
    public static let last24Hours = "Last 24 hours"
    public static let last7Days = "Last 7 days"
    public static let turnaroundHeading = "Turnaround, last 30 days"
    public static let last14Days = "Last 14 days"
    public static let chartTitle = "Daily counts, last 14 days"
    public static let chartDay = "Day"
    public static let chartCount = "Count"
    public static let chartSeries = "Series"
    public static let loading = "Loading…"
    public static let agentStoppedShort = "Stopped"
    public static let agentRunningShort = "Running"
    public static let agentMissingShort = "Not installed"
    public static let teamsOffShort = "Off"
    // Review requests
    public static let noReviewRequests = "No open merge requests are waiting for your review."
    public static let selectMergeRequest = "Select a merge request"
    public static let selectMergeRequestHint = "Its description, changes, comments and agent review show here."
    public static let allCaughtUp = "All caught up"
    public static func opened(_ relative: String) -> String { "opened \(relative)" }
    public static func updated(_ relative: String) -> String { "updated \(relative)" }
    public static let searchSettings = "Search settings"
    public static func noSettingsMatch(_ query: String) -> String { "No settings match “\(query)”" }
    public static let noSettingsMatchHint = "Search looks at each setting's name, help and key."
    public static func reviewGroup(_ group: ReviewGroup) -> String {
        switch group {
        case .waiting: "Waiting for you"
        case .reviewed: "You reviewed"
        case .drafts: "Drafts"
        case .all: "All"
        }
    }
    public static let nothingWaiting = "Nothing is waiting for your review."
    // Agent Review
    public static let agentReviewTab = "Agent review"
    public static let reviewWithAgent = "Review with agent"
    public static let reviewAgain = "Review again"
    public static let postToGitLab = "Post to GitLab…"
    public static let discardReview = "Discard"
    public static let postConfirmTitle = "Post this review to GitLab as you?"
    public static let postConfirmMessage =
        "Inline: each finding that names a line of the reviewed diff becomes a thread on that line, and the rest is one comment. As one comment: the whole review is one comment on the MR. Each is labelled as written by an agent; lines starting with / are escaped, and mentions and links are removed."
    public static let postInline = "Post inline"
    public static let postAsComment = "Post as one comment"
    public static let cancel = "Cancel"
    public static let noAgentReview =
        "The agent has not reviewed this MR. It reviews with the skill set in review.skill, read-only, on a temporary checkout, and nothing is posted until you approve it."
    public static func agentReviewStatus(_ status: String) -> String {
        switch status {
        case "queued": "Queued: starts after the agent's next poll"
        case "running": "Reviewing…"
        case "ready": "Ready: read it, then post or discard"
        case "posting": "Posting…"
        case "posted": "Posted to GitLab"
        case "discarded": "Discarded"
        case "failed": "Failed"
        case "skipped": "Skipped"
        default: status
        }
    }
    public static func agentReviewBadge(_ status: String) -> String? {
        switch status {
        case "queued": "Agent review queued"
        case "running": "Agent reviewing now"
        case "ready": "Agent review ready"
        case "posted": "Agent review posted"
        case "failed": "Agent review failed"
        default: nil
        }
    }
    public static func cliName(_ cli: String?) -> String {
        switch cli {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case let other?: other
        case nil: "the agent"
        }
    }
    public static func agentReviewMeta(cli: String?, model: String?, sha: String?) -> String {
        let who = model.map { "\(cliName(cli)) (\(DisplayText.clean($0, max: 60)))" } ?? cliName(cli)
        return sha.map { "By \(who) at commit \(String($0.prefix(8)))" } ?? "By \(who)"
    }
    // Agent Review activity (Overview and menu bar)
    public static let agentReviewHeading = "Agent Review"
    public static let reviewingNow = "Reviewing now"
    public static let notReviewing = "Not reviewing anything right now."
    public static func reviewing(_ title: String) -> String { "Reviewing \(title)" }
    public static func queuedReviews(_ count: Int) -> String { count == 1 ? "1 more queued" : "\(count) more queued" }
    public static let nextInQueue = "Next in queue"
    public static func autoReviews(_ on: Bool) -> String {
        on ? "Automatic: every MR waiting for you" : "Automatic reviews are off (review.auto)"
    }
    public static let reviewSettingSaved = "Saved. Restart the agent to apply it to the next review."
    public static let postingPicker = "Posting"
    public static let postWait = "Wait for me to post"
    public static let postAuto = "Post automatically"
    public static let postAsPicker = "Post as"
    public static let postAsCommentOption = "One comment"
    public static let postAsInlineOption = "Inline threads"
    public static let postAsHint = "Applies to automatic posting; Post to GitLab… asks each time."
    public static let reviewModelPicker = "Model"
    public static let cliDefaultModel = "CLI default"
    public static let autoPostConfirmTitle = "Post reviews to GitLab automatically?"
    public static let autoPostConfirmMessage =
        "Every review is posted as you as soon as it is written, without you reading it first. It carries the agent label; lines starting with / are escaped and mentions and links are removed."
    public static let turnOnAutoPost = "Post automatically"
    public static let otherModelsHint = "Other model names: Configuration → Agent Review → Review model."
    public static func reviewModel(_ model: String?) -> String {
        "Model: \(model.map { DisplayText.clean($0, max: 60) } ?? "CLI default")"
    }
    /// "Claude Code · opus · for 3 min".
    public static func runningLine(cli: String?, model: String?, since startedAt: Int?, now: Date = Date()) -> String {
        var parts = [cliName(cli)]
        if let model { parts.append(DisplayText.clean(model, max: 60)) }
        if let startedAt {
            let minutes = max(0, Int(now.timeIntervalSince1970 * 1000 - Double(startedAt)) / 60_000)
            parts.append(minutes < 1 ? "just started" : "for \(Self.minutes(minutes))")
        }
        return parts.joined(separator: " · ")
    }
    public static func agentReviewOutcome(_ code: String) -> String {
        switch code {
        case "queued": "Review queued. It starts after the agent's next poll."
        case "already-queued": "A review of this MR is already queued or running."
        case "posted": "Review posted to GitLab."
        case "discarded": "Review discarded."
        case "failed": "Posting failed. Check the MR in GitLab before posting again."
        case "bad-key": "This merge request key cannot be reviewed."
        default: "Nothing to do: the review changed in the meantime."
        }
    }
    // Approving
    public static let approve = "Approve…"
    public static let approveConfirmTitle = "Approve this MR on GitLab as you?"
    public static func approveConfirmMessage(sha: String) -> String {
        "Your approval is tied to commit \(sha.prefix(8)). If the author pushed after you opened the MR, nothing is approved and you are asked to look again."
    }
    public static let approveAction = "Approve"
    public static let approvedByYou = "Approved by you"
    public static let squashOnMerge = "Squash on merge"
    public static let noSquash = "No squash"
    public static func approveOutcome(_ code: String) -> String {
        switch code {
        case "approved": "Approved on GitLab."
        case "head-changed": "Not approved: the author pushed after you opened this MR. Look at the new changes, then approve again."
        case "bad-request": "This merge request or commit cannot be approved."
        default: "Approving failed. Check the MR in GitLab."
        }
    }
    public static func approvals(_ approved: Int, of total: Int) -> String { "\(approved)/\(total) approved" }
    public static func yourState(_ state: String) -> String { "You: \(reviewerState(state))" }
    public static let descriptionTab = "Description"
    public static let noDescription = "No description."
    public static func changesTab(_ count: Int) -> String { "Changes (\(count))" }
    public static func commentsTab(_ count: Int) -> String { "Comments (\(count))" }
    public static let noComments = "No comments yet."
    public static let showActivity = "Show GitLab activity"
    public static let resolved = "Resolved"
    public static let unresolved = "Unresolved"
    public static let draft = "Draft"
    public static let openInGitLab = "Open in GitLab"
    public static let diffTooLarge = "This diff is too large to show here. Open it in GitLab."
    public static let filesTruncated = "Only the first 100 files are shown. Open the MR in GitLab for the rest."
    public static let discussionsTruncated = "Only the first 100 discussions are shown."
    public static let newFile = "New"
    public static let deletedFile = "Deleted"
    public static let renamedFile = "Renamed"
    public static let reviewersHeading = "Reviewers"
    public static func byAuthor(_ name: String) -> String { "by \(name)" }
    public static func pipeline(_ status: String) -> String { "Pipeline \(status.lowercased())" }
    public static func reviewerState(_ state: String) -> String {
        switch state {
        case "APPROVED": "Approved"
        case "REQUESTED_CHANGES": "Requested changes"
        case "REVIEWED": "Reviewed"
        case "REVIEW_STARTED": "Reviewing"
        case "UNAPPROVED": "Unapproved"
        case "UNREVIEWED": "Not reviewed"
        default: state.lowercased().replacingOccurrences(of: "_", with: " ")
        }
    }
    // Messages
    public static let yourMRs = "Your MRs"
    public static let othersMRs = "Others' MRs"
    public static let yourMRsHint = "Nudges, reminders and re-review nudges to the reviewers of your merge requests."
    public static let othersMRsHint = "Review notices to the authors of merge requests you reviewed."
    public static func groupHeading(_ key: String) -> String {
        switch key {
        case "gitlab": "GitLab"
        case "polling": "Polling"
        case "notifications": "Notifications"
        case "teams": "Teams"
        case "model": "Language model"
        case "review": "Agent Review"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }
    public static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    public static let weekdayNamesLong = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]

    // MARK: Statistics

    public static let reviewRequests = "Review requests"
    public static let activity = "Activity on your MRs"
    public static let nudgesSent = "Nudges sent"
    public static let noticesSent = "Review notices sent"
    public static let ownerTurnaround = "Your time to review"
    public static let reviewerTurnaround = "Reviewers' time after a nudge"
    public static let noData = "Not enough data yet"
    public static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    // MARK: Model CLI

    public static let modelCliHeading = "Language model"
    public static let modelCliPicker = "Model CLI"
    public static let modelCliAuto = "Auto (first installed)"
    public static func notInstalled(_ name: String) -> String { "\(name) (not installed)" }
    public static func modelCliInUse(_ name: String) -> String { "In use: \(name)" }
    public static let noModelCliInstalled = "None of claude, codex or gemini is installed."
    public static func modelCliMissing(_ name: String) -> String {
        "\(name) is not installed, so nothing runs. Install it or pick another."
    }
    public static let modelCliSwitched = "Model CLI switched. Restart the agent to apply it."
    public static let modelCliNote = "Agent Review runs with Claude Code or Codex; Gemini CLI is not supported there."

    // MARK: Token usage

    public static let tokenUsage = "Token usage"
    public static let last30Days = "Last 30 days"
    public static func runs(_ count: Int) -> String { count == 1 ? "1 run" : "\(count) runs" }
    public static let inputTokens = "Input"
    public static let outputTokens = "Output"
    public static let cacheReadTokens = "Cache read"
    public static let cacheCreationTokens = "Cache write"
    public static let byPurpose = "By purpose, last 30 days"
    public static let tokensChartTitle = "Daily tokens, last 14 days"
    public static let chartTokens = "Tokens"
    public static let noTokenUsage =
        "No language model runs recorded yet. Suica writes its messages from templates; tokens appear here once Agent Review runs."
    public static func purpose(_ raw: String) -> String {
        switch raw {
        case "review": "Agent reviews"
        case "reply": "Replies"
        case "other": "Other"
        default: DisplayText.clean(raw, max: 40)
        }
    }
    /// 1234 → "1,234"; 12_345 → "12.3K"; 1_234_567 → "1.2M".
    public static func tokens(_ count: Int) -> String {
        count < 10_000
            ? count.formatted(.number.locale(Locale(identifier: "en_US")))
            : count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
    }

    // MARK: Message rows

    public static let youApprovedMr = "You approved this MR in GitLab"
    public static let trackedShort = "Tracked"
    public static let toReviewShort = "To review"
    public static let needsYouShort = "Needs you"
    public static func recentHeading(_ count: Int) -> String { "Recent (\(count))" }

    public static func outcomeLabel(_ outcome: ItemOutcome) -> String {
        switch outcome {
        case .approvedByYou: "Sent with your approval"
        case .sentAutomatically: "Sent without approval"
        case .sent: "Sent"
        case .skippedByYou: "Skipped by you"
        case .noLongerNeeded: "No longer needed"
        case .skipped: "Skipped"
        case .dryRun: "Dry run, not sent"
        case .failed: "Failed"
        }
    }

    public static func stateLabel(_ state: ItemState) -> String {
        switch state {
        case .queued: "Queued"
        case .pending: "Waiting for your approval"
        case .sending: "Sending"
        case .sent: "Sent"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .unresolved: "Person not found"
        case .dryRun: "Dry run"
        case .unknown: "Unknown"
        }
    }

    public static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "nudge": "Nudge"
        case "reminder": "Reminder"
        case "rereview": "Re-review"
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
