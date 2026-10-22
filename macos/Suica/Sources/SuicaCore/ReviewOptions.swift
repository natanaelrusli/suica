import Foundation
import Observation

// MARK: - Document

/// `suica review options --json`: the skills and models an Agent Review can use.
public struct ReviewOptions: Codable, Equatable, Sendable {
    public let version: Int
    /// The CLI the models are for; nil when none is installed.
    public let cli: String?
    public let defaults: Defaults
    /// Review skills first, as the agent orders them.
    public let skills: [Skill]
    public let models: [Model]

    public struct Defaults: Codable, Equatable, Sendable {
        public let skill: String
        /// Nil for the CLI's own default.
        public let model: String?

        public init(skill: String, model: String?) {
            self.skill = skill
            self.model = model
        }
    }

    public struct Skill: Codable, Equatable, Sendable, Identifiable {
        /// As typed after the slash: `plugin:skill`, or a bare name for a personal skill.
        public let name: String
        public let description: String
        /// user or plugin.
        public let source: String
        public let plugin: String?
        /// Only the configured default can be missing.
        public let missing: Bool

        public var id: String { name }
        /// The part after the plugin, which is what a person recognises.
        public var shortName: String { name.split(separator: ":").last.map(String.init) ?? name }

        public init(name: String, description: String, source: String, plugin: String?, missing: Bool = false) {
            self.name = name
            self.description = description
            self.source = source
            self.plugin = plugin
            self.missing = missing
        }
    }

    public struct Model: Codable, Equatable, Sendable, Identifiable {
        public let name: String
        public let label: String
        public let description: String

        public var id: String { name }

        public init(name: String, label: String, description: String) {
            self.name = name
            self.label = label
            self.description = description
        }
    }

    public init(version: Int = 1, cli: String?, defaults: Defaults, skills: [Skill], models: [Model]) {
        self.version = version
        self.cli = cli
        self.defaults = defaults
        self.skills = skills
        self.models = models
    }

    /// The skills whose name or description contains every word of `query`, in the agent's order.
    public func skills(matching query: String) -> [Skill] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return skills }
        return skills.filter { skill in
            let text = "\(skill.name) \(skill.description)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    public func skill(named name: String) -> Skill? { skills.first { $0.name == name } }
    public func model(named name: String) -> Model? { models.first { $0.name == name } }
}

// MARK: - Choice

/// The skill and model the Owner picked for one review; nil means the config's.
public struct ReviewChoice: Equatable, Sendable {
    public var skill: String?
    public var model: String?
    /// Queued as an automatic review, so `review.maxPerDay` applies (`daily-cap` once it is used).
    public var automatic = false

    public init(skill: String? = nil, model: String? = nil, automatic: Bool = false) {
        self.skill = skill
        self.model = model
        self.automatic = automatic
    }

    /// What to send: a pick equal to the default is no pick, so the review follows a later config change.
    public func relative(to defaults: ReviewOptions.Defaults) -> ReviewChoice {
        ReviewChoice(
            skill: skill == defaults.skill ? nil : skill,
            model: model == defaults.model ? nil : model, automatic: automatic)
    }

    /// The agent's check of a model name: it reaches the CLI's argv, so it may not look like a flag.
    public static func isValidModel(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9][\w.:\[\]\/-]*/) != nil
    }

    /// The options of `suica review queue`.
    public var arguments: [String] {
        (skill.map { ["--skill", $0] } ?? []) + (model.map { ["--model", $0] } ?? []) + (automatic ? ["--auto"] : [])
    }
}

// MARK: - Loader

/// Reads the options when a picker opens; a failure keeps the last good document.
@MainActor @Observable
public final class ReviewOptionsLoader {
    public private(set) var options: ReviewOptions?
    public private(set) var errorText: String?
    public private(set) var loading = false
    @ObservationIgnored private let client: any ReviewsClient
    @ObservationIgnored private var latest = 0

    public init(client: any ReviewsClient) {
        self.client = client
    }

    /// `cli` names a Model CLI other than the saved one, such as an unsaved choice.
    public func load(cli: String? = nil) async {
        latest += 1
        let mine = latest
        loading = true
        defer { if mine == latest { loading = false } }
        do {
            let options = try await client.reviewOptions(cli: cli)
            guard mine == latest else { return }
            self.options = options
            errorText = nil
        } catch {
            guard mine == latest else { return }
            errorText = MenuModel.message(for: error)
        }
    }
}
