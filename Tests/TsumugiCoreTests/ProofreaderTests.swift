import XCTest
@testable import TsumugiCore

/// 読み直し (確定済みの文の、変換の取り違えの指摘) のテスト。採点役は差し替える。
final class ProofreaderTests: XCTestCase {
    final class FakeScorer: ProofreadScorer {
        /// 読み → 変換し直した結果
        var again: [String: String] = [:]
        /// 表記 → 読みに対する確からしさ / 文章としての自然さ。載っていなければ -10。
        var surface: [String: Float] = [:]
        var text: [String: Float] = [:]
        var reconverted: [String] = []

        func reconvert(reading: String, leftContext: String, isCancelled: () -> Bool) -> String? {
            if isCancelled() { return nil }
            reconverted.append(reading)
            return again[reading]
        }
        func logProbability(surface s: String, reading: String, leftContext: String) -> Float? { surface[s] ?? -10 }
        func logProbability(text t: String, leftContext: String) -> Float? { text[t] ?? -10 }
    }

    var scorer: FakeScorer!
    var proofreader: Proofreader!

    override func setUpWithError() throws {
        let dict = try XCTUnwrap(SessionTests.dictionary, "build/system.dict がありません")
        scorer = FakeScorer()
        proofreader = Proofreader(converter: Converter(dictionary: dict), scorer: scorer)
        // 「仕様率」は、文全体の読みで変換し直すと「使用率」になり、そのほうがはっきり確からしい
        scorer.again["のしようりつをみたい"] = "の使用率を見たい"
        scorer.surface["の使用率を見たい"] = -2
        scorer.text["の使用率を見たい"] = -5
    }

    func testReading() {
        XCTAssertEqual(Proofreader.reading(of: "今日は学校に行きました"), "きょうはがっこうにいきました")
        XCTAssertEqual(Proofreader.reading(of: "データを確認する"), "でーたをかくにんする")
    }

    func testHunks() {
        func h(_ a: String, _ b: String) -> [Proofreader.Hunk] { Proofreader.hunks(Array(a), Array(b)) }
        XCTAssertEqual(h("の仕様率を見たい", "の使用率を見たい"), [.init(range: 1..<3, replacement: "使用")])
        XCTAssertEqual(h("vじょうで動く", "v上で動く"), [.init(range: 1..<4, replacement: "上")])
        XCTAssertEqual(h("分に組み込んで下さい", "文に組み込んでください"),
                       [.init(range: 0..<1, replacement: "文"), .init(range: 7..<8, replacement: "くだ")])
        XCTAssertEqual(h("同じ", "同じ"), [])
    }

    func testSuggestsHomophoneFix() {
        let c = proofreader.check("前の文です。CPUの仕様率を見たい")
        XCTAssertEqual(c?.from, "の仕様率")
        XCTAssertEqual(c?.to, "の使用率")
        // 直す箇所からカーソルまでをまとめて置き換える (カーソルを動かさないため)
        XCTAssertEqual(c?.tail, "仕様率を見たい")
        XCTAssertEqual(c?.fixedTail, "使用率を見たい")
        XCTAssertEqual(c?.gain, 8)
    }

    func testChecksOnlyLastSentence() {
        // 文末の句点のあとにカーソルがあっても、その文を見る
        XCTAssertNotNil(proofreader.check("CPUの仕様率を見たい。"))
        // 次の文に進んだら、前の文はもう蒸し返さない
        scorer.reconverted = []
        XCTAssertNil(proofreader.check("CPUの仕様率を見たい。次の話です"))
        XCTAssertEqual(scorer.reconverted, ["つぎのはなしです"])
    }

    func testNeedsBothGains() {
        // 読みに対しては確からしくても、文章として自然にならないなら出さない
        scorer.text["の使用率を見たい"] = -9
        XCTAssertNil(proofreader.check("CPUの仕様率を見たい"))
    }

    func testSmallGainIsNotSuggested() {
        scorer.surface["の使用率を見たい"] = -8
        XCTAssertNil(proofreader.check("CPUの仕様率を見たい"))
    }

    func testCandidatesAreNotFilteredByThreshold() {
        // しきい値に届かない候補も、計測用には伸びつきで返す
        scorer.surface["の使用率を見たい"] = -9
        scorer.text["の使用率を見たい"] = -9.5
        XCTAssertNil(proofreader.check("CPUの仕様率を見たい"))
        let all = proofreader.candidates("CPUの仕様率を見たい")
        XCTAssertEqual(all.map(\.to), ["の使用率"])
        XCTAssertEqual(all.first?.gain, 1)
        XCTAssertEqual(all.first?.textGain, 0.5)
    }

    func testIgnoredCorrectionIsNotSuggested() throws {
        let c = try XCTUnwrap(proofreader.check("CPUの仕様率を見たい"))
        XCTAssertNil(proofreader.check("CPUの仕様率を見たい", ignoring: [c.key]))
    }

    func testRejectsReconversionWithDifferentReading() {
        // 変換し直した結果が元の読みで読めないなら、モデルの作文なので使わない
        scorer.again["のしようりつをみたい"] = "の利用率を見たい"
        scorer.surface["の利用率を見たい"] = -1
        scorer.text["の利用率を見たい"] = -1
        XCTAssertNil(proofreader.check("CPUの仕様率を見たい"))
    }

    func testUnchangedTextIsNotScoredAgain() {
        _ = proofreader.check("CPUの仕様率を見たい")
        _ = proofreader.check("CPUの仕様率を見たい")
        XCTAssertEqual(scorer.reconverted.count, 1)
    }

    func testCancelledCheckIsNotCached() {
        XCTAssertNil(proofreader.check("CPUの仕様率を見たい") { true })
        XCTAssertNotNil(proofreader.check("CPUの仕様率を見たい"))
    }
}
