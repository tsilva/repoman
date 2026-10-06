import XCTest
@testable import RepoManCore

final class ConversationMarkdownTests: XCTestCase {
    func testAbsoluteMarkdownFileLinkOpensAsFileURL() throws {
        let path = "/Users/example/repos/site/docs/analytics-delivery-verification.md"
        let markdown = try AttributedString(markdown: "[Verification record](\(path))",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let link = try XCTUnwrap(markdown.runs.first?.link)
        XCTAssertNil(link.scheme)
        XCTAssertEqual(ConversationMarkdown.openDestination(for: link), URL(fileURLWithPath: path))
    }

    func testEncodedLocalFilePathIsDecodedOnce() throws {
        let link = try XCTUnwrap(URL(string: "/Users/example/My%20Project/verification%20%231.md"))
        let destination = ConversationMarkdown.openDestination(for: link)
        XCTAssertTrue(destination.isFileURL)
        XCTAssertEqual(destination.path, "/Users/example/My Project/verification #1.md")
    }

    func testOtherLinkDestinationsArePreserved() throws {
        for source in ["https://example.com/report?q=1#result", "file:///tmp/record.md",
                       "mailto:hello@example.com", "codex://threads/123", "docs/record.md",
                       "//example.com/report"] {
            let link = try XCTUnwrap(URL(string: source))
            XCTAssertEqual(ConversationMarkdown.openDestination(for: link), link, source)
        }
    }

    func testBranchComparisonFromConversation() {
        let source = """
        Both branches are safe candidates:

        | Branch | Fully merged into main | Checked out in a worktree |
        |---|---|---|
        | `codex-fix-health-report-source-status` | Yes | No |
        | `codex-what-next-current-status-summary` | Yes | No |

        Each has zero unmerged commits.
        """
        let blocks = ConversationMarkdown(source).blocks
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.first, .text("Both branches are safe candidates:\n"))
        guard case .table(let table) = blocks[1] else { return XCTFail("Expected table") }
        XCTAssertEqual(table.headers, ["Branch", "Fully merged into main", "Checked out in a worktree"])
        XCTAssertEqual(table.alignments, [.left, .left, .left])
        XCTAssertEqual(table.rows, [
            ["`codex-fix-health-report-source-status`", "Yes", "No"],
            ["`codex-what-next-current-status-summary`", "Yes", "No"]
        ])
        XCTAssertEqual(blocks.last, .text("\nEach has zero unmerged commits."))
    }

    func testAlignmentOptionalOuterPipesAndUnevenRows() {
        let source = """
        Name | Count | Result
        :--- | ---: | :---:
        **build** | 12 | [Passed](https://example.com)
        test | 3
        check | 4 | Passed | extra
        """
        guard case .table(let table) = ConversationMarkdown(source).blocks.first else {
            return XCTFail("Expected table")
        }
        XCTAssertEqual(table.alignments, [.left, .right, .center])
        XCTAssertEqual(table.rows, [["**build**", "12", "[Passed](https://example.com)"],
                                    ["test", "3", ""], ["check", "4", "Passed"]])
    }

    func testEscapedPipesRemainInsideCells() {
        let source = #"""
        | Pattern | Value |
        | --- | --- |
        | a\|b | `c\|d` |
        | slash\\ | end\| |
        """#
        guard case .table(let table) = ConversationMarkdown(source).blocks.first else {
            return XCTFail("Expected table")
        }
        XCTAssertEqual(table.rows, [["a|b", "`c|d`"], [#"slash\\"#, "end|"]])
    }

    func testMalformedTablesAndOrdinaryTextStayIntact() {
        for source in ["hello **world**\n\nnext paragraph", "a | b\n-- | ---\nx | y",
                       "a | b\n---\nx | y", "a | b\n--- | --x\nx | y",
                       "    a | b\n    --- | ---\n    x | y", "a | b\n\n--- | ---"] {
            XCTAssertEqual(ConversationMarkdown(source).blocks, [.text(source)], source)
        }
        XCTAssertEqual(ConversationMarkdown("").blocks, [])
    }

    func testTablesInsideFencedCodeStayText() {
        for fence in ["```", "~~~", "````"] {
            let source = "\(fence)markdown\na | b\n--- | ---\nx | y\n\(fence)"
            XCTAssertEqual(ConversationMarkdown(source).blocks, [.text(source)])
        }
        let source = "````\n```\na | b\n--- | ---\nx | y\n````\n\n| Real | Table |\n| --- | --- |"
        let blocks = ConversationMarkdown(source).blocks
        XCTAssertEqual(blocks.count, 2)
        guard case .table(let table) = blocks.last else { return XCTFail("Expected table after code") }
        XCTAssertEqual(table.headers, ["Real", "Table"])
        XCTAssertTrue(table.rows.isEmpty)
    }

    func testMultipleTablesAndWindowsLineEndings() {
        let source = "| A | B |\r\n| --- | --- |\r\n| 1 | 2 |\r\n\r\nBetween\r\n\r\n| C |\r\n| :---: |\r\n| 3 |"
        let blocks = ConversationMarkdown(source).blocks
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .text("\nBetween\n"))
        guard case .table(let table) = blocks[2] else { return XCTFail("Expected second table") }
        XCTAssertEqual(table.headers, ["C"])
        XCTAssertEqual(table.rows, [["3"]])
    }
}
