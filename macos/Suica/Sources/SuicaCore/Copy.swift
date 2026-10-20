import Foundation

/// Every string the app shows. English only; Teams messages are not part of the app.
public enum Copy {
    public static let appName = "Suica"
    public static let running = "Polling"
    public static let paused = "Paused"
    public static func tracked(_ count: Int) -> String { "\(count) of your MRs are tracked" }
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
        "Sent to Teams as Markdown: bold, italic, strikethrough, links, emoji and GIFs work. Messages already waiting keep the text they were written with."
    public static let teamsMessagesSection = "Teams messages"
    public static let alertsSection = "Your notifications"
    public static let alertNeedsTitle = "Write a title on the first line."
    public static let alertNeedsBody = "Write a body under the title."
    public static let templateEmptyVariant = "A variant is empty: write it or remove it."
    public static let alertTitleField = "Title"
    public static let alertBodyField = "Body"
    public static let alertHint =
        "Shown by macOS as plain text: emoji and :shortcodes: work, Markdown does not. Long text is cut to one line."
    public static let alertPreviewHeading = "As the notification will look"
    public static let alertPreviewNote = "Preview with sample values."
    public static let formatBold = "Bold"
    public static let formatItalic = "Italic"
    public static let formatStrikethrough = "Strikethrough"
    public static let formatLink = "Link…"
    public static let formatLinkPrompt = "Link address (https://…)"
    public static let formatLinkAdd = "Add link"
    public static let formatLinkRemove = "Remove link"
    public static let formatEmoji = "Emoji"
    public static let formatEmojiMore = "All emoji & symbols…"
    public static let formatEmojiHint = "Typing a :shortcode: such as :tada: turns into the emoji."
    public static let formatGIF = "GIF…"
    public static let viewVisual = "Visual"
    public static let viewMarkdown = "Markdown"
    public static let visualUnavailable =
        "This template uses Markdown the visual editor cannot show without changing it, so it opens as Markdown. Remove that syntax to edit it visually."
    public static let variantsHeading = "Variants"
    public static let variantsHelp =
        "Each message uses one variant, picked per message, so repeated chats do not read the same."
    public static func variantLabel(_ index: Int) -> String { "\(index + 1)" }
    public static let variantAdd = "Add a variant"
    public static let variantRemove = "Remove this variant"
    public static let gifTitle = "Add a GIF"
    public static let gifURL = "GIF link (https://…)"
    public static let gifAlt = "Short description"
    public static let gifAltPlaceholder = "celebrating penguin"
    public static let gifInsert = "Add GIF"
    public static let gifRecent = "Recently used"
    public static let gifLoading = "Loading the GIF…"
    public static let gifNotHTTPS = "Use an https link to the image itself, such as one ending in .gif."
    public static let gifNotImage = "That link did not return an image."
    public static let gifTooLarge = "That image is larger than 5 MB."
    public static let gifHint =
        "Copy a GIF's own link from GIPHY, Tenor or anywhere else (right-click the GIF → Copy Image Address). Teams shows it if it can load it."
    public static let imageNotLoaded = "Image not loaded"
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
        case "notice.refindings": "Review Notice: Agent Re-review findings"
        case "notice.reapproved": "Review Notice: Agent Re-review approved"
        case "alert.review-requested": "Review requested"
        case "alert.activity": "Activity on your MR"
        case "alert.summary": "Several at once"
        case "alert.baseline": "Agent started"
        case "alert.rereview": "Re-review Nudge waiting"
        case "alert.review-ready": "Agent Review ready"
        case "alert.review-posted": "Agent Review posted"
        case "alert.review-approved": "Agent Review posted and approved"
        case "alert.review-post-failed": "Agent Review not posted"
        case "alert.review-failed": "Agent Review failed"
        case "alert.review-skipped": "Agent Review skipped"
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
        case "notice.refindings":
            "To the Author, after an Agent Re-review is posted on their MR, with its new findings per severity."
        case "notice.reapproved":
            "To the Author, after an Agent Re-review is posted and the agent approved their MR (review.approve)."
        case "alert.review-requested": "To you, when someone adds you as a Reviewer."
        case "alert.activity": "To you, when someone reviews or comments on your MR."
        case "alert.summary":
            "To you, instead of the others, when one poll has more than notifications.summaryThreshold of them."
        case "alert.baseline": "To you, the first time the agent polls, with how many MRs wait for your review."
        case "alert.rereview": "To you, when a Re-review Nudge waits for your approval after you pushed."
        case "alert.review-ready": "To you, when an Agent Review is ready for you to check and post."
        case "alert.review-posted": "To you, when an Agent Review was posted automatically (review.post: auto)."
        case "alert.review-approved": "To you, when an Agent Review was posted automatically and the agent approved the MR."
        case "alert.review-post-failed": "To you, when posting an Agent Review automatically failed."
        case "alert.review-failed": "To you, when an Agent Review run failed."
        case "alert.review-skipped": "To you, when an Agent Review run was skipped."
        default: ""
        }
    }
    /// The short label a placeholder chip shows in the visual editor.
    public static func placeholderChip(_ name: String) -> String {
        switch name {
        case "mr.link": "MR link"
        case "mr.title": "MR title"
        case "mr.url": "MR address"
        case "mr.iid": "MR number"
        case "mr.project": "Project"
        case "person.name": "Recipient"
        case "person.firstName": "First name"
        case "owner.name": "You"
        case "agent.name": "Agent"
        case "review.findings": "Findings"
        case "time.greeting": "Greeting"
        default: name
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
        case "agent.name": "The agent's name (teams.agentName)"
        case "review.findings": "What the Agent Review found, per severity (findings notices only)"
        case "person.firstName": "The recipient's first name"
        case "time.greeting": "pagi, siang, sore or malam, by the time the message is written"
        case "author.name": "The MR's Author"
        case "activity.summary": "Who approved, asked for changes or commented"
        case "alert.count": "How many"
        case "alert.titles": "The first three titles, then how many more"
        case "reviewers.names": "The Reviewers waiting for a Re-review Nudge"
        case "review.reason": "Why the run failed or was skipped"
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
    public static let cancelReview = "Cancel review"
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
        case "queued": "Queued: starts in a few seconds"
        case "running": "Reviewing…"
        case "ready": "Ready: read it, then post or discard"
        case "posting": "Posting…"
        case "posted": "Posted to GitLab"
        case "discarded": "Discarded"
        case "failed": "Failed"
        case "skipped": "Skipped"
        case "cancelled": "Cancelled"
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
    public static let agentRereviewLabel = "Re-review"
    public static let rereviewNow = "Re-review"
    public static let readyToApprove = "Ready to approve: only minor findings left"
    /// The list's badge for an MR that changed since the agent's posted review.
    public static func changedSinceReview(_ change: ChangedSinceReview) -> String {
        switch (change.code, change.description) {
        case (true, true): "Code and description changed since review"
        case (true, false): "Code changed since review"
        default: "Description changed since review"
        }
    }
    /// The row's line on why an automatic re-review has not run; nil for a reason this app does not know.
    public static func rereviewWaiting(_ waiting: RereviewWaiting, dueTime: String?) -> String? {
        switch waiting.reason {
        case "waiting": dueTime.map { "Auto re-review due at \($0)" } ?? "Auto re-review waits after the last push"
        case "daily-cap": "Auto re-review held: daily review cap reached"
        case "approved": "No auto re-review: approved"
        case "draft": "No auto re-review while it is a draft"
        default: nil
        }
    }
    // Agent Review activity (Overview and menu bar)
    public static let agentReviewHeading = "Agent Review"
    public static let reviewingNow = "Reviewing now"
    public static let notReviewing = "Not reviewing anything right now."
    public static let activityHeading = "What the agent is doing"
    public static let activityStarting = "Starting…"
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
        case "queued": "Review queued. It starts in a few seconds."
        case "already-queued": "A review of this MR is already queued or running."
        case "posted": "Review posted to GitLab."
        case "discarded": "Review discarded."
        case "cancelled": "Review cancelled."
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
    public static let peopleIReview = "People you review"
    public static let peopleWhoReviewMe = "Your reviewers"
    public static let slowestApprovals = "Slowest approvals"
    public static let last90Days = "Last 90 days"
    public static let peopleIReviewHint =
        "The authors of the MRs you reviewed, by how many of their MRs you reviewed. Counted from this version of Suica on."
    public static let peopleWhoReviewMeHint = "The people who reviewed your MRs, by how many of your MRs they reviewed."
    public static let slowestApprovalsHint =
        "Your MRs by the time from opening to the first approval, as the agent saw it. Counted from this version of Suica on."
    public static func mergeRequestCount(_ n: Int) -> String { n == 1 ? "1 MR" : "\(n) MRs" }
    public static func approvedBy(_ name: String) -> String { "First approved by \(name)" }
    public static func openedOn(_ date: String) -> String { "opened \(date)" }
    /// A wait: minutes up to a day, then days and hours.
    public static func duration(_ m: Int) -> String {
        guard m >= 24 * 60 else { return minutes(m) }
        let days = m / (24 * 60)
        let hours = m % (24 * 60) / 60
        return hours == 0 ? "\(days) d" : "\(days) d \(hours) h"
    }
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
    public static func recentHeading(_ count: Int) -> String { "Recent (\(count))" }

    // MARK: Menu bar panel

    public static func polled(_ relative: String) -> String { "polled \(relative)" }
    public static let panelLists = "List"
    public static func needsYouTab(_ count: Int) -> String { "Needs you · \(count)" }
    public static func recentTab(_ count: Int) -> String { "Recent · \(count)" }
    public static let recentEmpty = "Nothing was sent or skipped lately."
    // MARK: Overview widgets

    public static let openLogs = "Open logs"

    // MARK: Logs

    public static let logs = "Logs"
    public static let logOutput = "Output"
    public static let logErrors = "Errors"
    public static let searchLogs = "Search the log"
    public static let logEmpty = "Nothing logged yet."
    public static let logNoMatches = "No entries match the search."
    public static func logMissing(_ file: String) -> String { "\(file) does not exist yet." }
    public static func logTruncated(_ entries: Int) -> String { "Showing the latest \(entries) entries at most." }
    public static func logReadFailed(_ reason: String) -> String { "Could not read the log: \(reason)" }
    public static let logFolderUnknown = "The logs folder is not known until the agent's status loads."
    public static let editConfig = "Edit config"
    public static let readyToApproveShort = "Ready to approve"
    public static let readyToApproveCaption = "Only minor findings left"
    public static let tokensToday = "Tokens today"
    public static let waitingForReviewHeading = "Waiting for your review"
    public static let agentReviewShort = "Agent review"
    public static let readyToPostHeading = "Ready to post"
    public static let reviewSettings = "Settings"
    public static let weekHeading = "Last 7 days"
    public static let tokensHeading = "Tokens"
    public static let systemHeading = "System"
    public static func allItems(_ count: Int) -> String { "All \(count) →" }
    public static func linkTo(_ title: String) -> String { "\(title) →" }
    public static func moreInMessages(_ count: Int) -> String { "\(count) more in Messages" }
    public static func weekSummary(requests: Int, nudges: Int, pollSuccess: Double?) -> String {
        let polls = pollSuccess.map { " · \(Int(($0 * 100).rounded()))% of polls ok" } ?? ""
        return "\(requests) review requests · \(nudges) nudges sent\(polls)"
    }
    public static func tokenTotals(day: String, week: String, month: String) -> String {
        "24 h \(day) · 7 d \(week) · 30 d \(month)"
    }
    public static let pauseShort = "Pause"
    public static let resumeShort = "Resume"
    public static let reviewsShort = "Reviews"
    public static let openShort = "Open"

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

    // Appearance
    public static let appearance = "Appearance"
    public static let settingsMenu = "Settings…"
    public static let goMenu = "Go"
    public static let workGroup = "Work"
    public static let insightsGroup = "Insights"
    public static let settingsGroup = "Settings"
    public static let accentHeading = "Accent colour"
    public static let accentHint = "Buttons, selections, links and highlights in the popover and this window."
    public static let lookHeading = "Look"
    public static let modeHeading = "Light or dark"
    public static let densityHeading = "Density"
    public static let densityHint = "Compact fits more rows and cards on screen."
    public static let motionHeading = "Animation"
    public static let motionHint = "Full slides, springs and bounces. Fades only and Off keep things still."
    public static let systemReducesMotion =
        "Reduce motion is on in System Settings → Accessibility → Display, so the app only fades."
    public static let menuBarHeading = "Menu bar"
    public static let menuBarBadgePicker = "Beside the icon"
    public static let menuBarBadgeHint = "Shown while messages need you."
    public static let popoverCounters = "Show quick actions in the popover"
    public static let startPagePicker = "Open the window on"
    public static let windowHeading = "Window"
    public static let resetAppearance = "Restore defaults"
    public static let appearanceNote =
        "These choices belong to this app on this Mac. They apply at once and are not part of the agent's config file."
    public static let previewHeading = "Preview"
    public static let previewSample = "A sample tile in the chosen colour"
    public static func openSection(_ title: String) -> String { "Open \(title)" }

    public static func title(_ value: MenuBarIcon) -> String {
        switch value {
        case .penguin: "Penguin"
        case .watermelon: "Watermelon"
        case .emoji: "Emoji"
        }
    }
    public static func title(_ value: Backdrop) -> String {
        switch value {
        case .plain: "Plain"
        case .wash: "Accent wash"
        case .sunrise: "Sunrise"
        case .lagoon: "Lagoon"
        case .watermelon: "Watermelon"
        case .aurora: "Aurora"
        }
    }
    public static func title(_ value: SoundEffect) -> String {
        switch value {
        case .off: "Off"
        case .pop: "Pop"
        case .glass: "Glass"
        case .purr: "Purr"
        case .hero: "Hero"
        case .tink: "Tink"
        case .submarine: "Submarine"
        }
    }
    public static func title(_ value: AppearancePreset) -> String {
        switch value {
        case .classic: "Classic"
        case .watermelonParty: "Watermelon party"
        case .midnight: "Midnight"
        case .sunrise: "Sunrise"
        case .zen: "Zen"
        }
    }
    public static let presetsHeading = "Presets"
    public static let presetsHint = "One click sets several choices below; change any of them afterwards."
    public static let customColor = "Your colour"
    public static let menuBarIconPicker = "Icon"
    public static let menuBarEmojiField = "Emoji"
    public static let menuBarEmojiHint = "Type or pick one emoji (⌃⌘Space opens the emoji picker)."
    public static let backdropHeading = "Backdrop"
    public static let backdropHint = "A soft wash behind the window's pages and the top of the popover. Aurora drifts slowly with full motion."
    public static let funHeading = "Fun"
    public static let celebrationsToggle = "Confetti when you send, approve or reach inbox zero"
    public static let celebrationsNoMotion = "Confetti needs motion: it is off while Motion is Off or the system reduces motion."
    public static let soundPicker = "Sound"
    public static let soundHint = "Played for the same moments, at the system's alert volume."
    public static let celebrateTry = "Try it"
    public static let inboxZero = "Inbox zero! 🎉"
    public static func title(_ value: AccentTheme) -> String {
        switch value {
        case .glacier: "Glacier"
        case .system: "System"
        case .suica: "Suica green"
        case .tangerine: "Tangerine"
        case .watermelon: "Watermelon"
        case .grape: "Grape"
        case .graphite: "Graphite"
        case .custom: "Custom"
        }
    }

    public static func title(_ value: AppearanceMode) -> String {
        switch value {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public static func title(_ value: Density) -> String {
        switch value {
        case .comfortable: "Comfortable"
        case .compact: "Compact"
        }
    }

    public static func title(_ value: MotionLevel) -> String {
        switch value {
        case .full: "Full"
        case .reduced: "Fades only"
        case .off: "Off"
        }
    }

    public static func title(_ value: MenuBarBadge) -> String {
        switch value {
        case .count: "Number"
        case .dot: "Dot"
        case .hidden: "Nothing"
        }
    }
}
