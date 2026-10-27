import Foundation
import Observation

/// Where a plan stands. The Owner sets it; until then it follows the plan's steps.
public enum PlanStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case planned, inProgress, inReview, done, dropped

    public var id: String { rawValue }
    public var title: String { Copy.planStatus(self) }
}

/// One `### Task N: title` of a plan with how many of its steps are ticked.
public struct PlanTask: Equatable, Sendable {
    public let title: String
    public let done: Int
    public let total: Int
}

/// A plan file written with the writing-plans skill: its title, goal, spec and step progress.
public struct PlanDocument: Equatable, Identifiable, Sendable {
    /// Absolute path of the file.
    public let path: String
    public let title: String
    public let goal: String?
    /// The spec path the plan names, as written.
    public let spec: String?
    /// `YYYY-MM-DD` from the file name.
    public let date: String?
    public let tasks: [PlanTask]
    public let stepsDone: Int
    public let stepsTotal: Int

    public var id: String { path }

    /// No ticked step is Planned, some is In progress, all is Done.
    public var derivedStatus: PlanStatus {
        if stepsTotal > 0 && stepsDone == stepsTotal { return .done }
        return stepsDone > 0 ? .inProgress : .planned
    }

    /// Nil when the file is not a plan: its first 12 lines carry the skill's `For agentic workers`
    /// header, or it is a dated file in a folder named `plans`.
    public static func parse(path: String, text: String) -> PlanDocument? {
        let lines = text.components(separatedBy: .newlines)
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let date = datePrefix(of: name)
        let hasHeader = lines.prefix(12).contains { $0.contains("For agentic workers") }
        let inPlansFolder = url.deletingLastPathComponent().lastPathComponent == "plans" && date != nil
        guard hasHeader || inPlansFolder, !Self.notPlanNames.contains(name.lowercased()) else { return nil }

        var title: String?
        var goal: String?
        var spec: String?
        var tasks: [(title: String, done: Int, total: Int)] = []
        var stepsDone = 0
        var stepsTotal = 0
        var inFence = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if title == nil, line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if goal == nil, line.hasPrefix("**Goal:**") {
                goal = String(line.dropFirst("**Goal:**".count)).trimmingCharacters(in: .whitespaces)
            } else if spec == nil, line.hasPrefix("**Spec:**") || line.hasPrefix("Spec:") {
                spec = firstCodeSpan(in: line)
            } else if line.hasPrefix("### Task "), let colon = line.firstIndex(of: ":") {
                tasks.append((String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces), 0, 0))
            } else if line.hasPrefix("- [ ]") || line.hasPrefix("- [x]") || line.hasPrefix("- [X]") {
                let ticked = !line.hasPrefix("- [ ]")
                stepsTotal += 1
                if ticked { stepsDone += 1 }
                if !tasks.isEmpty {
                    tasks[tasks.count - 1].total += 1
                    if ticked { tasks[tasks.count - 1].done += 1 }
                }
            }
        }
        return PlanDocument(
            path: path, title: title ?? name, goal: goal, spec: spec, date: date,
            tasks: tasks.map { PlanTask(title: $0.title, done: $0.done, total: $0.total) },
            stepsDone: stepsDone, stepsTotal: stepsTotal)
    }

    /// Files that name a folder's contents, not a plan, whatever they quote.
    private static let notPlanNames: Set<String> = ["readme", "tracker"]

    /// `2026-10-26-review-lessons` → `2026-10-26`.
    private static func datePrefix(of name: String) -> String? {
        let prefix = name.prefix(10)
        guard prefix.count == 10, name.dropFirst(10).first == "-" || name.count == 10 else { return nil }
        let parts = prefix.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return String(prefix)
    }

    private static func firstCodeSpan(in line: String) -> String? {
        let parts = line.split(separator: "`", omittingEmptySubsequences: false)
        return parts.count >= 3 ? String(parts[1]) : nil
    }
}

/// Finds the plans under a list of folders.
public enum PlanScanner {
    private static let maxBytes = 1_000_000

