import Foundation
import Observation

// MARK: - Documents (contracts/lessons.v1.json)

/// One Lesson in `suica lessons list --json`, as its scope ranks it.
public struct LessonSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    /// The general rule with its reason, as the model wrote it.
    public let rule: String
    public let topics: [String]
    /// The agent's ranking weight; the list comes heaviest first.
    public let weight: Double
    /// Occurrences: how many times it was flagged.
    public let count: Int
    /// The projects (`group/project`) it was flagged in, sorted.
    public let repos: [String]
    /// ISO 8601, its newest occurrence.
    public let lastSeen: String

    public init(
        id: Int, title: String, rule: String, topics: [String], weight: Double, count: Int, repos: [String],
        lastSeen: String
    ) {
        self.id = id
        self.title = title
        self.rule = rule
        self.topics = topics
        self.weight = weight
        self.count = count
        self.repos = repos
        self.lastSeen = lastSeen
    }

    public var lastSeenDate: Date? { MRNote.parse(lastSeen) }

    /// By its title, rule and Topics.
    public func matches(_ query: String) -> Bool {
        Search.matches(query, [title, rule] + topics)
    }
}

/// One configured Lesson Scope: a folder whose repos share Lessons.
public struct LessonScope: Codable, Equatable, Identifiable, Sendable {
    /// The configured folder, resolved.
    public let path: String
    /// Git repos found under it.
    public let repos: Int
    /// Its unarchived Lessons, heaviest first.
    public let lessons: [LessonSummary]

    public init(path: String, repos: Int, lessons: [LessonSummary]) {
        self.path = path
        self.repos = repos
        self.lessons = lessons
    }

    public var id: String { path }
}

/// `suica lessons list --json`.
public struct LessonListDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let enabled: Bool
    /// Empty while lessons are off.
    public let scopes: [LessonScope]
    /// Findings not learned into a Lesson yet.
    public let pending: Int

    public init(version: Int, enabled: Bool, scopes: [LessonScope], pending: Int) {
        self.version = version
        self.enabled = enabled
        self.scopes = scopes
        self.pending = pending
    }
}

public struct RelatedLesson: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String

    public init(id: Int, title: String) {
        self.id = id
        self.title = title
    }
}

/// One finding a Lesson was learned from.
public struct LessonOccurrence: Codable, Equatable, Sendable {
    public let mrKey: String
    public let mrTitle: String
    /// Empty when the agent did not know GitLab's host.
    public let mrUrl: String
    public let path: String?
    public let line: Int?
    /// Blocker, Major, Minor, Nit, or "" under no severity.
    public let severity: String
    /// open, changed, replied, fixed, not-fixed, partly-fixed, …; kept as sent.
    public let outcome: String
    /// The finding's text, at most 1000 characters.
    public let text: String
    /// ISO 8601.
    public let at: String

    public var date: Date? { MRNote.parse(at) }
    /// Only an http(s) link opens.
    public var mrURL: URL? { DisplayText.safeURL(mrUrl) }

    /// `path:line`, or the path alone; nil without a path.
    public var location: String? {
        guard let path, !path.isEmpty else { return nil }
        return line.map { "\(path):\($0)" } ?? path
    }
}

/// One Lesson in `suica lessons show <id> --json`, archived or not.
public struct LessonDetail: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let rule: String
    public let topics: [String]
    /// The file globs the hook matches it by.
    public let globs: [String]
    /// The Lesson Scope's path; "" when its occurrences fall in no scope.
    public let scope: String
    public let archived: Bool
    public let weight: Double
    public let count: Int
    public let repos: [String]
    /// Nil when it has no occurrence.
    public let lastSeen: String?
    /// Linked Lessons of the same scope, not archived.
    public let related: [RelatedLesson]
    /// Newest first.
    public let occurrences: [LessonOccurrence]

    public init(
        id: Int, title: String, rule: String, topics: [String], globs: [String], scope: String, archived: Bool,
        weight: Double, count: Int, repos: [String], lastSeen: String?, related: [RelatedLesson],
        occurrences: [LessonOccurrence]
    ) {
        self.id = id
        self.title = title
        self.rule = rule
        self.topics = topics
        self.globs = globs
        self.scope = scope
        self.archived = archived
        self.weight = weight
        self.count = count
        self.repos = repos
        self.lastSeen = lastSeen
        self.related = related
        self.occurrences = occurrences
    }
}

