import XCTest
@testable import TsumugiCore

final class SpacingTests: XCTestCase {
    func testSpaced() {
        XCTAssertEqual(Spacing.spaced("Tabで直す"), "Tab で直す")
        XCTAssertEqual(Spacing.spaced("これはNotionです"), "これは Notion です")
        XCTAssertEqual(Spacing.spaced("Tab で直す"), "Tab で直す")
        XCTAssertEqual(Spacing.spaced("Tシャツ"), "Tシャツ")
        XCTAssertEqual(Spacing.spaced("血液型はAです"), "血液型は A です")
        XCTAssertEqual(Spacing.spaced("血液型A"), "血液型A")
        XCTAssertEqual(Spacing.spaced("X線とA型"), "X線とA型")
        XCTAssertEqual(Spacing.spaced("30文字"), "30 文字")
        XCTAssertEqual(Spacing.spaced("全部で3件あります"), "全部で 3 件あります")
        XCTAssertEqual(Spacing.spaced("2026年11月16日の10時"), "2026 年 11 月 16 日の 10 時")
        XCTAssertEqual(Spacing.spaced("3万円と50%の差"), "3 万円と 50% の差")
        XCTAssertEqual(Spacing.spaced("v2に3/14(木)まで"), "v2 に 3/14(木)まで")
        XCTAssertEqual(Spacing.spaced("保存(S)を押す"), "保存(S)を押す")
        XCTAssertEqual(Spacing.spaced("これは`git status`です"), "これは `git status` です")
        XCTAssertEqual(Spacing.spaced("`変数`を使う"), "`変数` を使う")
        XCTAssertEqual(Spacing.spaced("本当ですか?OKです"), "本当ですか?OK です")
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
        XCTAssertTrue(Spacing.needsSpace(after: "30", before: "文字"))
        XCTAssertTrue(Spacing.needsSpace(after: "11", before: "月"))
        XCTAssertTrue(Spacing.needsSpace(after: "11 月", before: "1"))
        XCTAssertTrue(Spacing.needsSpace(after: "全部で", before: "3"))
        XCTAssertTrue(Spacing.needsSpace(after: "50%", before: "の"))
        XCTAssertFalse(Spacing.needsSpace(after: "(S)", before: "を"))
        XCTAssertFalse(Spacing.needsSpace(after: "3/", before: "を"))
        XCTAssertTrue(Spacing.needsSpace(after: "これは", before: "`"))
        XCTAssertTrue(Spacing.needsSpace(after: "us`", before: "です"))
        XCTAssertFalse(Spacing.needsSpace(after: "は `", before: "変数"))
        XCTAssertTrue(Spacing.needsSpace(after: "は A", before: "です"))
        XCTAssertFalse(Spacing.needsSpace(after: "です。", before: "N"))
        XCTAssertFalse(Spacing.needsSpace(after: "", before: "で"))
        XCTAssertTrue(Spacing.needsSpace(after: "血液型は", before: "Aです"))
        XCTAssertFalse(Spacing.needsSpace(after: "血液型", before: "Aです"))
    }
}
