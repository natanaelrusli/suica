import Foundation

public struct ClaudeSkill: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case personal, disabled, plugin(String)

        public var isPersonal: Bool {
            switch self {
            case .personal, .disabled: true
            case .plugin: false
            }
        }
    }

    public let directory: URL
    public let source: Source

    public var id: URL { directory }
    public var name: String { directory.lastPathComponent }
    public var file: URL { directory.appendingPathComponent("SKILL.md") }
}

public actor ClaudeSkillLibrary {
    public enum Failure: LocalizedError {
        case invalidFolder, nameInUse, missingSkill, readOnly, previewUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidFolder: Copy.skillInvalidFolder
            case .nameInUse: Copy.skillNameInUse
            case .missingSkill: Copy.skillMissing
            case .readOnly: Copy.skillReadOnly
            case .previewUnavailable: Copy.skillPreviewUnavailable
            }
        }
    }

    private let root: URL
    private let files = FileManager.default
    private var personal: URL { root.appendingPathComponent("skills", isDirectory: true) }
    private var disabled: URL { root.appendingPathComponent(".suica-disabled-skills", isDirectory: true) }

    public init(configDirectory: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        root = (configDirectory ?? configured ?? home.appendingPathComponent(".claude", isDirectory: true))
            .standardizedFileURL
    }

    public func list() throws -> [ClaudeSkill] {
        try skills(in: personal, source: .personal) + skills(in: disabled, source: .disabled) + pluginSkills()
    }

    public func preview(_ skill: ClaudeSkill) throws -> String {
        let file = skill.file.resolvingSymlinksInPath()
        guard hasSkillFile(in: skill.directory) else { throw Failure.missingSkill }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let limit = 1_000_000
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
            throw Failure.previewUnavailable
        }
        return text
    }

    public func importSkill(from folder: URL) throws -> URL {
        let name = folder.lastPathComponent
        let source = folder.resolvingSymlinksInPath().standardizedFileURL
        let skillsPath = personal.resolvingSymlinksInPath().standardizedFileURL.path
        guard Self.isPersonalName(name), hasSkillFile(in: source),
            skillsPath != source.path, !skillsPath.hasPrefix(source.path + "/")
        else { throw Failure.invalidFolder }

        try files.createDirectory(at: personal, withIntermediateDirectories: true)
        let destination = personal.appendingPathComponent(name, isDirectory: true)
        let disabledCopy = disabled.appendingPathComponent(name, isDirectory: true)
        guard !exists(destination), !exists(disabledCopy) else { throw Failure.nameInUse }

        // Install the whole folder at once so Claude never sees a partial copy.
        let staging = personal.appendingPathComponent(".suica-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        guard hasSkillFile(in: staging) else { throw Failure.invalidFolder }
        try files.moveItem(at: staging, to: destination)
        return destination
    }

    public func toggle(_ skill: ClaudeSkill) throws -> URL {
        let source = try personalDirectory(for: skill)
        let destinationRoot = skill.source == .personal ? disabled : personal
        try files.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let destination = destinationRoot.appendingPathComponent(skill.name, isDirectory: true)
        guard !exists(destination) else { throw Failure.nameInUse }
        try files.moveItem(at: source, to: destination)
        return destination
    }

    public func trash(_ skill: ClaudeSkill) throws {
        try files.trashItem(at: personalDirectory(for: skill), resultingItemURL: nil)
    }

    private func personalDirectory(for skill: ClaudeSkill) throws -> URL {
        guard skill.source.isPersonal, Self.isPersonalName(skill.name) else { throw Failure.readOnly }
        let parent = skill.source == .personal ? personal : disabled
        let directory = parent.appendingPathComponent(skill.name, isDirectory: true)
        guard directory.path == skill.directory.path, hasSkillFile(in: directory) else { throw Failure.missingSkill }
        return directory
    }

    private static func isPersonalName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
            && !["synced", "anthropic-skills"].contains(name.lowercased())
    }

    private func exists(_ url: URL) -> Bool {
        files.fileExists(atPath: url.path) || (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func hasSkillFile(in directory: URL) -> Bool {
        let file = directory.appendingPathComponent("SKILL.md").resolvingSymlinksInPath()
        return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func skills(in folder: URL, source: ClaudeSkill.Source) throws -> [ClaudeSkill] {
        let children: [URL]
        do {
            children = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        return children.compactMap { child in
            let name = child.lastPathComponent
            // Keep the path as addressed through this library, including symlinked folders.
            let directory = folder.appendingPathComponent(name, isDirectory: true)
            guard (!source.isPersonal || Self.isPersonalName(name)), hasSkillFile(in: directory) else {
                return nil
            }
            return ClaudeSkill(directory: directory, source: source)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct PluginRegistry: Decodable {
        struct Installation: Decodable {
            var scope: String?
            var installPath: String
        }

        var plugins: [String: [Installation]]
    }

    private func pluginSkills() -> [ClaudeSkill] {
        let index = root.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: index),
            let registry = try? JSONDecoder().decode(PluginRegistry.self, from: data)
        else { return [] }
        var seen: Set<URL> = []
        return registry.plugins.keys.sorted().flatMap { plugin -> [ClaudeSkill] in
            guard let installs = registry.plugins[plugin] else { return [] }
            let name = plugin.components(separatedBy: "@")[0]
            return installs.filter { ($0.scope ?? "user") == "user" && $0.installPath.hasPrefix("/") }.flatMap { install in
                let directory = URL(fileURLWithPath: install.installPath, isDirectory: true).appendingPathComponent("skills")
                return (try? skills(in: directory, source: .plugin(name))) ?? []
            }
        }
        .filter { seen.insert($0.id).inserted }
    }
}