public struct LessonDetailDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let lesson: LessonDetail

    public init(version: Int, lesson: LessonDetail) {
        self.version = version
        self.lesson = lesson
    }
}

// MARK: - Repeats (contracts/reviews.v1.json, contracts/fixes.v1.json)

/// An Agent Review finding that repeats a Lesson learned before it.
public struct ReviewRepeat: Codable, Equatable, Sendable {
    /// The finding's number, made unique within the review as `uniqueFindingNumbers` does (`1#2`).
    public let finding: String
    public let lessonId: Int
    public let title: String
    /// How many times it was flagged before this finding.
    public let before: Int
    public let repos: [String]

    public init(finding: String, lessonId: Int, title: String, before: Int, repos: [String]) {
        self.finding = finding
        self.lessonId = lessonId
        self.title = title
        self.before = before
        self.repos = repos
    }
}

/// A Finding Thread on your own MR that repeats a Lesson.
public struct ThreadRepeat: Codable, Equatable, Sendable {
    public let lessonId: Int
    public let title: String
    public let before: Int
    public let repos: [String]

    public init(lessonId: Int, title: String, before: Int, repos: [String]) {
        self.lessonId = lessonId
        self.title = title
        self.before = before
        self.repos = repos
    }
}

// MARK: - Findings of a review body

/// A finding of an Agent Review as the agent reads it from the body (`extractFindings` in
/// src/inline-review.ts): a top-level list item under a Findings heading that starts with a
/// `path:line` code span.
public struct ReviewFinding: Equatable, Sendable {
    /// Unique within the review: a number used before becomes `<number>#<position>`.
    public let number: String
    public let path: String
    public let line: Int
    public let text: String
    /// The capitalised severity subheading it sits under; "" under none.
    public let severity: String

    /// The first line of its text.
    public var title: String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}

/// Each number made unique within a review, as the agent keys its findings: numbered lists under
/// each severity both start at 1, so a number already used becomes `<number>#<position>`
/// (1-based among all findings). Port of `uniqueFindingNumbers` in src/inline-review.ts.
public func uniqueFindingNumbers(_ numbers: [String]) -> [String] {
    var used: Set<String> = []
    return numbers.enumerated().map { index, number in
        let unique = used.contains(number) ? "\(number)#\(index + 1)" : number
        used.insert(unique)
        return unique
    }
}

private nonisolated(unsafe) let fenceLine = #/^\s*(```|~~~)/#
private nonisolated(unsafe) let headingLine = #/^(#{1,6})\s+(.*)$/#
private nonisolated(unsafe) let listItemLine = #/^ {0,3}(?:\d+[.)]|[-*+])\s/#
private nonisolated(unsafe) let findingItemLine =
    #/^( {0,3}(?:(\d+)[.)]|[-*+])\s+)`([^`\s]+):(\d+)(?:[-–]\d+)?`[ \t]*(?:[—–:-][ \t]*)?(.*)$/#
private nonisolated(unsafe) let boldLabelLine = #/^(\*\*|__)(.+?)\1\s*$/#
private nonisolated(unsafe) let severityHeading = #/^\W*([A-Za-z]+)\s*(?:$|[^A-Za-z\s])/#

