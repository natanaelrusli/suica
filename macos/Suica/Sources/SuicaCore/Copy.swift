import Foundation

/// Every string the app shows. English only; Teams messages are not part of the app.
public enum Copy {
    public static let appName = "Suica"
    public static let running = "Polling"
    public static let paused = "Paused"
    public static let attentionHeading = "Needs your attention"
    public static let attentionEmpty = "Nothing is waiting for you."
    public static func moreHidden(_ count: Int) -> String {
        "and \(count) more (see suica pending --all)"
    }
    public static let teamsDisabled = "Teams is off. Set teams.enabled to true in the config."
    public static let send = "Send…"
    public static let skip = "Skip"
    public static let retry = "Retry"
    public static let clear = "Clear"
    public static let clearRecentTitle = "Clear the recent messages on this tab?"
    public static let clearRecentMessage = "They stay in Statistics. Messages that need you are not cleared."
    public static let pause = "Pause polling"
    public static let resume = "Resume polling"
    public static let refresh = "Refresh"
    public static let closeNotice = "Close"
    public static let expand = "Show pages"
    public static let collapse = "Hide pages"
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
        case "alert.fix-ready": "Agent Fix ready"
        case "alert.fix-failed": "Agent Fix failed"
        case "alert.fix-pushed": "Agent Fix pushed, replies missing"
        case "alert.pipeline-failed": "Pipeline failed"
        case "alert.pipeline-fix-ready": "Pipeline Fix ready"
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
        case "alert.fix-ready": "To you, when an Agent Fix for your MR waits for you to confirm and push."
        case "alert.fix-failed": "To you, when an Agent Fix run failed."
        case "alert.fix-pushed": "To you, when an Agent Fix was pushed but some replies could not be posted."
        case "alert.pipeline-failed": "To you, when the head pipeline of one of your MRs fails."
        case "alert.pipeline-fix-ready":
            "To you, when a fix of a failed pipeline (and no threads) waits for you to confirm and push."
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
        case "fix.threads": "How many threads the fix answers"
        case "fix.reason": "Why the fix failed"
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
    public static func reviewTab(_ group: ReviewGroup) -> String {
        switch group {
        case .waiting: "Waiting"
        case .reviewed: "Reviewed"
        case .approved: "Approved"
        case .drafts: "Drafts"
        case .all: "All"
        }
    }
    /// The longer name of a tab, for its help text and accessibility.
    public static func reviewTabHelp(_ group: ReviewGroup) -> String {
        switch group {
        case .waiting: "Waiting for you"
        case .reviewed: "You reviewed, not approved yet"
        case .approved: "You approved"
        case .drafts: "Drafts"
        case .all: "All merge requests"
        }
    }
    /// What an empty tab says when nothing is searched.
    public static func nothingInReviewTab(_ group: ReviewGroup) -> String {
        switch group {
        case .waiting: nothingWaiting
        case .reviewed: "Nothing you reviewed is waiting for your approval."
        case .approved: "You have not approved any open merge request."
        case .drafts: "No draft merge requests."
        case .all: noReviewRequests
        }
    }
    public static let noOpenMRsOfYours = "You have no open merge requests."
    public static let mergeRequests = "Merge requests"
    public static let myMergeRequests = "My MRs"
    public static let searchMyMRs = "Search my MRs"
    // Pipeline progress
    public static func pipelineNumber(_ iid: String) -> String { "Pipeline #\(iid)" }
    public static func pipelineJobsDone(_ done: Int, of total: Int) -> String {
        total == 0 ? "No jobs" : "\(done) of \(total) \(total == 1 ? "job" : "jobs") done"
    }
    public static func pipelineStageNow(_ stage: String) -> String { "now: \(stage)" }
    public static func pipelineFor(_ duration: String) -> String { "for \(duration)" }
    public static func pipelineTook(_ duration: String) -> String { "took \(duration)" }
    public static let pipelineShowJobs = "Show jobs"
    public static let pipelineHideJobs = "Hide jobs"
    public static let allowedToFail = "allowed to fail"
    public static let openPipeline = "Open the pipeline in GitLab"
    public static let openJob = "Open the job in GitLab"
    public static func jobStatus(_ status: String) -> String {
        switch status {
        case "SUCCESS": "passed"
        case "FAILED": "failed"
        case "RUNNING": "running"
        case "PENDING", "PREPARING", "WAITING_FOR_RESOURCE", "WAITING_FOR_CALLBACK": "pending"
        case "CREATED": "not started"
        case "MANUAL": "manual"
        case "SKIPPED": "skipped"
        case "CANCELED": "cancelled"
        case "SCHEDULED": "scheduled"
        default: status.lowercased().replacingOccurrences(of: "_", with: " ")
        }
    }
    // Teams message from an MR
    public static let messageOnTeams = "Message on Teams…"
    public static let messageOnTeamsHelp = "Write a Teams message to the author or a reviewer of this merge request"
    public static let messageTo = "To"
    public static let messageTemplate = "Start from"
    public static let messageText = "Message"
    public static let messagePreview = "Preview"
    public static let messageDrafting = "Writing from the template…"
    public static let sendMessage = "Send"
    public static func messageSent(_ name: String) -> String { "Sent to \(name) on Teams." }
    public static let noOneToMessage = "No one else is on this merge request yet."
    public static let messageSendsNow = "Sends now as you, also outside working hours. It is kept in Messages."
    public static func messageRecipient(_ name: String, role: String) -> String { "\(name) (\(role))" }
    public static let authorRole = "author"
    public static let reviewerRole = "reviewer"
    public static func templateLabel(_ name: String) -> String {
        switch name {
        case "nudge": "Review request"
        case "reminder": "Reminder"
        case "rereview": "Re-review request"
        case "notice.comments": "I left comments"
        case "notice.changes": "Changes requested"
        case "notice.approved": "Approved"
        default: name
        }
    }
    /// What happened to a Teams message sent from an MR; nil when it was sent.
    public static func messageOutcome(_ reply: TeamsMessageReply) -> String? {
        switch reply.status {
        case "sent", "draft": nil
        case "teams-off": "Teams is off. Turn it on under Configuration → Teams."
        case "bad-recipient": "That person is not the author or a reviewer of this merge request."
        case "unresolved": "Could not find this person in Teams. Add them under Configuration → Teams → People."
        case "lookup-error": "Teams could not look this person up. The message waits in Messages."
        case "retry-later": "Teams could not be reached. The message waits in Messages; send it from there."
        case "busy": "This message is already being sent."
        case "bad-request": "The message could not be read. Check its text."
        default: reply.message.map { "Not sent: \($0)" } ?? "Not sent: Teams failed."
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
    public static func agentReviewMeta(cli: String?, model: String?, sha: String?, skill: String? = nil) -> String {
        var who = model.map { "\(cliName(cli)) (\(DisplayText.clean($0, max: 60)))" } ?? cliName(cli)
        if let skill { who += ", following \(DisplayText.clean(skill, max: 80))" }
        return sha.map { "By \(who) at commit \(String($0.prefix(8)))" } ?? "By \(who)"
    }
    // Skill and model picker
    public static let reviewWith = "Review with…"
    public static let reviewWithHelp = "Pick the skill and model for this review only"
    public static let pickerTitle = "Skill and model"
    public static let pickerSkill = "Skill"
    public static let pickerModel = "Model"
    public static let searchSkills = "Search skills"
    public static let skillNotInstalled = "Not installed"
    public static let defaultTag = "Default"
    public static let otherModel = "Other model…"
    public static let otherModelPrompt = "Model name"
    public static let otherModelInvalid = "Starts with a letter or digit; letters, digits and . : _ / - only."
    public static let startReview = "Start review"
    public static let choose = "Choose…"
    public static let tryAgain = "Try again"
    public static let reviewBusy = "A review of this MR is queued or running: wait for it, or cancel it first."
    public static let noModelsListed = "This CLI lists no models. Type a name under Other model…"
    public static let noCli = "No model CLI is installed, so there are no models to list."
    public static func noSkillsMatch(_ query: String) -> String {
        "No skill matches “\(DisplayText.clean(query, max: 60))”."
    }
    /// "madhani-code-review with Opus", above Start review.
    public static func reviewWithSummary(skill: String, model: String?) -> String {
        "\(DisplayText.clean(skill, max: 80)) with \(model.map { DisplayText.clean($0, max: 60) } ?? cliDefaultModel)"
    }
    public static func pickerModels(for cli: String?) -> String { "Models of \(cliName(cli))" }
    public static let agentRereviewLabel = "Re-review"
    public static let rereviewNow = "Re-review"
    public static let readyToApprove = "Ready to approve: nothing serious left"
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
    public static let reviewEffortPicker = "Effort"
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
        case "bad-skill": "That skill is not installed any more. Pick another one."
        case "bad-model": "That model name cannot be used. Pick another one."
        case "daily-cap": "Not queued: automatic reviews reached review.maxPerDay for today."
        case "covered": "Not queued: the agent already queued or reviewed this commit."
        default: "Nothing to do: the review changed in the meantime."
        }
    }
    // Agent Fix, comments and merging (your own MRs)
    public static let fixTab = "Agent fix"
    public static let fixFindingsNow = "Fix findings now"
    public static let fixPipelineNow = "Fix pipeline"
    public static let watch = "Watch"
    public static let unwatch = "Unwatch"
    public static let watching = "Watching"
    public static let watchHelp = "Fix new Reviewer threads and failed pipelines on this MR by itself. Each fix waits for you before anything is pushed."
    public static let unwatchHelp = "Stop fixing this MR by itself. Fix findings now still works."
    public static func watchOutcome(_ code: String) -> String {
        switch code {
        case "watching": "Watching: Suica fixes new threads on this MR by itself."
        case "not-watching": "Not watching: Suica leaves this MR to you. Fix findings now still works."
        default: "This merge request key cannot be watched."
        }
    }
    public static let pipelineFailed = "Pipeline failed"
    public static let pipelineRunning = "Pipeline running"
    public static let pipelinePassed = "Pipeline passed"
    public static func fixPipelineHeading(_ iid: String) -> String { "Failed pipeline #\(iid)" }
    public static let fixPipelineWaiting = "The failed jobs and their logs are read when the fix starts."
    public static func fixPipelineJob(name: String, stage: String) -> String {
        stage.isEmpty ? name : "\(name) · \(stage)"
    }
    public static let fixNone =
        "No Agent Fix yet. When a Reviewer opens a thread or the pipeline fails, Suica works on it here and waits for you before pushing anything."
    public static let fixQueued = "Waiting to start…"
    public static let fixConfirming = "Committing, pushing and replying…"
    public static let fixPushedNote = "Pushed. The Reviewers resolve their threads."
    public static let fixChangedBadge = "Changed"
    public static let fixReplyBadge = "Reply only"
    public static let fixNoAnswer = "The model left this thread out."
    public static let fixReplyPlaceholder = "Reply to the reviewer"
    public static let fixDontPost = "Don't post"
    public static let fixPosted = "Posted"
    public static let fixCommitMessage = "Commit message"
    public static let fixNoCodeChange = "No code changed: only replies are posted."
    public static let fixConfirm = "Confirm and push…"
    public static let fixConfirmRepliesOnly = "Post replies…"
    public static let fixRetry = "Retry with a note…"
    public static let fixRetryTitle = "Retry this fix"
    public static let fixRetryHint = "Tell the agent what to do differently. It starts again on a fresh checkout."
    public static let fixRetryAction = "Retry"
    public static let fixDiscard = "Discard"
    public static let fixCancel = "Cancel fix"
    public static let fixPostMissing = "Post missing replies"
    public static func fixConfirmTitle(branch: String, replies: Int, changes: Bool) -> String {
        let posts = replies == 1 ? "1 reply" : "\(replies) replies"
        return changes ? "Commit, push to \(branch) and post \(posts)?" : "Post \(posts) on GitLab as you?"
    }
    public static let fixConfirmMessage = "Nothing is force-pushed. If the branch moved since the fix was made, nothing is pushed."
    public static func fixStatus(_ status: String) -> String {
        switch status {
        case "queued": "Queued"
        case "running": "Running"
        case "ready": "Ready for you"
        case "confirming": "Pushing"
        case "pushed": "Pushed"
        case "push-failed": "Not pushed"
        case "discarded": "Discarded"
        case "failed": "Failed"
        case "skipped": "Skipped"
        case "cancelled": "Cancelled"
        default: status
        }
    }
    public static func fixBadge(_ fix: FixSummary) -> String {
        fix.status != "ready"
            ? "Fix: \(fixStatus(fix.status).lowercased())"
            : fix.threads == 0 ? "Fix ready" : "Fix ready: \(fix.threads) threads"
    }
    public static func fixOutcome(_ code: String) -> String {
        switch code {
        case "queued": "Fix queued. It starts in a few seconds."
        case "added": "The threads joined the fix that is waiting to start."
        case "busy": "A fix of this MR is running or waits for you."
        case "nothing-to-fix": "Nothing to fix: no open thread waits for an answer."
        case "no-failed-pipeline": "Nothing to fix: the MR's head pipeline has not failed."
        case "not-yours": "Suica only fixes your own MRs."
        case "pushed": "Pushed, and the replies are posted."
        case "partial": "Pushed, but some replies were not posted. Post the missing ones from the Agent fix tab."
        case "branch-moved": "Nothing pushed: the branch moved since the fix was made. Retry to redo it on the new commits."
        case "push-failed": "Nothing pushed. The Agent fix tab says why."
        case "discarded": "Fix discarded."
        case "cancelled": "Fix cancelled."
        case "bad-request", "bad-key": "This fix cannot be confirmed as sent."
        default: "Nothing to do: the fix changed in the meantime."
        }
    }
    public static let commentPlaceholder = "Comment on this MR as you (Markdown)"
    public static let commentPreview = "Preview"
    public static let commentSend = "Comment"
    public static func commentOutcome(_ code: String) -> String {
        switch code {
        case "posted": "Comment posted."
        case "empty": "The comment is empty."
        default: "The comment was not posted. Check the MR in GitLab."
        }
    }
    public static let merge = "Merge…"
    public static let mergeTitle = "Merge this MR"
    public static let mergeNow = "Merge"
    public static let mergeWhenPipelineSucceeds = "Merge when pipeline succeeds"
    public static let mergeSquash = "Squash commits"
    public static let mergeSquashLocked = "The project decides whether commits are squashed."
    public static let mergeRemoveBranch = "Delete source branch"
    public static let mergeMessage = "Commit message"
    public static func mergeSha(_ sha: String) -> String { "At commit \(sha.prefix(8)). A newer push is never merged." }
    public static let closeMR = "Close MR…"
    public static let closeConfirmTitle = "Close this MR on GitLab without merging?"
    public static let closeConfirmMessage = "You can reopen it in GitLab. Suica stops fixing its threads."
    public static let closeAction = "Close MR"
    public static func closeOutcome(_ code: String) -> String {
        switch code {
        case "closed": "MR closed."
        case "not-yours": "Not closed: only your own MRs can be closed from Suica."
        case "bad-key": "This merge request key cannot be closed."
        default: "Closing failed. Check the MR in GitLab."
        }
    }
    public static let mergeNewCommits = "New commits arrived since you opened this. Close it and look at them first."
    public static let mergeBlockedPipeline = "The pipeline failed."
    public static let mergeBlockedApproval = "It still needs approval."
    public static let mergeBlockedConflict = "It has merge conflicts."
    public static let mergeBlockedDraft = "It is a draft."
    public static let mergeBlockedThreads = "Some threads are not resolved yet."
    public static let mergeBlockedRebase = "It needs a rebase."
    public static let mergeBlockedDependency = "It waits for another MR."
    public static let mergeBlockedOther = "GitLab will not merge it now."
    public static func mergeOutcome(_ code: String) -> String {
        switch code {
        case "merged": "Merged."
        case "scheduled": "GitLab merges it once the pipeline succeeds."
        case "not-mergeable": "GitLab will not merge it now. Reload to see why."
        case "sha-mismatch": "Not merged: someone pushed after you opened this MR. Look at the new changes first."
        default: "Merging failed. Check the MR in GitLab."
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
    public static let changesTab = "Changes"
    public static let commentsTab = "Comments"
    public static let copyCode = "Copy"
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
        case "fix": "Agent Fix"
        case "office": "Office"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }
    public static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    public static let weekdayNamesLong = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]

