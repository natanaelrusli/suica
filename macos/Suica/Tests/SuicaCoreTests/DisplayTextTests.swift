import Foundation
import Testing

@testable import SuicaCore

@Test func collapsesNewlinesTabsAndControlCharacters() {
    #expect(DisplayText.clean("a\n\tb\u{0007}c") == "a b c")
    #expect(DisplayText.clean("a   b\r\nc") == "a b c")
}

@Test func cutsLongTextWithAnEllipsis() {
    let cut = DisplayText.clean(String(repeating: "x", count: 5000))
    #expect(cut.count == 200)
    #expect(cut.hasSuffix("…"))
}

@Test func keepsTextAtTheLimitUntouched() {
    let exact = String(repeating: "y", count: 200)
    #expect(DisplayText.clean(exact) == exact)
}

@Test func keepsEmojiAndAccentsIntact() {
    #expect(DisplayText.clean("Café 🙂 👩‍👩‍👧") == "Café 🙂 👩‍👩‍👧")
    let emoji = String(repeating: "👩‍👩‍👧", count: 300)
    let cut = DisplayText.clean(emoji, max: 10)
    #expect(cut.count == 10)
    #expect(cut.dropLast().allSatisfy { $0 == "👩‍👩‍👧" })
}

@Test func trimsOuterWhitespace() {
    #expect(DisplayText.clean("  hi \n") == "hi")
}

@Test func acceptsOnlyHttpAndHttpsLinks() {
    #expect(DisplayText.safeURL("https://gitlab.example/a?b=c")?.absoluteString == "https://gitlab.example/a?b=c")
    #expect(DisplayText.safeURL("HTTP://gitlab.example/a") != nil)
    for bad in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "", "not a url", "ftp://x/y"] {
        #expect(DisplayText.safeURL(bad) == nil, "\(bad)")
    }
}

@Test func flashTextCoversEveryCodeTheAgentCanSend() {
    let codes = [
        "sent", "busy", "obsolete", "unresolved", "failed", "retry-later", "lookup-error",
        "not-pending", "not-found", "skipped", "retried", "nothing",
    ]
    for code in codes { #expect(Copy.flash(for: code) != "Done.", "\(code)") }
    #expect(Copy.flash(for: "zzz") == "Done.")
    #expect(Copy.flash(for: "sent") == "Message sent.")
}

@Test func copyHelpersFormatTheirArguments() {
    #expect(Copy.tracked(4) == "4 of your MRs are tracked")
    #expect(Copy.waitingForYou(5) == "5 MRs are waiting for your review")
    #expect(Copy.moreHidden(50) == "and 50 more (see suica pending --all)")
    #expect(Copy.confirmTitle("Bob") == "Send this message to Bob?")
    #expect(Copy.kindLabel("nudge") == "Nudge")
    #expect(Copy.kindLabel("reminder") == "Reminder")
    #expect(Copy.kindLabel("notice") == "Review notice")
    #expect(Copy.kindLabel("other") == "other")
}