private func isPreviousHeading(_ title: String) -> Bool {
    title.firstMatch(of: #/^\W*previous\b/#.ignoresCase()) != nil
}

private func isFindingsHeading(_ title: String) -> Bool {
    title.firstMatch(of: #/\bfindings\b/#.ignoresCase()) != nil && !isPreviousHeading(title)
}

private func severityOf(_ title: String) -> String? {
    guard let word = title.firstMatch(of: severityHeading)?.1 else { return nil }
    return word.prefix(1).uppercased() + word.dropFirst().lowercased()
}

/// Where a list item that starts at `from - 1` ends: before the next item, heading, or unindented
/// line after a blank one; fenced code inside it belongs to it.
private func itemEnd(_ lines: [String], from: Int) -> Int {
    var inFence = false
    var last = from
    var index = from
    while index < lines.count {
        let line = lines[index]
        defer { index += 1 }
        if line.firstMatch(of: fenceLine) != nil {
            inFence.toggle()
            last = index + 1
            continue
        }
        if inFence {
            last = index + 1
            continue
        }
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        let afterBlank = index > last
        if line.firstMatch(of: listItemLine) != nil || line.firstMatch(of: headingLine) != nil
            || (afterBlank && !(line.first?.isWhitespace ?? false))
        {
            break
        }
        last = index + 1
    }
    return last
}

/// The findings of a review body, numbered as the agent numbers them. Port of `extractFindings`
/// and `uniqueFindingNumbers` in src/inline-review.ts: a Previous heading and what is under it are
/// left out, and so is anything in fenced code.
public func extractReviewFindings(_ markdown: String) -> [ReviewFinding] {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var raw: [(number: String, path: String, line: Int, text: String, severity: String)] = []
    var sectionLevel: Int?
    var previousLevel: Int?
    var severity: String? = ""
    var inFence = false
    var index = 0
    while index < lines.count {
        let line = lines[index]
        if line.firstMatch(of: fenceLine) != nil { inFence.toggle() }
        if !inFence, let heading = line.firstMatch(of: headingLine) {
            let level = heading.1.count
            let title = String(heading.2)
            if let previous = previousLevel, level > previous {
                // Still under the Previous heading.
            } else if isFindingsHeading(title) {
                sectionLevel = level
                previousLevel = nil
                severity = ""
            } else {
                if let section = sectionLevel, level <= section { sectionLevel = nil }
                previousLevel = isPreviousHeading(title) ? level : nil
                severity = severityOf(title)
            }
            index += 1
            continue
        }
        if !inFence, sectionLevel != nil, previousLevel == nil, let label = line.firstMatch(of: boldLabelLine) {
            severity = severityOf(String(label.2))
            index += 1
            continue
        }
        guard !inFence, sectionLevel != nil, previousLevel == nil, let match = line.firstMatch(of: findingItemLine),
            let number = Int(match.4)
        else {
            index += 1
            continue
        }
        let indent = match.1.count
        let end = itemEnd(lines, from: index + 1)
        let continuation = lines[(index + 1)..<end].map { rest in
            String(rest.dropFirst(min(indent, rest.prefix { $0 == " " }.count)))
        }
        let text = ([String(match.5)] + continuation).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        raw.append(
            (match.2.map(String.init) ?? String(raw.count + 1), String(match.3), number, text, severity ?? ""))
        index = end
    }
    let numbers = uniqueFindingNumbers(raw.map(\.number))
    return zip(raw, numbers).map { item, number in
        ReviewFinding(number: number, path: item.path, line: item.line, text: item.text, severity: item.severity)
    }
}

/// A finding of the review that repeats a Lesson, with the finding when the body still lists it.
public struct RepeatedFinding: Equatable, Identifiable, Sendable {
    /// The number the agent gave it (`1`, `1#2`).
    public let label: String
    public let finding: ReviewFinding?
    public let lessonRepeat: ReviewRepeat

    public var id: String { label }
}

extension AgentReviewInfo {
    /// Its repeats, each matched to its finding by the numbering the agent used.
    public var repeatedFindings: [RepeatedFinding] {
        guard !repeats.isEmpty else { return [] }
        let findings = extractReviewFindings(body ?? "")
        let byNumber = Dictionary(findings.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        return repeats.map { RepeatedFinding(label: $0.finding, finding: byNumber[$0.finding], lessonRepeat: $0) }
    }
}

// MARK: - Filtering

/// What the Lessons page narrows the list to; nil shows every scope, Topic or repo.
public struct LessonFilter: Equatable, Sendable {
    public var scope: String?
    public var topic: String?
    public var repo: String?
    public var query: String

    public init(scope: String? = nil, topic: String? = nil, repo: String? = nil, query: String = "") {
        self.scope = scope
        self.topic = topic
        self.repo = repo
        self.query = query
    }

    public func keeps(_ lesson: LessonSummary) -> Bool {
        (topic.map(lesson.topics.contains) ?? true) && (repo.map(lesson.repos.contains) ?? true)
            && lesson.matches(query)
    }
}

extension LessonListDocument {
    private var allLessons: [LessonSummary] { scopes.flatMap(\.lessons) }

    /// Every Topic of a listed Lesson, sorted.
    public var topics: [String] { Array(Set(allLessons.flatMap(\.topics))).sorted() }

    /// Every repo a listed Lesson was flagged in, sorted.
    public var repos: [String] { Array(Set(allLessons.flatMap(\.repos))).sorted() }

    /// No scope lists a Lesson.
    public var isEmpty: Bool { allLessons.isEmpty }

    /// The scopes the filter shows, each with only the Lessons it keeps, still by weight.
    public func scopes(matching filter: LessonFilter) -> [LessonScope] {
        scopes.filter { filter.scope == nil || $0.path == filter.scope }.map { scope in
            LessonScope(path: scope.path, repos: scope.repos, lessons: scope.lessons.filter(filter.keeps))
        }
    }

    public func scope(ofLesson id: Int) -> LessonScope? {
        scopes.first { $0.lessons.contains { $0.id == id } }
    }

    /// The Lessons `lesson` can be merged into: the others of its own scope. None for an archived
    /// Lesson, or one that falls in no scope; the agent refuses both.
    public func mergeCandidates(for lesson: LessonDetail) -> [LessonSummary] {
        guard !lesson.archived, !lesson.scope.isEmpty else { return [] }
        return scopes.first { $0.path == lesson.scope }?.lessons.filter { $0.id != lesson.id } ?? []
    }
}

// MARK: - Commands' answers

/// What `suica lessons archive|merge` answered.
public enum LessonChangeOutcome: Equatable, Sendable {
    case archived, merged, notFound
    /// The agent refused, with its reason ("lesson 2 is archived", "lessons of two scopes …").
    case refused(String)
    case unknown(String)

    init(status: String, message: String?) {
        switch status {
        case "archived": self = .archived
        case "merged": self = .merged
        case "not-found": self = .notFound
        case "bad-request": self = .refused(message ?? "")
        default: self = .unknown(status)
        }
    }
}

/// `suica lessons status --json`: whether the Claude Code hook and the MCP servers are installed.
public struct LessonsSetupStatus: Decodable, Equatable, Sendable {
    public let hook: Bool
    public let claude: Bool
    public let codex: Bool

    public init(hook: Bool, claude: Bool, codex: Bool) {
        self.hook = hook
        self.claude = claude
        self.codex = codex
    }

    private struct MCP: Decodable {
        let claude: Bool
        let codex: Bool
    }

    private enum CodingKeys: String, CodingKey { case hook, mcp }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hook = try container.decode(Bool.self, forKey: .hook)
        let mcp = try container.decodeIfPresent(MCP.self, forKey: .mcp)
        claude = mcp?.claude ?? false
        codex = mcp?.codex ?? false
    }
}

/// What `suica lessons install` would change, shown before anything is.
public struct LessonsInstallPlan: Codable, Equatable, Sendable {
    public struct Hook: Codable, Equatable, Sendable {
        public let event: String
        public let matcher: String

        /// `PostToolUse (Read)`, or the event alone without a matcher.
        public var label: String { matcher.isEmpty ? event : "\(event) (\(matcher))" }
    }

    /// `~/.claude/settings.json`.
    public let settingsPath: String
    public let hooks: [Hook]
    /// The coding agents the MCP server is registered with: claude, codex.
    public let mcp: [String]
    /// The hook command written into settings.json.
    public let command: String
    /// Every CLI call that would run, in order.
    public let commands: [String]
    public let note: String
}

/// `suica lessons install [--yes] --json`: the plan (`needs-confirmation`), or what was done.
public struct LessonsInstallReply: Decodable, Equatable, Sendable {
    /// needs-confirmation, installed, partial, invalid-settings or unreadable-settings.
    public let status: String
    public let plan: LessonsInstallPlan?
    public let settingsPath: String?
    public let registered: [String]
    public let skipped: [String]
    public let failed: [String]

    private enum CodingKeys: String, CodingKey { case status, plan, settingsPath, registered, skipped, failed }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        plan = try container.decodeIfPresent(LessonsInstallPlan.self, forKey: .plan)
        settingsPath = try container.decodeIfPresent(String.self, forKey: .settingsPath)
        registered = try container.decodeIfPresent([String].self, forKey: .registered) ?? []
        skipped = try container.decodeIfPresent([String].self, forKey: .skipped) ?? []
        failed = try container.decodeIfPresent([String].self, forKey: .failed) ?? []
    }
}

/// `suica lessons uninstall --json`.
public struct LessonsUninstallReply: Decodable, Equatable, Sendable {
    /// uninstalled, partial, invalid-settings or unreadable-settings.
    public let status: String
    public let hookRemoved: Bool
    public let removed: [String]
    public let failed: [String]

    public init(status: String, hookRemoved: Bool, removed: [String], failed: [String]) {
        self.status = status
        self.hookRemoved = hookRemoved
        self.removed = removed
        self.failed = failed
    }

    private enum CodingKeys: String, CodingKey { case status, hookRemoved, removed, failed }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        hookRemoved = try container.decodeIfPresent(Bool.self, forKey: .hookRemoved) ?? false
        removed = try container.decodeIfPresent([String].self, forKey: .removed) ?? []
        failed = try container.decodeIfPresent([String].self, forKey: .failed) ?? []
    }
}