    // MARK: Configuration inputs

    /// A choice's name in the form, for the options the agent sends; nil for one this app does not know.
    public static func optionTitle(_ key: String, _ option: String) -> String? {
        switch (key, option) {
        case (_, "dry-run"): "Dry run"
        case ("review.post", "approval"): postWait
        case ("review.post", "auto"): postAuto
        case ("review.approveWhen", "minor"): "Minor or Nit left"
        case ("review.approveWhen", "nit"): "Only Nit left"
        case ("review.approveWhen", "clean"): "No findings"
        case (_, "approval"): "Ask me first"
        case (_, "auto") where key == "model.cli": "Auto"
        case (_, "auto"): "Send automatically"
        case (_, "comment"): postAsCommentOption
        case (_, "inline"): postAsInlineOption
        case (_, "claude"): "Claude Code"
        case (_, "codex"): "Codex"
        case (_, "gemini"): "Gemini CLI"
        default: nil
        }
    }

    /// What a choice does, shown under the control while it is picked.
    public static func optionDetail(_ key: String, _ option: String) -> String? {
        switch (key, option) {
        case ("review.post", "approval"): "A ready review waits in the app until you post it."
        case ("review.post", "auto"): "A ready review is posted to GitLab as you at once."
        case ("review.approveWhen", "minor"): "Approved when every finding left is Minor or Nit."
        case ("review.approveWhen", "nit"): "Approved when every finding left is a Nit."
        case ("review.approveWhen", "clean"): "Approved only when the review found nothing."
        case (_, "comment"): "The whole review is one comment on the MR."
        case (_, "inline"): "Findings on a line of the diff become threads there; the rest is one comment."
        case (_, "dry-run"): "Written to the log and never sent."
        case (_, "approval"): "Waits under Messages until you send it."
        case ("model.cli", "auto"): "The first installed of Claude Code, Codex and Gemini CLI."
        case (_, "auto"): "Sent as soon as it is due, inside working hours."
        case (_, "claude"): "Runs the review skill natively, with read-only tools."
        case (_, "codex"): "Reviews in its read-only sandbox, with the skill pasted in."
        case (_, "gemini"): "Teams replies only: Agent Review does not run with it."
        default: nil
        }
    }