    /// Every plan below `folders`, newest date first (undated last, then by path), each file once.
    /// A file that cannot be read or is not UTF-8 is skipped.
    public static func scan(folders: [String], home: String = NSHomeDirectory()) -> [PlanDocument] {
        var seen = Set<String>()
        var plans: [PlanDocument] = []
        for folder in folders {
            let root = URL(fileURLWithPath: Folders.expand(folder, home: home))
            guard
                let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if ["node_modules", ".build"].contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "md", values?.isRegularFile == true,
                    (values?.fileSize ?? 0) <= maxBytes
                else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard !seen.contains(path), let text = try? String(contentsOf: url, encoding: .utf8),
                    let plan = PlanDocument.parse(path: path, text: text)
                else { continue }
                seen.insert(path)
                plans.append(plan)
            }
        }
        return plans.sorted {
            switch ($0.date, $1.date) {
            case (let a?, let b?) where a != b: a > b
            case (nil, _?): false
            case (_?, nil): true
            default: $0.path < $1.path
            }
        }
    }
}

/// What the Owner set on a plan: a status that beats the derived one, and a note on where it stands.
public struct PlanMark: Equatable, Codable, Sendable {
    public var status: PlanStatus?
    public var note: String
}

/// The plans of the Owner's folders with their marks, searched and filtered for the Plans page.
/// Folders and marks are kept in `store`, keyed by the plan's absolute path.
@MainActor @Observable
public final class PlansModel {
    public private(set) var folders: [String]
    public private(set) var plans: [PlanDocument] = []
    public private(set) var isScanning = false
    public var query = ""
    public var filter: PlanStatus?
    private var marks: [String: PlanMark]
    private let store: any PreferenceStore
    private let home: String
    private let scan: @Sendable ([String]) -> [PlanDocument]
    /// Bumped by every refresh, so a slow scan that was overtaken drops its result.
    private var generation = 0

    private enum Key {
        static let folders = "plans.folders"
        static let marks = "plans.marks"
    }

    public init(
        store: any PreferenceStore, home: String = NSHomeDirectory(),
        scan: @escaping @Sendable ([String]) -> [PlanDocument] = { PlanScanner.scan(folders: $0) }
    ) {
        self.store = store
        self.home = home
        self.scan = scan
        folders = (store.object(forKey: Key.folders) as? [String]) ?? []
        marks =
            store.string(forKey: Key.marks)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: PlanMark].self, from: $0) } ?? [:]
    }

    /// Scans off the main thread; the previous list stays until the scan is done. Only the newest
    /// refresh sets the list: an older scan that finishes later is dropped.
    public func refresh() async {
        generation += 1
        let mine = generation
        guard !folders.isEmpty else {
            plans = []
            isScanning = false
            return
        }
        isScanning = true
        let folders = folders
        let scan = scan
        let found = await Task.detached { scan(folders) }.value
        guard mine == generation else { return }
        plans = found
        isScanning = false
    }

    public func addFolders(_ chosen: [String]) {
        folders = Folders.adding(chosen, to: folders, home: home)
        store.set(folders, forKey: Key.folders)
    }

    public func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
        store.set(folders, forKey: Key.folders)
    }

    public func status(of plan: PlanDocument) -> PlanStatus { marks[plan.path]?.status ?? plan.derivedStatus }
    public func hasSetStatus(_ plan: PlanDocument) -> Bool { marks[plan.path]?.status != nil }
    public func note(for plan: PlanDocument) -> String { marks[plan.path]?.note ?? "" }

    /// Nil goes back to the status the steps give.
    public func setStatus(_ status: PlanStatus?, for plan: PlanDocument) {
        update(plan) { $0.status = status }
    }

    public func setNote(_ note: String, for plan: PlanDocument) {
        update(plan) { $0.note = note.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The plans the filter and the search leave, in list order.
    public var visible: [PlanDocument] {
        let words = query.trimmingCharacters(in: .whitespaces)
        return plans.filter { plan in
            if let filter, status(of: plan) != filter { return false }
            guard !words.isEmpty else { return true }
            let name = URL(fileURLWithPath: plan.path).lastPathComponent
            return [plan.title, plan.goal ?? "", note(for: plan), name].contains {
                $0.localizedCaseInsensitiveContains(words)
            }
        }
    }

    /// Plans per status over every plan, whatever the filter and the search.
    public var counts: [PlanStatus: Int] {
        Dictionary(grouping: plans, by: { status(of: $0) }).mapValues(\.count)
    }

    private func update(_ plan: PlanDocument, _ change: (inout PlanMark) -> Void) {
        var mark = marks[plan.path] ?? PlanMark(status: nil, note: "")
        change(&mark)
        marks[plan.path] = mark.status == nil && mark.note.isEmpty ? nil : mark
        if let data = try? JSONEncoder().encode(marks), let json = String(data: data, encoding: .utf8) {
            store.set(json, forKey: Key.marks)
        }
    }
}