/// `suica lessons export --json`.
public struct LessonsExportReply: Decodable, Equatable, Sendable {
    /// exported, disabled, no-vault-path, no-lessons or failed.
    public let status: String
    public let written: Int
    public let removed: Int
    /// Files in the vault Suica did not write, left alone.
    public let conflicts: Int
    public let path: String?
    public let message: String?

    public init(status: String, written: Int, removed: Int, conflicts: Int, path: String?, message: String?) {
        self.status = status
        self.written = written
        self.removed = removed
        self.conflicts = conflicts
        self.path = path
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case status, written, removed, conflicts, path, message }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        written = try container.decodeIfPresent(Int.self, forKey: .written) ?? 0
        removed = try container.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        conflicts = try container.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        path = try container.decodeIfPresent(String.self, forKey: .path)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

// MARK: - Client

public protocol LessonsClient: Sendable {
    func lessons() async throws(AgentError) -> LessonListDocument
    /// Nil when the agent has no such Lesson.
    func lesson(id: Int) async throws(AgentError) -> LessonDetailDocument?
    func archiveLesson(id: Int) async throws(AgentError) -> LessonChangeOutcome
    /// Merges `gone` into `keep`.
    func mergeLessons(keep: Int, gone: Int) async throws(AgentError) -> LessonChangeOutcome
    func lessonsStatus() async throws(AgentError) -> LessonsSetupStatus
    /// Without `confirm` only the plan comes back; nothing changes.
    func installLessons(confirm: Bool) async throws(AgentError) -> LessonsInstallReply
    func uninstallLessons() async throws(AgentError) -> LessonsUninstallReply
    func exportLessons() async throws(AgentError) -> LessonsExportReply
}

// MARK: - Model

/// Where Install… is: asking the agent for its plan, showing it, waiting for your answer after the
/// dialog closed, or installing.
public enum LessonsInstallStep: Equatable, Sendable {
    case idle, planning
    /// The plan is on screen.
    case confirming(LessonsInstallPlan)
    /// The dialog closed and its button has not answered yet. SwiftUI closes a dialog (writes
    /// false to its binding) and runs the pressed button in either order, so closing alone never
    /// cancels: Install or Cancel decides.
    case dismissed(LessonsInstallPlan)
    case installing