    public static func effortTitle(_ level: String) -> String {
        switch level {
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra high"
        case "max": "Max"
        default: level
        }
    }

    public static func effortDetail(_ level: String) -> String {
        switch level {
        case "low": "Fastest and fewest tokens; may miss subtle problems."
        case "medium": "Balanced, and enough for most MRs."
        case "high": "More thorough; takes longer and uses more tokens."
        case "xhigh": "Much slower and costlier; for tricky changes."
        case "max": "The slowest and costliest. Codex runs it as Extra high."
        default: ""
        }
    }

    public static func categoryDetail(_ key: String) -> String {
        switch key {
        case "gitlab": "Host, glab and its timeout"
        case "polling": "How often GitLab is read"
        case "notifications": "Summaries and ignored authors"
        case "teams": "Messages, modes and hours"
        case "model": "The coding agent CLI"
        case "review": "Posting, model and limits"
        case "fix": "Fixes for your MRs"
        case "office": "Which coding agents it shows"
        default: "Where the history is kept"
        }
    }

    /// The section a setting is listed under on its category's page; nil for a category that is
    /// one section.
    public static func configSection(_ path: [String]) -> String? {
        guard path.count > 1 else { return nil }
        switch (path[0], path[1]) {
        case ("teams", "enabled"), ("teams", "command"), ("teams", "startTimeoutSeconds"),
            ("teams", "callTimeoutSeconds"):
            return "Connection"
        case ("teams", "modes"): return "Send modes"
        case ("teams", "workingHours"): return "Working hours"
        case ("teams", "reminderAfterHours"), ("teams", "noticeDebounceMinutes"), ("teams", "rereviewAfterMinutes"),
            ("teams", "maxMessagesPerReviewer"):
            return "Timing and limits"
        case ("teams", _): return "People and wording"
        case ("review", "auto"), ("review", "approve"), ("review", "approveWhen"): return "Automation"
        case ("review", "post"), ("review", "postAs"): return "Posting"
        case ("review", "skill"), ("review", "model"), ("review", "effort"): return "Skill and model"
        case ("review", _): return "Limits"
        default: return nil
        }
    }

