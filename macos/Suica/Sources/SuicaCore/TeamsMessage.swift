import Foundation

// MARK: - Documents

/// What `suica message <key> --json` reads on stdin.
public struct TeamsMessageRequest: Codable, Equatable, Sendable {
    /// The recipient's GitLab username.
    public let to: String
    /// The Teams template the text starts from (nudge, rereview, notice.comments, …).
    public let template: String
    /// The text to send as written; nil uses the template's.
    public let text: String?
    /// False only drafts the template's text.
    public let send: Bool

    public init(to: String, template: String, text: String?, send: Bool) {
        self.to = to
        self.template = template
        self.text = text
        self.send = send
    }

    // Encoded by hand so a nil text goes out as null, which the CLI requires.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(to, forKey: .to)
        try container.encode(template, forKey: .template)
        try container.encode(text, forKey: .text)
        try container.encode(send, forKey: .send)
    }
}

/// The answer: `draft` with the template's text, or how sending went (sent, unresolved,
/// lookup-error, failed, retry-later, busy), or why nothing happened (bad-request, bad-recipient,
/// teams-off, failed with a message).
public struct TeamsMessageReply: Codable, Equatable, Sendable {
    public let status: String
    public let text: String?
    public let message: String?

    public init(status: String, text: String? = nil, message: String? = nil) {
        self.status = status
        self.text = text
        self.message = message
    }
}

// MARK: - Choices

/// Someone on the MR who can get a Teams message from its page.
public struct MessageRecipient: Equatable, Hashable, Sendable {
    public let username: String
    public let name: String
    public let isAuthor: Bool
    /// Their review state as a Reviewer; nil for the Author.
    public let state: String?
}

/// Who a message from an MR's page can go to and which templates it starts from: on your own MR,
/// its Reviewers and the requests to review; on another's, its Author first, then the other
/// Reviewers, and the Review Notices.
public enum TeamsMessageChoices {
    public static func recipients(_ detail: MergeRequestDetail, me: Person?, yours: Bool) -> [MessageRecipient] {
        let author =
            yours || detail.author.username == me?.username
            ? [] : [MessageRecipient(username: detail.author.username, name: detail.author.name, isAuthor: true, state: nil)]
        let reviewers = detail.reviewers
            .filter { $0.username != me?.username && $0.username != detail.author.username }
            .map { MessageRecipient(username: $0.username, name: $0.name, isAuthor: false, state: $0.state) }
        return author + reviewers
    }

    public static func templates(yours: Bool) -> [String] {
        yours ? ["nudge", "reminder", "rereview"] : ["notice.comments", "notice.changes", "notice.approved"]
    }

    /// On your MR, a request to review to someone who has not, else a request to review again; on
    /// another's, the notice that matches your own review.
    public static func defaultTemplate(
        for recipient: MessageRecipient, in detail: MergeRequestDetail, me: Person?, yours: Bool
    ) -> String {
        if yours { return (recipient.state ?? "UNREVIEWED") == "UNREVIEWED" ? "nudge" : "rereview" }
        switch detail.reviewers.first(where: { $0.username == me?.username })?.state {
        case "APPROVED": return "notice.approved"
        case "REQUESTED_CHANGES": return "notice.changes"
        default: return "notice.comments"
        }
    }
}