    /// The plan waiting for Install or Cancel.
    public var plan: LessonsInstallPlan? {
        switch self {
        case .confirming(let plan), .dismissed(let plan): plan
        default: nil
        }
    }
}

/// The Lessons page and the Lessons configuration's hook row. Nothing polls: the page reads the
/// list when it opens and after each change.
@MainActor @Observable
public final class LessonsModel {
    /// The last good list: a failed refresh does not clear it.
    public private(set) var list: LessonListDocument?
    public private(set) var errorText: String?
    public private(set) var loading = false
    public private(set) var selectedId: Int?
    public private(set) var selected: LessonDetailDocument?
    public private(set) var detailError: String?
    /// The outcome of the last archive or merge.
    public private(set) var banner: String?
    /// An archive or merge is in flight.
    public private(set) var busy = false
    public var filter = LessonFilter()

    /// The hook and MCP servers; nil until read.
    public private(set) var setup: LessonsSetupStatus?
    public private(set) var install: LessonsInstallStep = .idle
    /// The status is being read.
    public private(set) var setupLoading = false
    /// Why the last status read failed; nil once one succeeds.
    public private(set) var setupError: String?
    /// An uninstall or export is in flight.
    public private(set) var setupBusy = false
    /// The outcome of the last install, uninstall or export.
    public private(set) var setupNotice: String?