    public static let configOverviewHint = "Pick a category. Search looks through every setting."
    public static let messageTemplatesDetail = "Teams messages and alerts"
    public static let appearanceDetail = "Look, accent and motion"
    public static let backToConfiguration = "Back to Configuration"
    public static func settingsCount(_ count: Int) -> String { count == 1 ? "1 setting" : "\(count) settings" }
    public static func unsavedCount(_ count: Int) -> String { "\(count) unsaved" }
    public static func problemCount(_ count: Int) -> String { count == 1 ? "1 problem" : "\(count) problems" }

    /// "changed lines" for 2, "changed line" for 1.
    public static func unit(_ unit: String, count: Int) -> String {
        count == 1 && unit.hasSuffix("s") ? String(unit.dropLast()) : unit
    }

    public static let durationUnitPicker = "Unit"
    public static let chooseFile = "Choose…"
    public static let showInFinder = "Show in Finder"
    public static let openInBrowser = "Open in browser"
    public static let installed = "Installed"
    public static let notInstalledShort = "Not installed"
    public static let inUse = "In use"
    public static let workingHours = "Working hours"
    public static let workingHoursFrom = "From"
    public static let workingHoursTo = "To"
    public static let workingHoursOrder = "The start must be before the end."
    public static func workingHoursSpan(_ hours: Int, _ minutes: Int) -> String {
        minutes == 0 ? "\(hours) h a day" : "\(hours) h \(minutes) min a day"
    }

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
    public static func approvedBy(_ name: String, username: String) -> String {
        name == username ? "First approved by @\(username)" : "First approved by \(name) (@\(username))"
    }
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
        case "approve": "Approval checks"
        case "fix": "Agent fixes"
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

