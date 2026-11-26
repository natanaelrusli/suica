import AppKit
import SuicaCore
import SwiftUI

private enum DevelopmentTab: String, CaseIterable { case ports = "Ports", worktrees = "Worktrees" }

struct DevelopmentCleanupView: View {
    let window: WindowModel
    @AppStorage("developmentCleanup.repositories") private var savedRepositories = ""
    @AppStorage("developmentCleanup.projectServersOnly") private var projectServersOnly = true
    @AppStorage("developmentCleanup.repositoriesWithWorktreesOnly") private var withWorktreesOnly = false
    @State private var tab: DevelopmentTab = CommandLine.arguments.contains("--development-cleanup-ui-fixture") ? .worktrees : .ports

    // Ports
    @State private var ports: PortScanDocument?
    @State private var query = ""
    @State private var selectedPort: PortListenerDocument?
    @State private var forceCandidate: PortListenerDocument?
    @State private var confirmingStop = false
    @State private var confirmingForce = false
    @State private var portBusy = false
    @State private var portError: String?
    @State private var portStatus: String?
    @State private var portRefreshID = UUID()

    // Worktrees
    @State private var worktrees: WorktreeScanDocument?
    @State private var repo = ""
    @State private var target = ""
    @State private var refreshedAt: String?
    @State private var refreshedTarget: String?
    @State private var selectedPaths: Set<String> = []
    @State private var sizeEstimate: Int64?
    @State private var worktreeCounts: [String: Int] = [:]
    @State private var confirmingRemoval = false
    @State private var confirmingPrune = false
    @State private var worktreeBusy = false
    @State private var worktreeError: String?
    @State private var worktreeStatus: String?
    @State private var worktreeRefreshID = UUID()
    @State private var discoveryID = UUID()
    @State private var discovering = false
    @State private var discoveryMessage: String?

