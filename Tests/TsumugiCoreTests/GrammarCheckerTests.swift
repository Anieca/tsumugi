import XCTest
@testable import TsumugiCore

final class GrammarCheckerTests: XCTestCase {
    /// 決めた文だけを自然とみなす採点役。それ以外の文は、違う文字のところで確率が落ちる。
    final class FakeScorer: TextScorer {
        var good: [Character]
        init(good: String) { self.good = Array(good) }

        func tokens(text: String, leftContext: String, alternatives: Int) -> [ScoredToken] {
            var j = 0
            return text.map { c in
                let expected = j < good.count ? String(good[j]) : "。"
                let ok = String(c) == expected
                if ok { j += 1 }
                return ScoredToken(text: String(c), probability: ok ? 0.5 : 0.001, alternatives: [(expected, 0.5)])
            }
        }

        func logProbability(text: String, leftContext: String) -> Float? {
            tokens(text: text, leftContext: leftContext, alternatives: 1).reduce(Float(0)) { $0 + log($1.probability) }
        }
    }

    func check(_ text: String, good: String) -> Correction? {
        GrammarChecker(scorer: FakeScorer(good: good)).check(text)
    }

    func testRemovesDuplicatedParticle() {
        let c = check("今日は会議をを開きます", good: "今日は会議を開きます")
        XCTAssertEqual(c?.tail, "を開きます")
        XCTAssertEqual(c?.fixedTail, "開きます")
    }

    func testRemovesRepeatedWords() {
        let c = check("設定を変更するすることができます", good: "設定を変更することができます")
        XCTAssertEqual(c.map { String("設定を変更するすることができます".dropLast($0.tail.count)) + $0.fixedTail }, "設定を変更することができます")
    }

    func testFillsDroppedCharacter() {
        let c = check("東京に行きした", good: "東京に行きました")
        XCTAssertEqual(c?.tail, "した")
        XCTAssertEqual(c?.fixedTail, "ました")
    }

    func testSwapsParticleButNotOtherCharacters() {
        let c = check("彼は学校を行ったよ", good: "彼は学校に行ったよ")
        XCTAssertEqual(c?.fixedTail, "に行ったよ")
        // 助詞でない文字の入れ替えは提案しない
        XCTAssertNil(check("明日までに提出しまう。", good: "明日までに提出します。"))
    }

    func testLeavesNaturalSentenceAlone() {
        XCTAssertNil(check("今日は会議を開きます", good: "今日は会議を開きます"))
    }
}
