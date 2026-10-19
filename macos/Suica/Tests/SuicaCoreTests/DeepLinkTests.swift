import Foundation
import Testing

@testable import SuicaCore

private func link(_ text: String) -> DeepLink? {
    URL(string: text).flatMap(DeepLink.init(url:))
}

@Test(arguments: [
    ("suica://message/1", DeepLink.message(1)),
    ("suica://message/12345", .message(12345)),
    ("suica://messages", .messages),
    ("suica://messages/", .messages),
    // Schemes and hosts are case-insensitive.
    ("SUICA://Message/7", .message(7)),
    ("suica://MESSAGES", .messages),
])
func aLinkTheAgentSendsOpensTheMessages(text: String, expected: DeepLink) {
    #expect(link(text) == expected)
}

@Test(arguments: [
    // The id must be a positive integer, and only that.
    "suica://message/0", "suica://message/-1", "suica://message/+5", "suica://message/1.5",
    "suica://message/abc", "suica://message/5x", "suica://message/%205", "suica://message/", "suica://message",
    "suica://message/1/2", "suica://message/5/", "suica://message//5", "suica://message/٣",
    "suica://message/99999999999999999999",
    // Nothing else is accepted: other hosts, paths, query, fragment, userinfo, port, other schemes.
    "suica://", "suica:message/5", "suica:///message/5", "suica://other/5", "suica://messages/5",
    "suica://messages?id=5", "suica://message/5?x=1", "suica://message/5#top", "suica://x@message/5",
    "suica://message:80/5", "suica://messages:1",
    "suicaa://message/5", "http://message/5", "file:///message/5",
])
func anythingElseIsIgnored(text: String) {
    #expect(link(text) == nil)
}
