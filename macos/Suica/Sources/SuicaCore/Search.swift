/// The search on the Messages and Review requests pages: a row is shown when every word of the
/// query is somewhere in its texts, ignoring case and accents. An empty query shows every row.
public enum Search {
    public static func matches(_ query: String, _ texts: [String?]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = texts.compactMap { $0 }.joined(separator: "\n")
        return words.allSatisfy { haystack.localizedStandardContains($0) }
    }
}

extension OutboxItem {
    /// By what its row shows: the kind, the recipient, the MR, the outcome and the message.
    public func matches(_ query: String) -> Bool {
        Search.matches(query, [Copy.kindLabel(kind), recipientName, mrKey, mrTitle, detail, text])
    }
}

extension ReviewSummary {
    /// By the MR's title and key, its author and its reviewers.
    public func matches(_ query: String) -> Bool {
        Search.matches(
            query, [title, key, author.name, author.username] + reviewers.flatMap { [$0.name, $0.username] })
    }
}

extension ReviewListDocument {
    /// Your MRs whose title or key holds the search text; all of them without one.
    public func yourMergeRequests(matching query: String) -> [YourMergeRequest] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return yourMergeRequests }
        return yourMergeRequests.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.key.localizedCaseInsensitiveContains(text)
        }
    }

    /// `sections` with only the MRs that match, dropping groups left empty.
    public func sections(matching query: String) -> [ReviewSection] {
        sections.compactMap { section in
            let items = section.items.filter { $0.matches(query) }
            return items.isEmpty ? nil : ReviewSection(group: section.group, items: items)
        }
    }
}