    private var repositories: [String] { Array(Set(savedRepositories.split(separator: "\n").map(String.init))).sorted() }
    private var visibleRepositories: [String] {
        // Saved parent folders are rescanned on open; only actual checkouts are listed.
        let sorted = repositories.filter { isRepository($0) || $0 == repo }
            .sorted { (worktreeCounts[$0] ?? 0, $1) > (worktreeCounts[$1] ?? 0, $0) }
        return withWorktreesOnly ? sorted.filter { (worktreeCounts[$0] ?? 0) > 0 || $0 == repo } : sorted
    }
    /// Named after the main checkout, since a saved path can be one of its linked worktrees.
    private var selectedRepositoryName: String { URL(fileURLWithPath: worktrees?.entries.first?.path ?? repo).lastPathComponent }
    /// Linked worktrees with the actionable ones first: ready, then folder missing, then not merged, then kept.
    private var linkedEntries: [WorktreeEntryDocument] {
        let rank = ["merged": 0, "prunable": 1, "unverified": 2]
        return (worktrees?.entries.dropFirst() ?? []).enumerated()
            .sorted { (rank[$0.element.status] ?? 3, $0.offset) < (rank[$1.element.status] ?? 3, $1.offset) }
            .map(\.element)
    }
    private var selectedEntries: [WorktreeEntryDocument] { worktrees?.entries.filter { selectedPaths.contains($0.path) } ?? [] }
    private var eligibleEntries: [WorktreeEntryDocument] { worktrees?.entries.filter { $0.status == "merged" } ?? [] }
    private var prunableEntries: [WorktreeEntryDocument] { worktrees?.entries.filter { $0.status == "prunable" } ?? [] }
    private var remoteTarget: Bool { worktrees?.targetRef?.hasPrefix("refs/remotes/") == true }
    /// The agent refuses removal against a remote target unless it was fetched in the last five minutes.
    private var remoteTargetFresh: Bool {
        guard remoteTarget else { return true }
        guard refreshedTarget == worktrees?.entries.first?.target, let refreshedAt, let date = parseISODate(refreshedAt) else { return false }
        let age = Date().timeIntervalSince(date)
        // Well inside the agent's five minutes, so a batch of removals does not run past it.
        return age >= -30 && age <= 120
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageHeader
            if tab == .ports { portsPage } else { worktreesPage }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await refreshPorts() }
        .task {
            // Show what is already saved first; rescanning saved parent folders can take a while.
            await loadWorktreeCounts()
            if repo.isEmpty { repo = visibleRepositories.first(where: isRepository) ?? "" }
            await migrateSavedRepositories()
            await loadWorktreeCounts()
            if repo.isEmpty || !repositories.contains(repo) { repo = visibleRepositories.first ?? "" }
        }
        .onChange(of: selectedPaths) { _, _ in sizeEstimate = nil }
        .onChange(of: repo) { _, _ in
            worktreeRefreshID = UUID(); worktrees = nil; selectedPaths.removeAll(); sizeEstimate = nil
            refreshedAt = nil; refreshedTarget = nil; target = ""; worktreeError = nil; worktreeStatus = nil
            if !repo.isEmpty { Task { await refreshWorktrees() } }
        }
        .onSubmit(of: .text) {
            if tab == .worktrees, !repo.isEmpty { Task { await refreshWorktrees() } }
        }
        .confirmationDialog("Stop \(selectedPort.map(displayName) ?? "process")?", isPresented: $confirmingStop, titleVisibility: .visible, presenting: selectedPort) { listener in
            Button("Stop Process", role: .destructive) { Task { await stop(listener, force: false) } }
            Button("Cancel", role: .cancel) {}
        } message: { listener in
            Text(verbatim: "PID \(listener.pid) on port \(listener.ports.joined(separator: ", ")). Suica sends SIGTERM so the process can shut down cleanly.\n\n\(listener.command ?? listener.program)")
        }
        .confirmationDialog("Force quit \(forceCandidate.map(displayName) ?? "process")?", isPresented: $confirmingForce, titleVisibility: .visible, presenting: forceCandidate) { listener in
            Button("Force Quit", role: .destructive) { Task { await stop(listener, force: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { listener in
            Text(verbatim: "PID \(listener.pid) ignored SIGTERM. Force quitting sends SIGKILL; unsaved state in that process is lost.")
        }
        .confirmationDialog("Remove \(selectedEntries.count) worktree\(selectedEntries.count == 1 ? "" : "s")?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await removeSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalPreview)
        }
        .confirmationDialog("Prune \(prunableEntries.count) stale entr\(prunableEntries.count == 1 ? "y" : "ies")?", isPresented: $confirmingPrune, titleVisibility: .visible) {
            Button("Prune", role: .destructive) { Task { await prune() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These folders no longer exist. Pruning drops Git's records of them and keeps their branches:\n\n" + prunableEntries.map { "\($0.path) [\($0.branch ?? "detached")]" }.joined(separator: "\n"))
        }
    }

    // MARK: - Header

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ports & Worktrees").font(.title.bold()).accessibilityAddTraits(.isHeader)
                Text("Stop forgotten dev servers and clear out merged checkouts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("Ports and worktrees", selection: $tab) {
                ForEach(DevelopmentTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .accessibilityLabel("Ports and worktrees")
        }
    }

    // MARK: - Ports

    private var projectListeners: [PortListenerDocument] { (ports?.listeners ?? []).filter(isProjectListener) }

    /// A listener started from inside a project folder, as opposed to a daemon running from `/` or the home folder.
    private func isProjectListener(_ listener: PortListenerDocument) -> Bool {
        guard let cwd = listener.cwd else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home + "/") && !cwd.hasPrefix(home + "/Library/") && !cwd.hasPrefix(home + "/.")
    }

    private var filteredPorts: [PortListenerDocument] {
        let base = projectServersOnly ? projectListeners : (ports?.listeners ?? [])
        let rows = query.isEmpty ? base : base.filter {
            $0.ports.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || ($0.cwd ?? "").localizedCaseInsensitiveContains(query) || $0.program.localizedCaseInsensitiveContains(query)
                || ($0.command ?? "").localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }
        return rows.sorted { (startDate($0.startedAt) ?? .distantFuture) < (startDate($1.startedAt) ?? .distantFuture) }
    }

    private var portsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Show", selection: $projectServersOnly) {
                    Text("Project Servers").tag(true)
                    Text("All Listeners").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if let ports {
                    Text(verbatim: projectServersOnly ? "\(projectListeners.count) of \(ports.listeners.count)" : "\(ports.listeners.count)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                TextField("Filter by port, project or command", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshPorts() } }
                    .labelStyle(.iconOnly).help("Rescan listeners").disabled(portBusy)
                    .keyboardShortcut("r", modifiers: .command)
            }
            if let portError { NoticeBox(text: portError, tint: .red) { self.portError = nil } }
            if let portStatus { NoticeBox(text: portStatus, tint: .green) { self.portStatus = nil } }
            if let ports {
                if ports.status == "partial", !projectServersOnly { NoticeBox(text: ports.error ?? "Some listener details could not be read.", tint: .orange) }
                if filteredPorts.isEmpty {
                    if !query.isEmpty { ContentUnavailableView.search(text: query) }
                    else {
                        ContentUnavailableView(projectServersOnly ? "No project servers running" : "No TCP listeners",
                            systemImage: "checkmark.seal",
                            description: Text(projectServersOnly ? "Nothing started from a project folder is listening. Switch to All listeners to see system services." : "Nothing on this Mac is accepting TCP connections."))
                    }
                } else {
                    List(filteredPorts) { portRow($0) }.listStyle(.inset).overlay(alignment: .top) { if portBusy { ProgressView().controlSize(.small).padding(6) } }
                    Text("Oldest first. Age and folder help you recognise a forgotten server; neither proves it is unused.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if portBusy { ProgressView("Scanning listeners…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func displayName(_ listener: PortListenerDocument) -> String {
        isProjectListener(listener) ? listener.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? listener.program : listener.program
    }

    private func portRow(_ listener: PortListenerDocument) -> some View {
        let mine = listener.owner == String(getuid())
        let age = processAge(listener.startedAt)
        let stale = (startDate(listener.startedAt).map { Date().timeIntervalSince($0) } ?? 0) > 86_400
        let shownPorts = listener.ports.prefix(4)
        return HStack(alignment: .center, spacing: 14) {
            Text(":\(listener.ports.first ?? "?")")
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tint)
                .frame(minWidth: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(displayName(listener)).font(.headline).lineLimit(1)
                    if listener.protected { Label("Suica", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                    if listener.ports.count > 1 {
                        Text(shownPorts.dropFirst().map { ":\($0)" }.joined(separator: " ") + (listener.ports.count > 4 ? " +\(listener.ports.count - 4) more" : ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            .help(listener.ports.joined(separator: ", "))
                    }
                }
                Text(listener.command ?? listener.program)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(listener.command ?? listener.program).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(verbatim: "\(listener.program) · PID \(listener.pid)")
                    Text("·")
                    Text("up \(age)").foregroundStyle(stale ? Color.orange : Color.secondary)
                    if let cwd = listener.cwd, !isProjectListener(listener) { Text("· \(cwd)").lineLimit(1).truncationMode(.middle) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let port = listener.ports.first, isProjectListener(listener), let url = URL(string: "http://localhost:\(port)") {
                Button("Open", systemImage: "safari") { NSWorkspace.shared.open(url) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Open http://localhost:\(port)")
            }
            if let cwd = listener.cwd, cwd != "/" {
                Button("Reveal", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Show \(cwd) in Finder")
            }
            Button("Stop…") { selectedPort = listener; confirmingStop = true }
                .disabled(!mine || listener.protected || portBusy)
                .help(listener.protected ? "Suica's own process" : !mine ? "Owned by another user" : "Send SIGTERM to PID \(listener.pid)")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy PID") { copy(String(listener.pid)) }
            if let command = listener.command { Button("Copy Command") { copy(command) } }
            if let cwd = listener.cwd { Button("Copy Folder Path") { copy(cwd) } }
        }
    }

    // MARK: - Worktrees

    private var worktreesPage: some View {
        Group {
            if repositories.isEmpty {
                repositoryEmptyState
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        repositoryList.frame(width: 260)
                        populatedWorktreesPage.frame(minWidth: 520)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        repositoryList.frame(height: 190)
                        populatedWorktreesPage
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var repositoryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Repositories").font(.headline)
                Spacer()
                Menu {
                    Button("Add Repository…", systemImage: "folder.badge.plus", action: chooseRepository)
                    Button("Discover in Folder…", systemImage: "magnifyingglass", action: discoverRepositories)
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(discovering).help("Add repositories")
            }
            Toggle("Only with worktrees", isOn: $withWorktreesOnly).toggleStyle(.checkbox).font(.caption)
            if discovering { ProgressView().controlSize(.small) }
            if let discoveryMessage { Text(discoveryMessage).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleRepositories, id: \.self) { path in repositoryRow(path) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }

    private func repositoryRow(_ path: String) -> some View {
        let selected = repo == path
        let count = worktreeCounts[path] ?? 0
        let name = URL(fileURLWithPath: path).lastPathComponent
        return Button { repo = path } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                    Text(URL(fileURLWithPath: path).deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)").font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityLabel("\(name), \(count) linked worktrees")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
        }
    }

    private var repositoryEmptyState: some View {
        ContentUnavailableView {
            Label("Add your repositories", systemImage: "folder.badge.plus")
        } description: {
            Text("Pick a projects folder and Suica finds every Git repository inside it, then shows which linked worktrees are merged and safe to remove.")
        } actions: {
            Button("Discover Repositories in Folder…", action: discoverRepositories).buttonStyle(.borderedProminent).controlSize(.large).disabled(discovering)
            Button("Add a Single Repository…", action: chooseRepository).disabled(discovering)
            if discovering { ProgressView("Scanning…").controlSize(.small) }
            if let discoveryMessage { Text(discoveryMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var populatedWorktreesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(repo.isEmpty ? "Select a repository" : selectedRepositoryName).font(.title3.bold()).lineLimit(1).help(repo)
                if let worktrees, worktrees.status == "ok" {
                    summaryChip("\(eligibleEntries.count) ready", .green)
                    let blocked = worktrees.entries.count - 1 - eligibleEntries.count - prunableEntries.count
                    if blocked > 0 { summaryChip("\(blocked) kept", .secondary) }
                    if !prunableEntries.isEmpty { summaryChip("\(prunableEntries.count) stale", .orange) }
                }
                Spacer(minLength: 4)
                if worktreeBusy { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshWorktrees() } }
                    .labelStyle(.iconOnly).help("Rescan worktrees").disabled(repo.isEmpty || worktreeBusy)
            }
            HStack(spacing: 8) {
                TextField("Merge target, e.g. origin/main", text: $target).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .help("Branch that finished work is merged into. Press Return to recheck.")
                Button("Fetch", systemImage: "arrow.down.circle") { Task { await fetchTarget() } }
                    .disabled(target.isEmpty || worktreeBusy || !remoteTarget)
                    .help(remoteTarget ? "Fetch the remote so merge checks use its latest tip" : "Local branch, nothing to fetch")
                Text(targetFreshness).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let worktreeError { NoticeBox(text: worktreeError, tint: .red) { self.worktreeError = nil } }
            if let worktreeStatus { NoticeBox(text: worktreeStatus, tint: .green) { self.worktreeStatus = nil } }
            if !prunableEntries.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(prunableEntries.count) worktree folder\(prunableEntries.count == 1 ? " was" : "s were") deleted outside Git and still clutter the list.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Prune…") { confirmingPrune = true }.disabled(worktreeBusy)
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            if let worktrees {
                if worktrees.entries.count <= 1, worktrees.status == "ok" {
                    ContentUnavailableView("No linked worktrees", systemImage: "checkmark.seal", description: Text("Only the main checkout exists here; nothing to clean up."))
                } else {
                    List {
                        ForEach(linkedEntries, id: \.path) { worktreeRow($0) }
                    }
                    .listStyle(.inset)
                }
            } else if worktreeBusy {
                ProgressView("Checking worktrees…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Button(selectedEntries.count == eligibleEntries.count && !eligibleEntries.isEmpty ? "Deselect All" : "Select All Ready") {
                    selectedPaths = selectedEntries.count == eligibleEntries.count ? [] : Set(eligibleEntries.map(\.path))
                }
                .disabled(eligibleEntries.isEmpty || worktreeBusy)
                Button("Estimate Size") { Task { await estimateSelectedSize() } }.disabled(selectedEntries.isEmpty || worktreeBusy)
                if let sizeEstimate { Text("≈ \(ByteCountFormatter.string(fromByteCount: sizeEstimate, countStyle: .file))").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                Spacer()
                if let blocker = removalBlocker { Text(blocker).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Button((remoteTargetFresh ? "Remove" : "Fetch & Remove") + (selectedEntries.isEmpty ? "…" : " \(selectedEntries.count)…")) {
                    Task {
                        if !remoteTargetFresh { await fetchTarget() }
                        if remoteTargetFresh, !selectedEntries.isEmpty { confirmingRemoval = true }
                    }
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(removalBlocker != nil || selectedEntries.isEmpty || worktreeBusy)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
    }

    private var removalBlocker: String? {
        if worktreeBusy { return nil }
        if worktrees?.status != "ok" { return worktrees == nil ? nil : "Fix the scan error first." }
        if selectedEntries.isEmpty { return eligibleEntries.isEmpty ? "No merged, clean worktrees to remove." : "Select worktrees to remove." }
        return nil
    }

    private var targetFreshness: String {
        guard worktrees != nil else { return "" }
        guard remoteTarget else { return "Local branch" }
        guard refreshedTarget == worktrees?.entries.first?.target, let refreshedAt, let date = parseISODate(refreshedAt) else { return "Not fetched this session" }
        return "Fetched \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))"
    }

    private func summaryChip(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var removalPreview: String {
        let rows = selectedEntries.map { "\($0.path) [\($0.branch ?? "detached")]" }
        let size = sizeEstimate.map { "About \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) on disk (approximate)." } ?? "Size not estimated."
        return (rows + ["", "Branches are kept. Each checkout is rechecked just before removal and skipped if anything changed.", size]).joined(separator: "\n")
    }

    private func worktreeRow(_ entry: WorktreeEntryDocument) -> some View {
        let (label, tint, symbol): (String, Color, String) = switch entry.status {
        case "merged": ("Ready", .green, "checkmark.circle.fill")
        case "prunable": ("Folder missing", .orange, "questionmark.folder")
        case "unverified": ("Unverified", .secondary, "arrow.triangle.branch")
        default: ("Kept", .secondary, "lock")
        }
        let reason = switch entry.status {
        case "merged": "Merged into \(entry.target); clean."
        case "unverified": "HEAD is not in \(entry.target). Squash or rebase merges cannot be confirmed, so it is kept."
        default: entry.reason ?? "Not eligible for removal."
        }
        let isSelected = Binding(
            get: { selectedPaths.contains(entry.path) },
            set: { if $0 { selectedPaths.insert(entry.path) } else { selectedPaths.remove(entry.path) } })
        return HStack(alignment: .top, spacing: 10) {
            Toggle("Select \(entry.branch ?? entry.path)", isOn: isSelected).toggleStyle(.checkbox).labelsHidden()
                .disabled(entry.status != "merged" || worktreeBusy)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.branch ?? "Detached HEAD").font(.headline).lineLimit(1)
                    Label(label, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
                }
                Text(entry.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                Text(reason).font(.caption).foregroundStyle(entry.status == "merged" ? Color.secondary : tint == .orange ? Color.orange : Color.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if !entry.ignoredOutput.isEmpty, entry.status == "merged" {
                    Label("Also deletes \(entry.ignoredOutput.prefix(4).joined(separator: ", "))\(entry.ignoredOutput.count > 4 ? " +\(entry.ignoredOutput.count - 4)" : "")", systemImage: "shippingbox")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if entry.status != "prunable" {
                Button("Reveal", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.path) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Show in Finder")
            }
        }
        .padding(.vertical, 3)
        .contextMenu { Button("Copy Path") { copy(entry.path) } }
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func chooseRepository() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a repository or a parent folder containing repositories."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startDiscovery(in: url.standardizedFileURL.resolvingSymlinksInPath().path, selectFirst: true)
    }

    private func discoverRepositories() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to scan for local Git repositories."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startDiscovery(in: url.standardizedFileURL.resolvingSymlinksInPath().path, selectFirst: false)
    }

    private func startDiscovery(in root: String, selectFirst: Bool) {
        let requestID = UUID(); discoveryID = requestID
        discovering = true; discoveryMessage = "Scanning \(root)…"; worktreeError = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                GitRepositoryDiscovery.find(in: root)
            }.value
            guard discoveryID == requestID else { return }
            mergeDiscovery(result, root: root, selectFirst: selectFirst)
            await loadWorktreeCounts()
        }
    }

    private func mergeDiscovery(_ result: GitRepositoryDiscoveryResult, root: String, selectFirst: Bool) {
        let current = repositories
        let candidates = selectFirst ? result.repositories + current : current + result.repositories
        let merged = GitRepositoryDiscovery.deduplicatedRepositories(candidates)
        if merged != current { savedRepositories = merged.joined(separator: "\n") }
        discovering = false
        let added = merged.count - current.count
        var details = added > 0
            ? "Added \(added) repositories from \(root)."
            : "No new Git repositories found under \(root)."
        details += " Scanned \(result.directoriesScanned) folders."
        if result.inaccessibleDirectories > 0 { details += " \(result.inaccessibleDirectories) folders could not be read; results may be incomplete." }
        if result.truncated { details += " The scan reached its folder limit; choose a narrower folder to continue." }
        discoveryMessage = details
        if selectFirst, let first = result.repositories.first { repo = first }
        else if repo.isEmpty { repo = merged.first ?? "" }
    }

    private func isRepository(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path)
    }

    private func loadWorktreeCounts() async {
        let paths = repositories
        let counts = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: paths.map { ($0, GitRepositoryDiscovery.linkedWorktreeCount($0)) })
        }.value
        worktreeCounts = counts
        if !counts.values.contains(where: { $0 > 0 }) { withWorktreesOnly = false }
    }

    private func migrateSavedRepositories() async {
        let original = repositories
        guard !original.isEmpty else { return }
        discovering = true
        discoveryMessage = "Checking saved repository folders…"
        var migrated: [String] = []
        var partial = false
        for savedPath in original {
            let pathURL = URL(fileURLWithPath: savedPath).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            let gitMarker = pathURL.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitMarker.path, isDirectory: &isDirectory) {
                migrated = GitRepositoryDiscovery.deduplicatedRepositories(migrated + [pathURL.path])
                continue
            }
            let alreadySaved = migrated
            let result = await Task.detached(priority: .utility) {
                GitRepositoryDiscovery.find(in: pathURL.path, alreadySaved: alreadySaved)
            }.value
            migrated.append(contentsOf: result.repositories.filter { !migrated.contains($0) })
            if result.inaccessibleDirectories > 0 || result.truncated {
                partial = true
                if !migrated.contains(pathURL.path) { migrated.append(pathURL.path) }
            }
        }
        let deduplicated = Array(Set(migrated)).sorted()
        if deduplicated != original { savedRepositories = deduplicated.joined(separator: "\n") }
        discovering = false
        discoveryMessage = partial ? "Repository discovery was incomplete. Saved folders with scan problems were kept; use Discover in Folder to retry." : nil
    }

    private func refreshPorts() async {
        let requestID = UUID(); portRefreshID = requestID
        portBusy = true
        do {
            let fresh = try await window.listDevelopmentPorts()
            guard portRefreshID == requestID else { return }
            ports = fresh
            portError = fresh.status == "failed" ? fresh.error ?? "Listener scan failed." : nil
        } catch { if portRefreshID == requestID { portError = String(describing: error) } }
        if portRefreshID == requestID { portBusy = false }
    }

    private func stop(_ listener: PortListenerDocument, force: Bool) async {
        portBusy = true; portError = nil; portStatus = nil
        do {
            let result = try await window.stopDevelopmentPort(listener, force: force)
            if result.status == "stopped" { portStatus = "Stopped \(displayName(listener)) (PID \(listener.pid)); port \(listener.ports.joined(separator: ", ")) is free." }
            else { portError = result.message }
            portBusy = false
            await refreshPorts()
            if result.status == "still-running", !force, let fresh = ports?.listeners.first(where: { $0.id == listener.id }) {
                forceCandidate = fresh; confirmingForce = true
            }
        } catch { portError = String(describing: error); portBusy = false }
    }

    private func refreshWorktrees() async {
        guard !repo.isEmpty else { return }
        let requestID = UUID(), requestedRepo = repo, requestedTarget = target
        worktreeRefreshID = requestID
        worktreeBusy = true
        do {
            let fresh = try await window.listDevelopmentWorktrees(repo: requestedRepo, target: requestedTarget.isEmpty ? nil : requestedTarget)
            guard worktreeRefreshID == requestID, repo == requestedRepo else { return }
            if target.isEmpty { target = fresh.entries.first?.target ?? fresh.defaultTarget ?? "" }
            if fresh.entries.first?.target != refreshedTarget { refreshedAt = nil; refreshedTarget = nil }
            let oldIdentities = Dictionary(uniqueKeysWithValues: (worktrees?.entries ?? []).map { ($0.path, $0.id) })
            selectedPaths = Set(selectedPaths.filter { path in fresh.entries.contains(where: { $0.path == path && $0.status == "merged" && oldIdentities[path] == $0.id }) })
            worktrees = fresh
            worktreeCounts[requestedRepo] = max(0, fresh.entries.count - 1)
            worktreeError = fresh.status == "ok" ? nil : fresh.error ?? "Repository scan failed."
        } catch { if worktreeRefreshID == requestID { worktreeError = String(describing: error) } }
        if worktreeRefreshID == requestID { worktreeBusy = false }
    }

    private func fetchTarget() async {
        worktreeBusy = true; worktreeError = nil
        do {
            let result = try await window.fetchDevelopmentWorktreeTarget(repo: repo, target: target)
            worktreeBusy = false
            if result.status == "fetched" { refreshedAt = result.refreshedAt; refreshedTarget = result.target; await refreshWorktrees() }
            else { refreshedAt = nil; refreshedTarget = nil; worktreeError = result.error ?? "Fetch failed." }
        } catch { worktreeError = String(describing: error); worktreeBusy = false }
    }

    private func estimateSelectedSize() async {
        worktreeBusy = true
        let paths = selectedEntries.map(\.path)
        sizeEstimate = await Task.detached(priority: .utility) {
            paths.reduce(Int64(0)) { total, path in
                let url = URL(fileURLWithPath: path)
                let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return total }
                return total + enumerator.reduce(Int64(0)) { sum, item in
                    guard let file = item as? URL, let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return sum }
                    return sum + Int64(values.totalFileAllocatedSize ?? 0)
                }
            }
        }.value
        worktreeBusy = false
    }

    private func removeSelected() async {
        guard !repo.isEmpty else { return }
        worktreeBusy = true; worktreeError = nil; worktreeStatus = nil
        var removed = 0
        var skipped: [String] = []
        for entry in selectedEntries {
            do {
                let result = try await window.removeDevelopmentWorktree(repo: repo, entry: entry, refreshedAt: refreshedAt)
                if result.status == "removed" { removed += 1 } else { skipped.append("\(entry.branch ?? entry.path): \(result.reason ?? "skipped")") }
            } catch { skipped.append("\(entry.branch ?? entry.path): \(error)") }
        }
        if removed > 0 { worktreeStatus = "Removed \(removed) worktree\(removed == 1 ? "" : "s"); branches kept." }
        if !skipped.isEmpty { worktreeError = "Skipped \(skipped.count):\n" + skipped.joined(separator: "\n") }
        selectedPaths.removeAll(); sizeEstimate = nil
        worktreeBusy = false
        await refreshWorktrees()
    }

    private func prune() async {
        worktreeBusy = true; worktreeError = nil; worktreeStatus = nil
        do {
            let result = try await window.pruneDevelopmentWorktrees(repo: repo)
            if result.status == "pruned" { worktreeStatus = "Pruned \(result.pruned.count) stale entr\(result.pruned.count == 1 ? "y" : "ies")." }
            else { worktreeError = result.error ?? "Prune failed." }
        } catch { worktreeError = String(describing: error) }
        worktreeBusy = false
        await refreshWorktrees()
    }

    // MARK: - Formatting

    private func startDate(_ startedAt: String?) -> Date? {
        guard let startedAt else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        // ps pads single-digit days with a second space ("Nov  3").
        return formatter.date(from: startedAt.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
    }

    private func processAge(_ startedAt: String?) -> String {
        guard let date = startDate(startedAt) else { return startedAt ?? "unknown" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    private func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
