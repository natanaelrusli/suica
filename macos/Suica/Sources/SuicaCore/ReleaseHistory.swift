import Foundation

/// Bundled release notes, newest first. Update alongside the version when preparing a release.
/// Summaries follow the commits between the corresponding Git tags.
public struct ReleaseNote: Identifiable, Sendable {
    public let version: String
    public let date: String
    public let title: String
    public let changes: [String]

    public var id: String { version }
    public var url: URL { URL(string: "https://github.com/natanaelrusli/suica/releases/tag/v\(version)")! }

    public static let recent: [ReleaseNote] = [
        ReleaseNote(
            version: "0.1.9", date: "9 Nov 2026", title: "Lessons from your agents",
            changes: [
                "Coding agents can save lessons directly through the add_lesson MCP tool.",
                "Export the lessons graph as JSON for use outside Suica.",
            ]),
        ReleaseNote(
            version: "0.1.8", date: "5 Nov 2026", title: "Read and edit documents",
            changes: [
                "Browse Markdown documents in a folder tree, follow links and read plans in the app.",
                "Edit documents with drafts, atomic saves and conflict detection when a file changes on disk.",
                "Suica asks before quitting and holds updates while documents have unsaved changes.",
            ]),
        ReleaseNote(
            version: "0.1.7", date: "4 Nov 2026", title: "A cleaner workspace",
            changes: [
                "Clear caches, old logs, update downloads and leftover fix checkouts from Configuration.",
                "Compact the state database while keeping settings, templates and history.",
            ]),
        ReleaseNote(
            version: "0.1.6", date: "4 Nov 2026", title: "Agent usage at a glance",
            changes: [
                "See overall Claude Code and Codex token usage and estimated costs in USD and IDR.",
                "Cached log scans speed up repeat visits; exchange rates include an offline fallback.",
                "Read agent usage from the CLI with suica usage agents --json.",
            ]),
        ReleaseNote(
            version: "0.1.5", date: "3 Nov 2026", title: "Fewer Teams nudges",
            changes: [
                "Combine queued nudges for the same ticket into one Teams message.",
                "Approve a held group once to send its combined message.",
                "Held groups are rebuilt when a message leaves the group.",
            ]),
    ]
}
