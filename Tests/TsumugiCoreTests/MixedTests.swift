import XCTest
@testable import TsumugiCore

/// 日本語モードのまま打った英単語の切り分け。辞書を使う結合テスト。
final class MixedTests: XCTestCase {
    var user: UserModel!
    var lexicon: LatinLexicon!
    var segmenter: MixedSegmenter!
    var session: Session!
    var commits: [String] = []

    override func setUpWithError() throws {
        let dict = try XCTUnwrap(SessionTests.dictionary, "build/system.dict がありません")
        user = UserModel(fileURL: nil)
        let converter = Converter(dictionary: dict, userModel: user)
        lexicon = LatinLexicon(fileURL: nil)
        for w in ["Tab", "Notion", "hook", "main"] { lexicon.learn(w, weight: 2) }
        segmenter = MixedSegmenter(converter: converter, lexicon: lexicon)
        segmenter.usesSystemWords = false
        session = Session(converter: converter, userModel: user)
        session.mixed = segmenter
        commits = []
        session.onCommit = { [unowned self] in self.commits.append($0) }
    }

    private func type(_ s: String) { for c in s { session.handle(.char(c)) } }
    private func pieces(_ raw: String) -> [String]? {
        segmenter.plan(raw: raw, final: true)?.pieces.map { $0.isEnglish ? "[" + $0.text + "]" : $0.text }
    }

    func testPlan() {
        XCTAssertEqual(pieces("tabdenaosu"), ["[Tab]", "でなおす"])
        XCTAssertEqual(pieces("korehanotiondesu"), ["これは", "[Notion]", "です"])
        XCTAssertEqual(pieces("hookwotomete"), ["[hook]", "をとめて"])
        // 日本語だけなら切り分けない
        XCTAssertNil(pieces("kyouhaiitenkidesune"))
        XCTAssertNil(pieces("soremadenikaku"))
        // 大文字ではじめた語は、知らなくても英字。どこまでかは後ろの日本語で決まる
        XCTAssertEqual(pieces("NYryokou"), ["[NY]", "りょこう"])
        // ローマ字にならない綴りは、知らない語でも英字
        XCTAssertEqual(pieces("uvxdeonegai"), ["[uvx]", "でおねがい"])
        // 長音や記号をはさんでも続けて扱う
        XCTAssertEqual(pieces("ko-dowomainniireru"), ["こーどを", "[main]", "にいれる"])
    }

    func testPendingWhileTyping() {
        let p = segmenter.plan(raw: "tabd")
        XCTAssertEqual(p?.pieces.map(\.text), ["Tab"])
        XCTAssertEqual(p?.pending, "d")
    }

    func testLexiconNeedsTwoSightings() {
        lexicon.learn("redis")
        XCTAssertNil(lexicon.lookup("redis"))
        lexicon.learn("redis")
        XCTAssertEqual(lexicon.lookup("redis")?.form, "redis")
        // かなに直されたら、英字にしなくなる
        lexicon.reject("redis")
        XCTAssertNil(lexicon.lookup("redis"))
    }

    func testTypingCommitsMixedText() {
        type("tabdenaosu")
        XCTAssertEqual(session.view.markedText, "Tabで直す")
        session.handle(.enter)
        XCTAssertEqual(commits, ["Tabで直す"])
        // 英字まじりの確定は、言い回しとしては覚えない
        XCTAssertEqual(user.stats.phrases, 0)
    }

    func testJapaneseOnlyIsUnchanged() {
        type("kyouhaiitenkidesune")
        XCTAssertEqual(session.view.markedText, "今日はいい天気ですね")
        session.handle(.enter)
        XCTAssertEqual(commits, ["今日はいい天気ですね"])
    }

    func testCapitalWordIsLearned() {
        type("Redisdesu")
        XCTAssertEqual(session.view.segments.first, "Redis")
        session.handle(.enter)
        // 自分で大文字にした語は、次から小文字で打っても同じ表記になる
        type("redisdesu")
        XCTAssertEqual(session.view.segments.first, "Redis")
    }

    func testLatinKeyPinsTailWord() {
        type("watasihamineo")
        XCTAssertFalse(session.view.markedText.contains("mineo"))
        session.handle(.latin)
        XCTAssertTrue(session.view.markedText.hasSuffix("mineo"))
        type("desu")
        session.handle(.enter)
        XCTAssertEqual(commits.last, "私はmineoです")
        // 英数キーで示した語は、次から自動で英字になる
        type("mineodesu")
        XCTAssertEqual(session.view.segments.first, "mineo")
    }

    func testChoosingKanaRejectsWord() {
        type("maindesu")
        XCTAssertEqual(session.view.segments.first, "main")
        session.handle(.space)
        let i = try! XCTUnwrap(session.view.candidates.firstIndex(of: "まいん"))
        for _ in 0..<i { session.handle(.space) }
        session.handle(.enter)
        XCTAssertEqual(commits.last?.hasPrefix("まいん"), true)
        type("maindesu")
        XCTAssertNotEqual(session.view.segments.first, "main")
    }

    func testBackspaceUndoesEnglish() {
        type("tabd")
        for _ in 0..<2 { session.handle(.backspace) }
        XCTAssertEqual(session.view.markedText, "た")
    }

    func testSpacing() {
        XCTAssertTrue(Spacing.needsSpace(after: "context", before: "manager", betweenWords: true))
        XCTAssertFalse(Spacing.needsSpace(after: "context", before: "manager"))
    }
}
