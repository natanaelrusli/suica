import AppKit
import Foundation

public struct IdeaNote: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let createdAt: Int
}

public struct IdeaSessionLink: Codable, Equatable, Identifiable, Sendable {
    public let agent: String
    public let sessionId: String
    public let linkedAt: Int
    public var id: String { "\(agent)/\(sessionId)" }
}

public struct Idea: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let projectPath: String?
    public let createdAt: Int
    public let updatedAt: Int
    public let archivedAt: Int?
    public let revision: Int
    public let notes: [IdeaNote]
    public let planPaths: [String]
    public let sessions: [IdeaSessionLink]
}

public struct IdeaListDocument: Decodable, Equatable, Sendable {
    public let status: String
    public let ideas: [Idea]
}


public struct IdeaMutationDocument: Decodable, Equatable, Sendable {
    public let status: String
    public let idea: Idea?
    public let message: String?
}

public struct IdeaPromptDocument: Decodable, Equatable, Sendable {
    public let status: String
    public let prompt: String?
    public let length: Int?
    public let maxLength: Int?
    public let withinLimit: Bool?
    public let message: String?
}

public protocol IdeasClient: Sendable {
    func ideas(archived: Bool) async throws(AgentError) -> IdeaListDocument
    func createIdea(text: String, projectPath: String?) async throws(AgentError) -> IdeaMutationDocument
    func updateIdea(id: Int, revision: Int, text: String, projectPath: String?) async throws(AgentError) -> IdeaMutationDocument
    func setIdeaArchived(id: Int, archived: Bool) async throws(AgentError) -> IdeaMutationDocument
    func addIdeaNote(id: Int, text: String) async throws(AgentError) -> IdeaMutationDocument
    func linkIdeaPlan(id: Int, path: String) async throws(AgentError) -> IdeaMutationDocument
    func linkIdeaSession(id: Int, agent: String, sessionId: String) async throws(AgentError) -> IdeaMutationDocument
    func ideaPrompt(ids: [Int], question: String?) async throws(AgentError) -> IdeaPromptDocument
}

@MainActor @Observable
public final class IdeasModel {
    public private(set) var ideas: [Idea] = []
    public private(set) var selectedId: Int?
    public var archived = false
    public var query = ""
    public var draft = ""
    public var projectPath = ""
    public var noteDraft = ""
    public var promptQuestion = "" {
        didSet {
            if promptQuestion != oldValue {
                promptRevision += 1
                prompt = nil
            }
        }
    }
    public var selectedIDs: Set<Int> = []
    public private(set) var prompt: IdeaPromptDocument?
    public private(set) var busy = false
    public private(set) var errorText: String?
    public private(set) var notice: String?
    public private(set) var hasConflict = false
    @ObservationIgnored private var promptRevision = 0
    @ObservationIgnored private let client: any IdeasClient

    public init(client: any IdeasClient) { self.client = client }

    public func reportError(_ message: String?) { errorText = message }
    public var selected: Idea? { ideas.first { $0.id == selectedId } }
    public var matches: [Idea] {
        guard !query.isEmpty else { return ideas }
        return ideas.filter { idea in
            idea.text.localizedCaseInsensitiveContains(query)
                || (idea.projectPath?.localizedCaseInsensitiveContains(query) ?? false)
                || idea.notes.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    public func load() async {
        do {
            ideas = try await client.ideas(archived: archived).ideas
            selectedIDs.formIntersection(Set(ideas.map(\.id)))
            if let selectedId, !ideas.contains(where: { $0.id == selectedId }) { select(nil) }
            errorText = nil
        } catch { errorText = MenuModel.message(for: error) }
    }

    public func select(_ id: Int?) {
        selectedId = id
        hasConflict = false
        if let idea = ideas.first(where: { $0.id == id }) {
            draft = idea.text
            projectPath = idea.projectPath ?? ""
        }
    }

    public func reloadCurrent() async {
        guard let id = selectedId else { return }
        await load()
        selectedId = nil
        select(id)
    }

    public func toggleSelection(_ id: Int) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    public func create() async -> Bool {
        guard !busy else { return false }
        busy = true
        archived = false
        errorText = nil
        defer { busy = false }
        do {
            let reply = try await client.createIdea(text: draft, projectPath: projectPath.isEmpty ? nil : projectPath)
            guard reply.status == "ok", let idea = reply.idea else {
                errorText = reply.message ?? "Could not save this idea."
                return false
            }
            await load()
            select(idea.id)
            notice = nil
            return true
        } catch { errorText = MenuModel.message(for: error); return false }
    }

    public func save() async -> Bool {
        guard let idea = selected, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let reply = try await client.updateIdea(
                id: idea.id, revision: idea.revision, text: draft, projectPath: projectPath.isEmpty ? nil : projectPath)
            guard reply.status == "ok", let updated = reply.idea else {
                hasConflict = reply.status == "conflict"
                errorText = hasConflict ? "This idea changed elsewhere. Your draft is preserved until you reload the saved version." : (reply.message ?? "Could not save this idea.")
                return false
            }
            hasConflict = false
            await load(); select(updated.id); errorText = nil
            return true
        } catch { errorText = MenuModel.message(for: error); return false }
    }

    public func setArchived(_ value: Bool) async {
        guard let idea = selected, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await client.setIdeaArchived(id: idea.id, archived: value)
            guard reply.status == "ok" else { errorText = reply.message ?? "Could not update archive state."; return }
            selectedId = nil
            await load()
        } catch { errorText = MenuModel.message(for: error) }
    }