    @ObservationIgnored private let client: any LessonsClient
    @ObservationIgnored private var latestRefresh = 0
    @ObservationIgnored private var latestDetail = 0

    public init(client: any LessonsClient) {
        self.client = client
    }

    public func dismissBanner() { banner = nil }
    public func dismissSetupNotice() { setupNotice = nil }

    /// The scopes and Lessons the filter keeps.
    public var shownScopes: [LessonScope] { list?.scopes(matching: filter) ?? [] }

    public func refresh() async {
        latestRefresh += 1
        let mine = latestRefresh
        loading = true
        defer { if mine == latestRefresh { loading = false } }
        do {
            let fresh = try await client.lessons()
            guard mine == latestRefresh else { return }
            if list != fresh { list = fresh }
            errorText = nil
            // A scope that left the config is not kept as a filter that hides everything.
            if let scope = filter.scope, !fresh.scopes.contains(where: { $0.path == scope }) { filter.scope = nil }
        } catch {
            guard mine == latestRefresh else { return }
            errorText = MenuModel.message(for: error)
        }
    }

    /// Shows one Lesson; nil clears the detail.
    public func select(_ id: Int?) async {
        selectedId = id
        if selected?.lesson.id != id { selected = nil }
        detailError = nil
        guard let id else { return }
        await loadDetail(id)
    }

    /// Opens a Lesson from elsewhere (a repeat marker): the filters are cleared to its scope, so its
    /// row is in the list.
    public func open(_ id: Int) async {
        if list == nil { await refresh() }
        filter = LessonFilter(scope: list?.scope(ofLesson: id)?.path)
        await select(id)
        if filter.scope == nil, let scope = selected?.lesson.scope, list?.scopes.contains(where: { $0.path == scope }) == true {
            filter.scope = scope
        }
    }

