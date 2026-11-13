import XCTest
@testable import TsumugiCore

final class RomajiTests: XCTestCase {
    private func type(_ s: String) -> Composer {
        var c = Composer()
        for ch in s { c.input(ch) }
        return c
    }

    func testBasic() {
        XCTAssertEqual(type("konnnichiha").kana, "こんにちは")
        XCTAssertEqual(type("konnichiha").kana, "こんいちは") // "nn" は「ん」(標準的なローマ字入力と同じ)
        XCTAssertEqual(type("kyouhaiitenkidesune").kana, "きょうはいいてんきですね")
        XCTAssertEqual(type("gakkou").kana, "がっこう")
        var shinbun = type("sinbun")
        shinbun.flush()
        XCTAssertEqual(shinbun.kana, "しんぶん")
        XCTAssertEqual(type("shinnyuu").kana, "しんゆう")
        XCTAssertEqual(type("ko-hi-").kana, "こーひー")
        XCTAssertEqual(type("sou,desu.").kana, "そう、です。")
        XCTAssertEqual(type("tyotto").kana, "ちょっと")
        XCTAssertEqual(type("fairu").kana, "ふぁいる")
        XCTAssertEqual(type("xtu").kana, "っ")
    }

    func testBackspaceReturnsStrayLetterToPending() {
        var c = type("ds")
        XCTAssertEqual(c.kana, "d")
        c.backspace()
        XCTAssertEqual(c.pending, "d")
        c.input("e")
        XCTAssertEqual(c.kana, "で")
        XCTAssertEqual(c.pending, "")
        // かなを消した場合も同じ
        var c2 = type("dsa")
        XCTAssertEqual(c2.kana, "dさ")
        c2.backspace()
        c2.input("o")
        XCTAssertEqual(c2.kana, "ど")
        // 消さずに続けたときは従来どおり
        XCTAssertEqual(type("dse").kana, "dせ")
        // 大文字で始めた英字入力は巻き戻さない
        var c3 = type("Apple")
        c3.backspace()
        c3.input("a")
        XCTAssertEqual(c3.kana, "Appla")
    }

    func testPending() {
        var c = type("kan")
        XCTAssertEqual(c.kana, "か")
        XCTAssertEqual(c.pending, "n")
        c.flush()
        XCTAssertEqual(c.kana, "かん")
        c = type("sh")
        XCTAssertEqual(c.kana, "")
        XCTAssertEqual(c.pending, "sh")
    }

    func testLiteralsAndBackspace() {
        XCTAssertEqual(type("2026nen").kana + type("2026nen").pending, "2026ねn")
        var c = type("kya")
        XCTAssertEqual(c.kana, "きゃ")
        c.backspace()
        XCTAssertEqual(c.kana, "き")
        c.backspace()
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(type("Apple").kana, "Apple")
        XCTAssertEqual(type("iPhone").kana, "いPhone")
        XCTAssertEqual(type("kaigi").raw, "kaigi")
    }
}