    public func addNote() async {
        guard let idea = selected, !noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await client.addIdeaNote(id: idea.id, text: noteDraft)
            guard reply.status == "ok" else { errorText = reply.message ?? "Could not save note."; return }
            noteDraft = ""; await load()
        } catch { errorText = MenuModel.message(for: error) }
    }

    public func linkPlan(_ path: String) async {
        guard let idea = selected, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await client.linkIdeaPlan(id: idea.id, path: path)
            guard reply.status == "ok" else { errorText = reply.message ?? "Could not link plan."; return }
            await load()
        } catch { errorText = MenuModel.message(for: error) }
    }

    public func buildPrompt() async {
        let ids = selectedIDs.isEmpty ? selectedId.map { [$0] } ?? [] : selectedIDs.sorted()
        guard !ids.isEmpty else { errorText = "Select at least one idea."; return }
        guard !busy else { return }
        let question = promptQuestion
        let revision = promptRevision
        busy = true
        defer { busy = false }
        prompt = nil
        do {
            let reply = try await client.ideaPrompt(ids: ids, question: question.isEmpty ? nil : question)
            guard revision == promptRevision else { return }
            prompt = reply
            errorText = prompt?.status == "ok" ? nil : (prompt?.message ?? "Could not build brainstorm prompt.")
        } catch {
            guard revision == promptRevision else { return }
            errorText = MenuModel.message(for: error)
        }
    }

    public func copyPrompt() -> Bool {
        guard let prompt, prompt.status == "ok", let text = prompt.prompt else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Brainstorm prompt copied. The prompt shares selected idea content with whoever you paste it to."
        return true
    }

    public func handoff(to session: OfficeSession, office: OfficeModel) async -> Bool {
        guard let prompt, prompt.status == "ok", prompt.withinLimit == true, let text = prompt.prompt,
              session.status == .idle, !busy else { return false }
        busy = true
        defer { busy = false }
        office.select(session.id)
        let sent = await office.send(text)
        guard sent else { errorText = office.sendNotice ?? "The brainstorm was not sent."; return false }
        var linkFailure: String?
        for id in (selectedIDs.isEmpty ? selectedId.map { [$0] } ?? [] : selectedIDs.sorted()) {
            do {
                let reply = try await client.linkIdeaSession(id: id, agent: session.agent, sessionId: session.sessionId)
                if reply.status != "ok" { linkFailure = reply.message ?? "The session reference could not be saved."; break }
            } catch {
                linkFailure = MenuModel.message(for: error)
                break
            }
        }
        await load()
        if let linkFailure {
            errorText = nil
            notice = "Sent to \(session.heading), but could not save the session reference: \(linkFailure). The prompt was already sent; do not resend to retry linking."
            return true
        }
        notice = "Sent to \(session.heading). The agent may send this prompt to its configured provider; discussion-only guidance does not restrict its existing permissions."
        errorText = nil
        return true
    }
}
