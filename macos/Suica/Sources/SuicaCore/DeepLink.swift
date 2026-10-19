import Foundation

/// A `suica://` link: how the macOS notification of a Re-review Nudge opens the window.
public enum DeepLink: Equatable, Sendable {
    /// Messages → Your MRs, with this outbox row selected if it still exists.
    case message(Int)
    /// Messages → Your MRs.
    case messages

    /// Nil for anything but `suica://message/<id>`, with a positive integer id, and `suica://messages`.
    /// Any program can open a `suica://` address, so everything else is refused.
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "suica",
            parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        switch parts.host?.lowercased() {
        case "message":
            let id = parts.path.dropFirst()
            guard parts.path.hasPrefix("/"), id.utf8.allSatisfy({ (48...57).contains($0) }),
                let number = Int(id), number > 0
            else { return nil }
            self = .message(number)
        case "messages":
            guard parts.path.isEmpty || parts.path == "/" else { return nil }
            self = .messages
        default:
            return nil
        }
    }
}
