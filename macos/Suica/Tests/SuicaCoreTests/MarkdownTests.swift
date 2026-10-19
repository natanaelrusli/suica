import Testing

@testable import SuicaCore

@Test func aTableBecomesHeaderAlignmentsAndRows() {
    let blocks = parseMarkdownBlocks(
        """
        ## Guardrails checked
        | Skill | Result | Count |
        |---|:---:|--:|
        | madhani-git-workflow | **clean** | 1 |
        | a \\| b | `x` |
        | too | many | cells | here |

        After.
        """)
    #expect(blocks == [
        .heading(level: 2, text: "Guardrails checked"),
        .table(MarkdownTable(
            header: ["Skill", "Result", "Count"],
            alignments: [.leading, .center, .trailing],
            rows: [
                ["madhani-git-workflow", "**clean**", "1"],
                ["a | b", "`x`", ""],
                ["too", "many", "cells"],
            ])),
        .paragraph("After."),
    ])
}

@Test func aTableNeedsADelimiterRowWithTheSameNumberOfCells() {
    #expect(parseMarkdownBlocks("a | b\n|---|---|---|") == [.paragraph("a | b\n|---|---|---|")])
    #expect(parseMarkdownBlocks("a | b\nnot a delimiter") == [.paragraph("a | b\nnot a delimiter")])
    #expect(parseMarkdownBlocks("a | b\n--- | ---\n1 | 2") == [
        .table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]]))
    ])
}

@Test func aTableEndsAtABlankLineOrALineWithoutAPipe() {
    let blocks = parseMarkdownBlocks("Intro:\n| a |\n|---|\n| 1 |\nplain")
    #expect(blocks == [
        .paragraph("Intro:"),
        .table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"]])),
        .paragraph("plain"),
    ])
}

@Test func indentedAndFollowingLinesContinueAListItem() {
    let blocks = parseMarkdownBlocks(
        """
        - **Finding class:** drift.
          **Mechanisable:** yes.
        lazy line
        - second

          indented after a blank line
        - third

        A paragraph.
        """)
    #expect(blocks == [
        .listItem(text: "**Finding class:** drift.\n**Mechanisable:** yes.\nlazy line", marker: "•", indent: 0),
        .listItem(text: "second\nindented after a blank line", marker: "•", indent: 0),
        .listItem(text: "third", marker: "•", indent: 0),
        .paragraph("A paragraph."),
    ])
}

@Test func otherBlocksKeepTheirShape() {
    let blocks = parseMarkdownBlocks("# T\n\n1. one\n  - nested\n> quote\n```\n| a |\n|---|\n```\ntext\nmore")
    #expect(blocks == [
        .heading(level: 1, text: "T"),
        .listItem(text: "one", marker: "1.", indent: 0),
        .listItem(text: "nested", marker: "•", indent: 1),
        .quote("quote"),
        .code("| a |\n|---|"),
        .paragraph("text\nmore"),
    ])
}

@Test func tableCellsKeepOtherEscapes() {
    #expect(tableCells("| a\\*b | c \\| d |") == ["a\\*b", "c | d"])
    #expect(tableCells("a | b") == ["a", "b"])
}

@Test func taskItemsShowTheirBox() {
    #expect(parseMarkdownBlocks("- [ ] todo\n- [x] done\n1. [X] first\n- [ ]") == [
        .listItem(text: "todo", marker: "☐", indent: 0),
        .listItem(text: "done", marker: "☑", indent: 0),
        .listItem(text: "first", marker: "1. ☑", indent: 0),
        .listItem(text: "", marker: "☐", indent: 0),
    ])
    #expect(parseMarkdownBlocks("- [link](x) text") == [.listItem(text: "[link](x) text", marker: "•", indent: 0)])
}

@Test func htmlCommentsAreHiddenOutsideCode() {
    let blocks = parseMarkdownBlocks(
        """
        <!-- Template: describe the change -->
        Intro <!-- hidden --> kept.
        <!--
        - [ ] not shown
        -->
        - item
        ```
        <!-- in code -->
        ```
        """)
    #expect(blocks == [
        .paragraph("Intro  kept."),
        .listItem(text: "item", marker: "•", indent: 0),
        .code("<!-- in code -->"),
    ])
    #expect(parseMarkdownBlocks("a\n<!-- never closed\nb") == [.paragraph("a")])
}

@Test func rulesUnderlinedHeadingsAndTildeFences() {
    let blocks = parseMarkdownBlocks("Title\n===\n\n---\n* * *\nSub\nheading\n---\n~~~sh\n```\n~~~")
    #expect(blocks == [
        .heading(level: 1, text: "Title"),
        .rule,
        .rule,
        .heading(level: 2, text: "Sub\nheading"),
        .code("```"),
    ])
}

@Test func imagesBecomeLinksAndUploadsPointIntoTheProject() {
    let project = "https://gitlab.example/g/p"
    #expect(
        inlineMarkdownSource("See ![shot](/uploads/ab/s.png) and ![](https://x.example/i.png)", projectURL: project)
            == "See [shot](https://gitlab.example/g/p/uploads/ab/s.png) and [image](https://x.example/i.png)")
    #expect(inlineMarkdownSource("`![x](/uploads/a)` [f](/uploads/b)", projectURL: nil) == "`![x](/uploads/a)` [f](/uploads/b)")
    #expect(inlineMarkdownSource("[f](/uploads/b)", projectURL: project) == "[f](https://gitlab.example/g/p/uploads/b)")
}
