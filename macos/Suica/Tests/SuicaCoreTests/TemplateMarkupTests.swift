import Foundation
import Testing

@testable import SuicaCore

@Test func theMarkupSubsetParsesIntoRuns() {
    #expect(
        TemplateMarkup.parse("Halo **{{person.name}}**, cek _ini_ ~~dulu~~ [MR](https://x.example/1) ![party](https://g.example/p.gif)")
            == [
                .text("Halo ", []), .placeholder("person.name", .bold), .text(", cek ", []), .text("ini", .italic),
                .text(" ", []), .text("dulu", .strikethrough), .text(" ", []),
                .link(text: "MR", url: "https://x.example/1", []), .text(" ", []),
                .image(alt: "party", url: "https://g.example/p.gif"),
            ])
    #expect(TemplateMarkup.parse("**_both_**") == [.text("both", [.bold, .italic])])
    #expect(TemplateMarkup.parse("a \\*not\\* b") == [.text("a *not* b", [])])
    // Unclosed or spaced delimiters stay literal.
    #expect(TemplateMarkup.parse("2 * 3 and **open") == [.text("2 * 3 and **open", [])])
}

@Test func theEditorWritesCanonicalMarkdown() {
    #expect(TemplateMarkup.markdown([.text("bold", .bold), .text(" and ", []), .text("italic", .italic)]) == "**bold** and _italic_")
    // Nested styles share delimiters instead of closing and reopening.
    #expect(TemplateMarkup.markdown([.text("a ", .bold), .text("b", [.bold, .italic]), .text(" c", .bold)]) == "**a _b_ c**")
    // A delimiter never sits next to a space inside it.
    #expect(TemplateMarkup.markdown([.text("Hi ", .bold), .text("there", [])]) == "**Hi** there")
    // Inside a word, italic uses *, which Markdown honours there.
    #expect(TemplateMarkup.markdown([.text("re", []), .text("view", .italic), .text("ed", [])]) == "re*view*ed")
    // Literals are escaped, and a ! typed before a link stays a !.
    #expect(TemplateMarkup.markdown([.text("5*3 [x] a_b", [])]) == "5\\*3 \\[x\\] a\\_b")
    #expect(TemplateMarkup.markdown([.text("Wow!", []), .link(text: "t", url: "https://x.example", [])]) == "Wow\\![t](https://x.example)")
    // Styles stop at a line break and start again after it.
    #expect(TemplateMarkup.markdown([.text("one\ntwo", .bold)]) == "**one**\n**two**")
}

@Test func everyCanonicalTemplateRoundTrips() {
    let sources = [
        "Halo {{person.name}}, saya {{agent.name}}, agen review-nya {{owner.name}}. Boleh minta tolong review MR ini?\n{{mr.link}}\nTerima kasih!",
        "**Halo** _{{person.firstName}}_ 🎉 ~~lama~~\n[Buka](https://gitlab.example/a_b)\n![party](https://media.example/p_q.gif)",
        "**a _b_ c** and re*view*ed",
        "Wow\\![t](https://x.example)",
        "jam 10:30, :tada: {{ mr.link }}",
    ]
    for source in sources {
        #expect(TemplateMarkup.isFaithful(source), "\(source)")
    }
}

@Test func markdownTheEditorCannotShowIsNotFaithful() {
    for source in ["__bold__", "a **b\nc**", "`code`", "\\-dash", "*a*", "**a** **b**"] {
        #expect(!TemplateMarkup.isFaithful(source), "\(source)")
    }
}

@Test func variantsSplitAndJoin() {
    let text = "Halo\n--- or ---\nHai :wave:\n  --- or ---\t\nPermisi"
    #expect(TemplateVariants.split(text) == ["Halo", "Hai :wave:", "Permisi"])
    #expect(TemplateVariants.join(["Halo", "Hai"]) == "Halo\n--- or ---\nHai")
    #expect(TemplateVariants.split("one --- or --- line") == ["one --- or --- line"])
}

@Test func shortcodesExpandAndCompleteWhileTyping() {
    let table = ["tada": "🎉", "+1": "👍"]
    #expect(EmojiShortcodes.expand(":tada: at 10:30: :nope: :+1:", table: table) == "🎉 at 10:30: :nope: 👍")
    #expect(EmojiShortcodes.completed(in: "Yay :tada:", table: table)! == (6, "🎉"))
    #expect(EmojiShortcodes.completed(in: "Yay :tada", table: table) == nil)
    #expect(EmojiShortcodes.completed(in: "Yay :nope:", table: table) == nil)
}

@Test func thePreviewSplitsTextAndHTTPSImages() {
    let rendered = "Halo Rina 🎉\n![party](https://media.example/p.gif)\nDone ![x](http://insecure.example/x.gif)"
    #expect(
        TemplatePreview.segments(rendered) == [
            .text("Halo Rina 🎉"), .image(alt: "party", url: URL(string: "https://media.example/p.gif")!),
            .text("Done ![x](http://insecure.example/x.gif)"),
        ])
    #expect(TemplatePreview.segments("") == [.text("")])
}

@Test func thePreviewFillsTheNewPlaceholdersAndShortcodes() {
    #expect(
        TemplatePreview.render("Selamat {{time.greeting}} {{person.firstName}} :wave:", emoji: ["wave": "👋"], hour: 16)
            == "Selamat sore Rina 👋")
    #expect([3, 4, 11, 15, 18].map { TemplatePreview.greeting(hour: $0) } == ["malam", "pagi", "siang", "sore", "malam"])
}

@Test func anAlertPreviewsAsTitleAndBody() {
    let preview = AlertPreview.render(":tada: Review siap\n{{mr.title}}\n{{nope}}", emoji: ["tada": "🎉"])
    #expect(preview.title == "🎉 Review siap")
    #expect(preview.body == "[ABC-12] feat: export the leave history {{nope}}")
    #expect(AlertPreview.join(title: "A\nB", body: "C") == "A B\nC")
    #expect(AlertPreview.split("Only") == ("Only", ""))
}