    // MARK: Office

    public static let office = "Office"
    public static let officeEmpty = "No coding agents running"
    public static let officeEmptyHint = "Start Claude Code, Codex or Gemini CLI and it appears at a desk."
    public static let bubbleWaiting = "Waiting for you"
    public static let bubbleWorking = "Working"
    public static let bubbleIdle = "Idle"
    public static let bubbleExited = "Left the office"
    public static let resetCamera = "Reset view"
    public static let officeCenterRoom = "Center room"
    public static let officeControlsHint =
        "Drag to turn · right-drag, ⌥-drag or two-finger scroll to move · wheel, pinch or ⌘-scroll to zoom"
    public static let openAgent = "Open"
    public static let officeProject = "Project"
    public static let officeStatus = "Status"
    public static let officeStarted = "Started"
    public static let officeLastActions = "Last actions"
    public static let officeNoActions = "No actions seen yet."
    public static let closeDetails = "Close"
    public static let officeStyleMenu = "Customize"
    public static let officeBuildingPicker = "Building"
    public static let officeEnvironmentPicker = "Environment"
    public static let officeHeading = "Office"
    public static let officeStyleHint =
        "What the building is made of, what lies outside it and how the office looks. The Office page's Customize menu has the same choices."
    public static let officeTimeOfDayPicker = "Time of day"
    public static let officeBubblesPicker = "Bubbles"
    public static let officeStreetLifeToggle = "Street life"
    public static let officeSlowTurnToggle = "Slow turn"
    public static let officeBossToggle = "Boss walks over"
    public static let officeMessagePlaceholder = "Message the agent…"
    public static let officeSendMessage = "Send"
    public static let officeSending = "The agent is answering…"
    public static let officeBusyHint = "The agent is working: send when it waits for you or is idle."
    public static let officeSendHint =
        "Return sends, ⌥Return adds a line. One turn runs with your own settings; an open terminal sees it after resuming."

