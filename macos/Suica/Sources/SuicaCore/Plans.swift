import Foundation

/// Where a plan stands. The Owner sets it; until then it follows the plan's steps.
public enum PlanStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case planned, inProgress, inReview, done, dropped

    public var id: String { rawValue }
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
        guard hasHeader || inPlansFolder else { return nil }

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
