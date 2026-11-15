import XCTest
@testable import TsumugiCore

final class SpacingTests: XCTestCase {
    func testSpaced() {
        XCTAssertEqual(Spacing.spaced("Tabで直す"), "Tab で直す")
        XCTAssertEqual(Spacing.spaced("これはNotionです"), "これは Notion です")
        XCTAssertEqual(Spacing.spaced("Tab で直す"), "Tab で直す")
        XCTAssertEqual(Spacing.spaced("Tシャツ"), "Tシャツ")
        XCTAssertEqual(Spacing.spaced("血液型はAです"), "血液型はAです")
        XCTAssertEqual(Spacing.spaced("30文字"), "30文字")
        XCTAssertEqual(Spacing.spaced("OK。次へ"), "OK。次へ")
        XCTAssertEqual(Spacing.spaced("「API」を"), "「API」を")
        XCTAssertEqual(Spacing.spaced("サーバー"), "サーバー")
    }

    func testNeedsSpace() {
        XCTAssertTrue(Spacing.needsSpace(after: "Tab", before: "で"))
        XCTAssertTrue(Spacing.needsSpace(after: "これは", before: "N"))
        XCTAssertTrue(Spacing.needsSpace(after: "これは", before: "Notion"))
        XCTAssertFalse(Spacing.needsSpace(after: "Tab ", before: "で"))
        XCTAssertFalse(Spacing.needsSpace(after: "T", before: "シャツ"))
        XCTAssertFalse(Spacing.needsSpace(after: "は T", before: "シャツ"))
        XCTAssertFalse(Spacing.needsSpace(after: "30", before: "文字"))
        XCTAssertFalse(Spacing.needsSpace(after: "です。", before: "N"))
        XCTAssertFalse(Spacing.needsSpace(after: "", before: "で"))
        XCTAssertFalse(Spacing.needsSpace(after: "血液型は", before: "Aです"))
    }
}