    private func loadDetail(_ id: Int) async {
        latestDetail += 1
        let mine = latestDetail
        do {
            let fresh = try await client.lesson(id: id)
            guard mine == latestDetail, selectedId == id else { return }
            if let fresh {
                if selected != fresh { selected = fresh }
            } else {
                selected = nil
                detailError = Copy.lessonGone
            }
        } catch {
            guard mine == latestDetail, selectedId == id else { return }
            detailError = MenuModel.message(for: error)
        }
    }

    public func archive(_ id: Int) async {
        await change { (client: any LessonsClient) async throws(AgentError) -> LessonChangeOutcome in
            try await client.archiveLesson(id: id)
        } then: { outcome in
            if outcome == .archived && self.selectedId == id { await self.select(nil) }
        }
    }

    /// Merges `gone` into `keep`, then shows `keep`.
    public func merge(_ gone: Int, into keep: Int) async {
        await change { (client: any LessonsClient) async throws(AgentError) -> LessonChangeOutcome in
            try await client.mergeLessons(keep: keep, gone: gone)
        } then: { outcome in
            if outcome == .merged { await self.select(keep) }
        }
    }

    private func change(
        _ run: (any LessonsClient) async throws(AgentError) -> LessonChangeOutcome,
        then: (LessonChangeOutcome) async -> Void
    ) async {
        guard !busy else { return }
        busy = true
        do {
            let outcome = try await run(client)
            banner = Copy.lessonChangeOutcome(outcome)
            await then(outcome)
        } catch {
            banner = MenuModel.message(for: error)
        }
        busy = false
        await refresh()
        if let id = selectedId, selected?.lesson.id == id { await loadDetail(id) }
    }

    // MARK: Hook and MCP server

    public func refreshSetup() async {
        guard !setupLoading else { return }
        setupLoading = true
        do {
            setup = try await client.lessonsStatus()
            setupError = nil
        } catch {
            setupError = Copy.lessonsStatusFailed(MenuModel.message(for: error))
        }
        setupLoading = false
    }

    /// Asks the agent what installing would change; nothing changes until `confirmInstall`.
    public func beginInstall() async {
        if case .dismissed = install { install = .idle }
        guard install == .idle else { return }
        install = .planning
        do {
            let reply = try await client.installLessons(confirm: false)
            if reply.status == "needs-confirmation", let plan = reply.plan {
                install = .confirming(plan)
                return
            }
            setupNotice = Copy.lessonsInstallOutcome(reply)
        } catch {
            setupNotice = MenuModel.message(for: error)
        }
        install = .idle
    }

    /// The dialog's binding was set to false: keeps the plan for the button that closed it.
    public func installDialogClosed() {
        if case .confirming(let plan) = install { install = .dismissed(plan) }
    }

    /// Cancel: nothing is installed.
    public func cancelInstall() {
        if install.plan != nil { install = .idle }
    }

    /// Install: moves to `.installing` at once, before anything can cancel, then installs as the
    /// plan said and reads the status again. Nil when no plan waits.
    @discardableResult
    public func confirmInstall() -> Task<Void, Never>? {
        guard install.plan != nil else { return nil }
        install = .installing
        return Task { await self.runInstall() }
    }

    private func runInstall() async {
        do {
            setupNotice = Copy.lessonsInstallOutcome(try await client.installLessons(confirm: true))
        } catch {
            setupNotice = MenuModel.message(for: error)
        }
        install = .idle
        await refreshSetup()
    }

    public func uninstall() async {
        if case .dismissed = install { install = .idle }
        guard !setupBusy, install == .idle else { return }
        setupBusy = true
        do {
            setupNotice = Copy.lessonsUninstallOutcome(try await client.uninstallLessons())
        } catch {
            setupNotice = MenuModel.message(for: error)
        }
        setupBusy = false
        await refreshSetup()
    }

    public func exportVault() async {
        guard !setupBusy else { return }
        setupBusy = true
        do {
            setupNotice = Copy.lessonsExportOutcome(try await client.exportLessons())
        } catch {
            setupNotice = MenuModel.message(for: error)
        }
        setupBusy = false
    }
}
