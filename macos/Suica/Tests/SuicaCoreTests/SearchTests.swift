import Testing

@testable import SuicaCore

@Test func searchNeedsEveryWordSomewhereIgnoringCaseAndAccents() {
    let texts: [String?] = ["Fix the login form", nil, "José Ramírez"]
    #expect(Search.matches("", texts))
    #expect(Search.matches("   ", texts))
    #expect(Search.matches("LOGIN", texts))
    #expect(Search.matches("login jose", texts))
    #expect(Search.matches("ramirez", texts))
    #expect(!Search.matches("login teams", texts))
}

@Test func messageMatchesItsKindRecipientMRAndText() {
    let item = OutboxItem(
        id: 1, kind: "nudge", status: "sent", detail: "Sent with your approval", recipientName: "Dika Pratama",
        mrKey: "ess/wiki!57", mrTitle: "docs: late list", mrUrl: "https://x", text: "Could you take a look?",
        createdAt: 0, updatedAt: 0)
    #expect(item.matches("Nudge"))
    #expect(item.matches("dika"))
    #expect(item.matches("wiki!57"))
    #expect(item.matches("late list"))
    #expect(item.matches("approval"))
    #expect(item.matches("take a look"))
    #expect(!item.matches("reminder"))
}

@Test func reviewMatchesItsTitleKeyAuthorAndReviewers() {
    let mr = ReviewSummary(
        key: "med/dashboard!135", title: "feat: claim lists", url: "https://x", draft: false,
        author: Person(username: "indra", name: "Indra Putra"),
        reviewers: [ReviewerInfo(username: "nata", name: "Nata Nael", state: "UNREVIEWED")])
    #expect(mr.matches("claim"))
    #expect(mr.matches("dashboard!135"))
    #expect(mr.matches("indra putra"))
    #expect(mr.matches("nata"))
    #expect(!mr.matches("wiki"))
}

@Test func filteredSectionsKeepTheirGroupsAndDropEmptyOnes() {
    func mr(_ key: String, _ title: String, state: String, draft: Bool = false) -> ReviewSummary {
        ReviewSummary(
            key: key, title: title, url: "https://x", draft: draft, author: Person(username: "a", name: "A"),
            reviewers: [ReviewerInfo(username: "me", name: "Me", state: state)])
    }
    let list = ReviewListDocument(
        version: 1, me: Person(username: "me", name: "Me"),
        mergeRequests: [
            mr("g/p!1", "claims page", state: "UNREVIEWED"),
            mr("g/p!2", "login form", state: "UNREVIEWED"),
            mr("g/p!3", "claims export", state: "APPROVED"),
            mr("g/p!4", "draft login", state: "UNREVIEWED", draft: true),
        ])
    #expect(list.sections(matching: "") == list.sections)
    let claims = list.sections(matching: "claims")
    #expect(claims.map(\.group) == [.waiting, .approved])
    #expect(claims.map { $0.items.map(\.key) } == [["g/p!1"], ["g/p!3"]])
    #expect(list.sections(matching: "nothing like this").isEmpty)
}