    /// The line under the message field when a message was not sent.
    public static func officeSendOutcome(_ code: String) -> String {
        switch code {
        case "busy": officeBusyHint
        case "not_found": "This session is no longer running on this Mac."
        case "unsupported": "Suica can write only to Claude Code, Codex and Gemini CLI."
        case "agent_missing": "The agent's command line tool was not found on this Mac."
        case "empty": "Write a message first."
        case "too_long": "The message is too long: 8,000 characters at most."
        case "failed": "The agent's turn failed or ran out of time; its own log says why."
        default: "The message was not sent (\(code))."
        }
    }
    public static let officeConversation = "Conversation"
    public static let officeNoChat = "No conversation to show."
    public static let officeChatLoading = "Reading the conversation…"
    public static let officeYou = "You"
    public static let officeChatToggleHint = "Show or hide the conversation of the selected agent"
    public static let copyMessage = "Copy message"
    public static func officeMessageCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "message" : "messages")"
    }
    public static let officeEntranceSign = "Office"
    public static func officeSummary(sessions: Int, rooms: Int) -> String {
        "\(sessions) \(sessions == 1 ? "agent" : "agents") in \(rooms) \(rooms == 1 ? "room" : "rooms")"
    }
    public static func officeStatusName(_ status: String) -> String {
        switch status {
        case "working": "Working"
        case "waiting": "Waiting for you"
        case "exited": "Left"
        default: "Idle"
        }
    }

    // MARK: System

    public static let systemPage = "System"
    public static let cpu = "CPU"
    public static let memory = "Memory"
    public static let disk = "Disk"
    public static let network = "Network"
    public static let battery = "Battery"
    public static let thermal = "Thermal"
    public static let topProcesses = "Top processes"
    public static let processName = "Name"
    public static let processID = "PID"
    public static let download = "Download"
    public static let upload = "Upload"
    public static let lastTwoMinutes = "Last 2 minutes"
    public static let measuring = "Measuring…"
    public static let noProcesses = "Could not list the processes."
    public static let chartTime = "Time"
    public static let chartUsage = "Usage"
    /// 0.423 → "42%".
    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
    /// A process's share of one core: "12.3%".
    public static func processCPU(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US"))) + "%"
    }
    /// Memory in binary units, as Activity Monitor shows it: "12.4 GB".
    public static func memoryBytes(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory).locale(Locale(identifier: "en_US")))
    }
    /// Disk space and traffic in decimal units, as Finder shows them: "245.1 GB".
    public static func diskBytes(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file).locale(Locale(identifier: "en_US")))
    }
    public static func rate(_ bytesPerSecond: Double) -> String {
        "\(diskBytes(UInt64(max(bytesPerSecond, 0).rounded())))/s"
    }
    public static func usedOf(_ used: String, _ total: String) -> String { "\(used) of \(total)" }
    public static func free(_ amount: String) -> String { "\(amount) free" }
    public static func swapUsed(_ amount: String) -> String { "Swap \(amount)" }
    public static func cores(_ count: Int) -> String { count == 1 ? "1 core" : "\(count) cores" }
    /// The 1, 5 and 15 minute load averages.
    public static func loadAverages(_ values: [Double]) -> String {
        let numbers = values.map { $0.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US"))) }
        return "Load \(numbers.joined(separator: " · "))"
    }
    public static func powerState(_ state: PowerState) -> String {
        switch state {
        case .charging: "Charging"
        case .pluggedIn: "On power adapter"
        case .onBattery: "On battery"
        }
    }
    public static func timeLeft(_ minutes: Int) -> String { "\(Copy.minutes(minutes)) left" }
    public static func thermalState(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }
    public static func thermalHint(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: "Running cool."
        case .fair: "A little warm. The fans may spin up."
        case .serious: "Hot. macOS slows the Mac down to cool it."
        case .critical: "Very hot. macOS slows the Mac down hard."
        }
    }
    public static func uptime(_ seconds: TimeInterval) -> String { "Up \(duration(Int(seconds / 60)))" }

    // MARK: Logs

    public static let logs = "Logs"
    public static let logOutput = "Output"
    public static let logErrors = "Errors"
    public static let searchLogs = "Search the log"
    public static let logEmpty = "Nothing logged yet."
    public static let logNoMatches = "No entries match the search."
    public static func logMissing(_ file: String) -> String { "\(file) does not exist yet." }
    public static let logNoneInRange = "Nothing was logged in this date range."
    public static func logTruncated(_ entries: Int) -> String { "Showing the latest \(entries) entries." }
    public static let logLimit = "Show"
    public static func logLimitChoice(_ entries: Int) -> String { "Latest \(entries)" }
    public static let logDateRange = "Date range"
    public static let logFrom = "From"
    public static let logTo = "to"

    public static let searchMessages = "Search messages"
    public static let searchReviews = "Search merge requests"
    public static func noMessagesMatch(_ query: String) -> String { "No messages match “\(query)”." }
    /// After `noMessagesMatch`, when the other tab has some.
    public static func matchesInOtherTab(_ count: Int, _ tab: String) -> String {
        "\(count) \(count == 1 ? "match" : "matches") in \(tab)."
    }
    public static func noReviewsMatch(_ query: String) -> String { "No review requests match “\(query)”." }
    public static func logReadFailed(_ reason: String) -> String { "Could not read the log: \(reason)" }
    public static let logFolderUnknown = "The logs folder is not known until the agent's status loads."
    public static let editConfig = "Edit config"
    public static let readyToApproveShort = "Ready to approve"
    public static let readyToApproveCaption = "Nothing serious left"
    public static let waitingForReviewShort = "Waiting for you"
    public static let attentionCaption = "Teams messages to confirm"
    public static let pollsOk = "Polls ok"
    public static func tokensFor(_ span: String) -> String { "Tokens, \(span)" }
    public static func lastPollAgo(_ relative: String) -> String { "Last poll \(relative)" }
    public static func pollEvery(_ seconds: Int) -> String { "every \(seconds) s" }
    public static func health(_ health: AgentHealth) -> String {
        switch health {
        case .ok: "Agent running"
        case .pollFailed: "Last poll failed"
        case .paused: "Polling paused"
        case .stopped: "Agent stopped"
        case .missing: "Agent not installed"
        }
    }
    public static let waitingForReviewHeading = "Waiting for your review"
    public static let agentReviewShort = "Agent review"
    public static let readyToPostHeading = "Ready to post"
    public static let reviewSettings = "Settings"
    public static let weekHeading = "Last 7 days"
    public static let systemHeading = "System"
    public static func allItems(_ count: Int) -> String { "All \(count) →" }
    public static func reviewTally(_ tally: ReviewTally) -> String {
        var parts: [String] = []
        if tally.waiting > 0 { parts.append("\(tally.waiting) waiting") }
        if tally.reviewed > 0 { parts.append("\(tally.reviewed) reviewed") }
        if tally.drafts > 0 { parts.append("\(tally.drafts) \(tally.drafts == 1 ? "draft" : "drafts")") }
        return parts.isEmpty ? "No open review requests" : parts.joined(separator: " · ")
    }
    public static func yourTally(_ tally: YourTally) -> String {
        let fixes = tally.fixesReady == 0 ? "" : " · \(tally.fixesReady) \(tally.fixesReady == 1 ? "fix" : "fixes") ready"
        return "\(tally.approved) of \(tally.open) approved\(fixes)"
    }
    public static func linkTo(_ title: String) -> String { "\(title) →" }
    public static func moreInMessages(_ count: Int) -> String { "\(count) more in Messages" }
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
        case "cleared": "Cleared."
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

    public static func title(_ value: OfficeStyle) -> String {
        switch value {
        case .modern: "Modern"
        case .brick: "Brick"
        case .glass: "Glass"
        case .timber: "Timber"
        }
    }

    public static func title(_ value: OfficeEnvironment) -> String {
        switch value {
        case .city: "City"
        case .park: "Park"
        case .snow: "Snow"
        }
    }

    public static func title(_ value: OfficeTimeOfDay) -> String {
        switch value {
        case .system: "Follow appearance"
        case .day: "Day"
        case .night: "Night"
        }
    }

    public static func title(_ value: OfficeBubbles) -> String {
        switch value {
        case .all: "All"
        case .selected: "Selected only"
        case .off: "Off"
        }
    }

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
    public static func title(_ value: IconStyle) -> String {
        switch value {
        case .colorful: "Colourful"
        case .tinted: "Tinted"
        case .accent: "Accent"
        case .monochrome: "Monochrome"
        }
    }
    public static func title(_ value: AppIconStyle) -> String {
        switch value {
        case .classic: "Classic"
        case .watermelon: "Watermelon"
        case .sunset: "Sunset"
        case .midnight: "Midnight"
        case .mono: "Mono"
        }
    }
    public static let iconsHeading = "Icons"
    public static let iconStylePicker = "Icon style"
    public static let iconStyleHint = "How the icons in the sidebar, tiles and cards are coloured."
    public static let appIconPicker = "App icon"
    public static let appIconHint =
        "Shown in the Dock and the app switcher while this window is open. Finder keeps the classic icon."
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

