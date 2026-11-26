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
            version: "0.1.18", date: "26 Nov 2026", title: "Development cleanup",
            changes: [
                "New Development cleanup page lists listening ports and git worktrees across your repositories.",
                "Stop a port's process, and fetch, prune or remove worktrees from the page.",
                "New `suica ports` and `suica worktrees` commands expose the same data as JSON.",
            ]),
        ReleaseNote(
            version: "0.1.17", date: "26 Nov 2026", title: "Run suica on a VPS from another machine",
            changes: [
                "New `suica-remote` command runs the suica CLI on a VPS over SSH with a key. Install it with `make install-remote`.",
            ]),
        ReleaseNote(
            version: "0.1.16", date: "25 Nov 2026", title: "Reviews skip generated files",
            changes: [
                "The Agent review ignores generated files: protobuf output, lockfiles, build output, snapshots, mocks and golden contracts.",
                "Ignored files no longer count toward the size cap, so large MRs made mostly of generated files get reviewed.",
                "The Agent review tab lists which files were reviewed and which were ignored; ignored files carry a badge in Changes.",
            ]),
        ReleaseNote(
            version: "0.1.15", date: "19 Nov 2026", title: "Adjustable glass and a clearer sidebar",
            changes: [
                "Turn glass on or off and adjust its opacity in Appearance. Suica respects macOS Reduce Transparency.",
                "The title bar gradient spans the sidebar and main pane, and sidebar rows scroll between the pinned header and footer.",
                "Overview opens with its summary tiles. Agent health is shown in the sidebar.",
            ]),
        ReleaseNote(
            version: "0.1.14", date: "19 Nov 2026", title: "Claude skills and a more useful sidebar",
            changes: [
                "Browse and preview Claude skills. Import, edit, disable, restore, or move personal skills to the Trash.",
                "See agent health, ongoing reviews, the installed version, CPU usage, RAM used, and fan speed in the sidebar.",
                "The sidebar and Overview check for review activity every three seconds while the window is open.",
                "Reveal older release notes in Updates, down to Suica 0.1.1.",
            ]),
        ReleaseNote(
            version: "0.1.13", date: "17 Nov 2026", title: "Empty files no longer block reviews",
            changes: [
                "An MR that adds or deletes an empty file, such as an `__init__.py`, can now be reviewed instead of failing as an unsupported empty diff.",
            ]),
        ReleaseNote(
            version: "0.1.12", date: "16 Nov 2026", title: "Faster, steadier MR reviews",
            changes: [
                "MR pages open from cached details, and repeated reads of the same MR are shared instead of fetched again.",
                "Large diffs and long Markdown are prepared off the main thread, so the page stays responsive while they open.",
                "On a narrow window the MR list and the MR take turns, with a Back button.",
                "Agent Reviews use a fixed Suica layout that ends in a ready-to-approve verdict, and a review that says no is never approved.",
            ]),
        ReleaseNote(
            version: "0.1.11", date: "12 Nov 2026", title: "Fairer approvals, quieter Teams",
            changes: [
                "Reviews no longer stay unapproved over items that only wait on a CI run or a device check; a CI item is lifted once the head pipeline is green.",
                "A burst of pushes now sends one re-review chat about the latest review, with what is still open from earlier ones.",
                "Review Notices for MRs of one ticket go out as one chat, and an approved review sends a single message.",
            ]),
        ReleaseNote(
            version: "0.1.10", date: "12 Nov 2026", title: "A clearer view of updates",
            changes: [
                "The Updates page fills the window, with release cards that adapt to its width.",
                "Read changelog summaries for the last five versions offline, with links to each release.",
                "Clearer checking, installation and error states make the next action easier to find.",
            ]),
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
        ReleaseNote(
            version: "0.1.4", date: "29 Oct 2026", title: "A local Idea Box",
            changes: [
                "Capture ideas in Suica’s Idea Box.",
            ]),
        ReleaseNote(
            version: "0.1.3", date: "29 Oct 2026", title: "See which lessons reach agents",
            changes: [
                "Suica records which lessons are delivered through hooks and the MCP server.",
                "See lesson usage in the app or find counts by project with `suica lessons usage`.",
            ]),
        ReleaseNote(
            version: "0.1.2", date: "28 Oct 2026", title: "Explore and export lessons",
            changes: [
                "Explore how lessons connect in the lessons graph.",
                "Export lessons as a ZIP archive.",
            ]),
        ReleaseNote(
            version: "0.1.1", date: "28 Oct 2026", title: "In-app updates",
            changes: [
                "Check for and install Suica releases from the Updates page.",
                "Suica verifies the release signature and download checksum before installation.",
            ]),
    ]
}