// MARK: - Set up Suica

extension Copy {
    public static let setupTitle = "Set up Suica"
    public static let setupOpen = "Set up Suica…"
    public static let setupWelcomeTitle = "Welcome to Suica"
    public static let setupPanelHint =
        "Connect Suica to your GitLab and start the background agent. It takes a minute: the window walks you through it."
    public static let setupBack = "Back"
    public static let setupContinue = "Continue"
    public static let setupDone = "Done"
    public static func setupStepTitle(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: setupWelcomeTitle
        case .gitlab: "Connect to GitLab"
        case .codingAgent: "Pick a coding agent"
        case .teams: "Teams messages"
        case .finish: "Ready to start"
        }
    }
    public static let setupWelcome =
        "Suica watches your GitLab merge requests in the background: it tells you when someone asks for your review or comments, can review MRs with a coding agent, and can nudge reviewers on Teams."
    public static let setupWelcomeSteps =
        "A few questions set up the essentials: your GitLab host, the coding agent to use and whether to send Teams messages. Everything else has sensible defaults and can be changed later in Configuration."
    public static let setupGitlabHint =
        "Suica reads GitLab through the glab command, signed in as you. Enter the host of your GitLab, without a path."
    public static let setupHostPlaceholder = "gitlab.example.com"
    public static let setupCheck = "Check connection"
    public static func setupSignedIn(_ username: String) -> String { "Signed in as @\(username)." }
    public static let setupCheckLater =
        "You can continue without a working connection, but the agent reports GitLab errors until it works."
    public static func setupCheckLine(_ status: String) -> String {
        switch status {
        case "bad-host": "That is not a host name. Enter only the host, such as gitlab.example.com."
        case "glab-missing": "The glab command is not installed. Install it, then check again:"
        case "gitlab-auth": "glab is not signed in to this host. Sign in, then check again:"
        case "gitlab-unreachable": "The host can't be reached. Check the name and your network or VPN."
        default: "GitLab answered with an error. Check the host, or sign in again:"
        }
    }
    public static func setupFixCommand(_ status: String, host: String) -> String? {
        switch status {
        case "glab-missing": "brew install glab"
        case "gitlab-auth", "gitlab-error": "glab auth login --hostname \(host)"
        default: nil
        }
    }
    public static let setupCopy = "Copy"
    public static let setupCodingAgentHint =
        "Agent Review and Agent Fix run a coding agent CLI on this Mac. You can switch any time in Configuration."
    public static let setupRecommended = "Recommended"
    public static func setupAutoUses(_ name: String) -> String {
        "Uses \(name) now: the first installed of Claude Code, Codex and Gemini CLI."
    }
    public static let setupAutoNone = "None of Claude Code, Codex or Gemini CLI is installed yet."
    public static func setupAgentMissingWarning(_ name: String) -> String {
        "\(name) is not installed on this Mac. Install it before the first review, or pick another."
    }
    public static let setupTeamsToggle = "Send Teams messages"
    public static let setupTeamsHint =
        "Suica can nudge reviewers and tell them when you have addressed their comments. It needs the Teams MCP server (teams.command, by default ~/.config/teams-mcp/run.sh). Nudges and most notices wait for your approval in Messages; the notices about an Agent Review's findings and about your approval are sent at once. Change either under Configuration → Teams."
    public static let setupSummaryHost = "GitLab host"
    public static let setupSummaryAgent = "Coding agent"
    public static let setupSummaryTeams = "Teams messages"
    public static let setupOn = "On"
    public static let setupOff = "Off"
    public static let setupFinishHint =
        "Saving writes your config file and starts the background agent. Everything else uses the defaults; change them any time in Configuration."
    public static let setupStart = "Save and start agent"
    public static let setupAllSet = "You're all set"
    public static let setupFinished =
        "Suica is set up and the agent is running. It takes the first look at GitLab now; new review requests show up in Merge requests."
    public static func setupNotSaved(status: String, issues: [ConfigIssue]) -> String {
        if status == "conflict" {
            return "A config file was created meanwhile, so nothing was written. Edit it in Configuration."
        }
        let reasons = issues.map { "\($0.path): \($0.message)" }.joined(separator: " ")
        return reasons.isEmpty ? "The config was not saved." : "The config was not saved. \(reasons)"
    }
    public static let setupAgentNotStarted =
        "The config is saved, but the agent did not start. Try again, or run suica agent install in Terminal."
}
