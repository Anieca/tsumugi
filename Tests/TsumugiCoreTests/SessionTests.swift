import XCTest
@testable import TsumugiCore

/// 辞書を使う結合テスト。先に `make dict` で build/system.dict を作っておく。
final class SessionTests: XCTestCase {
    static let dictionary: SystemDictionary? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/system.dict")
        return try? SystemDictionary(url: url)
    }()

    var user: UserModel!
    var session: Session!
    var commits: [String] = []
    var clock = 1_000_000.0

    override func setUpWithError() throws {
        let dict = try XCTUnwrap(Self.dictionary, "build/system.dict がありません")
        user = UserModel(fileURL: nil)
        user.now = { [unowned self] in self.clock }
        session = Session(converter: Converter(dictionary: dict, userModel: user), userModel: user)
        commits = []
        session.onCommit = { [unowned self] in self.commits.append($0) }
    }

    private func type(_ s: String) { for c in s { session.handle(.char(c)) } }

    func testConverter() throws {
        let c = Converter(dictionary: try XCTUnwrap(Self.dictionary))
        XCTAssertEqual(c.convert("きょうはいいてんきですね").first?.text, "今日はいい天気ですね")
        XCTAssertEqual(c.convert("おせわになっております").first?.text, "お世話になっております")
        XCTAssertEqual(c.convert("2026ねん3がつ").first?.text, "2026年3月")
        let n = c.convert("こうせいをかくにんする", nbest: 8)
        XCTAssertEqual(n.count, 8)
        XCTAssertEqual(Set(n.map(\.text)).count, 8)
        XCTAssertTrue(zip(n, n.dropFirst()).allSatisfy { $0.cost <= $1.cost })
        // 読みは必ず保存される
        for conv in n { XCTAssertEqual(conv.reading, "こうせいをかくにんする") }
        XCTAssertEqual(c.match(reading: "かれのこうえんをきいた", surface: "彼の講演を聞いた")?.text, "彼の講演を聞いた")
        XCTAssertNil(c.match(reading: "かれのこうえんをきいた", surface: "彼の講演を見た"))
        XCTAssertEqual(c.match(reading: "ちゃっとじーぴーてぃーをつかう", surface: "ChatGPTを使う")?.text, "ChatGPTを使う")
        XCTAssertFalse(c.convert("ぬぬぬぬっっっゃゃ").isEmpty)
    }

    func testLiveConversionAndCommit() {
        type("kyouhaiitenkidesune")
        XCTAssertEqual(session.view.markedText, "今日はいい天気ですね")
        XCTAssertTrue(session.handle(.enter))
        XCTAssertEqual(commits, ["今日はいい天気ですね"])
        XCTAssertFalse(session.view.isComposing)
        // 未入力のときのキーはアプリに渡す
        XCTAssertFalse(session.handle(.enter))
        XCTAssertFalse(session.handle(.tab))
        XCTAssertFalse(session.handle(.char("1")))
    }

    func testPendingRomajiAndBackspace() {
        type("kak")
        XCTAssertEqual(session.view.segments.last, "k")
        session.handle(.backspace)
        session.handle(.backspace)
        XCTAssertFalse(session.view.isComposing)
        type("kan")
        session.handle(.enter)
        XCTAssertEqual(commits.last?.count, 1) // 「かん」が 1 語に変換される (末尾の n は「ん」)
    }

    func testCandidateSelectionLearns() {
        type("kouseiwokakuninsuru")
        let first = session.view.markedText
        session.handle(.space)
        let v = session.view
        XCTAssertEqual(v.focus, 0)
        XCTAssertEqual(v.candidateIndex, 1)
        let picked = v.candidates[1]
        XCTAssertNotEqual(picked, v.candidates[0])
        session.handle(.enter)
        XCTAssertNotEqual(commits.last, first)
        XCTAssertTrue(commits.last!.hasPrefix(picked))
        // 次からは選んだ表記が最初に出る
        type("kouseiwokakuninsuru")
        XCTAssertTrue(session.view.markedText.hasPrefix(picked))
    }

    func testSegmentResizeAndEscape() {
        type("kyouhaisyaniiku")
        session.handle(.right)
        let before = session.view.segments
        session.handle(.shiftLeft)
        XCTAssertNotEqual(session.view.segments, before)
        XCTAssertEqual(session.view.segments.joined().isEmpty, false)
        session.handle(.escape)
        XCTAssertNil(session.view.focus)
        XCTAssertEqual(session.view.segments, before)
        session.handle(.katakana)
        session.handle(.enter)
        XCTAssertEqual(commits, ["キョウハイシャニイク"])
        type("apple")
        session.handle(.latin)
        session.handle(.enter)
        XCTAssertEqual(commits.last, "apple")
    }

    func testHistoryCompletionWithTab() {
        type("osewaninatteorimasu")
        session.handle(.enter)
        XCTAssertEqual(commits, ["お世話になっております"])
        type("ose")
        XCTAssertNil(session.view.ghost) // 2 文字では 1 回使っただけの句は出さない
        type("wa")
        XCTAssertEqual(session.view.ghost?.text, "お世話になっております")
        XCTAssertEqual(session.view.ghost?.source, .history)
        session.handle(.tab)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits.last, "お世話になっております")
        // Esc は先読みだけを消し、入力は残す
        type("osewa")
        XCTAssertNotNil(session.view.ghost)
        session.handle(.escape)
        XCTAssertNil(session.view.ghost)
        XCTAssertTrue(session.view.isComposing)
        type("ni")
        XCTAssertNil(session.view.ghost)
        session.handle(.escape)
        XCTAssertFalse(session.view.isComposing)
    }

    func testNextPhrasePrediction() {
        for _ in 0..<2 {
            type("otukaresamadesu")
            session.handle(.enter)
            clock += 3
            type("tanakadesu")
            session.handle(.enter)
            clock += 100
        }
        type("otukaresamadesu")
        session.handle(.enter)
        let g = session.view.ghost
        XCTAssertEqual(g?.text, commits[1])
        XCTAssertTrue(session.handle(.tab))
        XCTAssertEqual(commits.last, commits[1])
        // 学習を止めている間は覚えない
        user.isPaused = true
        let before = user.stats.phrases
        type("himitunohanasi")
        session.handle(.enter)
        XCTAssertEqual(user.stats.phrases, before)
    }

    func testUserModelPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tsumugi-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = UserModel(fileURL: url)
        a.recordCommit(reading: "よろしくおねがいします", surface: "よろしくお願いします", previous: nil)
        a.learnChoice(reading: "こうせい", surface: "校正", lid: 1851, rid: 1851, cost: 5000, topCost: 3000)
        a.saveNow()
        let b = UserModel(fileURL: url)
        XCTAssertEqual(b.completePhrase(readingPrefix: "よろし")?.surface, "よろしくお願いします")
        XCTAssertEqual(b.learnedWords(reading: "こうせい").first?.word.surface, "校正")
        XCTAssertLessThan(b.learnedWords(reading: "こうせい")[0].cost, 3000)
        b.forgetAll()
        XCTAssertNil(UserModel(fileURL: url).completePhrase(readingPrefix: "よろし"))
    }

    func testAppContextIsUsedAsLeftContext() {
        let llm = FakeNeural()
        session = Session(converter: Converter(dictionary: Self.dictionary!, userModel: user), userModel: user, neural: llm)
        session.runsNeuralInline = true
        session.onCommit = { [unowned self] in self.commits.append($0) }
        var document = "田中様\nお世話になっております。"
        session.contextProvider = { document }
        type("kyou")
        XCTAssertEqual(llm.contexts.last, document)
        // 入力先への反映が遅れても、いま確定した文字列は文脈に入る
        session.handle(.enter)
        XCTAssertEqual(llm.contexts.last, document + commits[0])
        // 文章を読めない入力先では、自分が確定した文字列をつないで文脈にする
        document = ""
        session.contextProvider = { nil }
        type("ha")
        XCTAssertEqual(llm.contexts.last, "田中様\nお世話になっております。" + commits[0])
    }

    func testGhostDisappearsWhenRomajiDiverges() {
        let llm = FakeNeural()
        llm.prediction = "しりょうをてんぷ"
        session = Session(converter: Converter(dictionary: Self.dictionary!, userModel: user), userModel: user, neural: llm)
        session.runsNeuralInline = true
        type("siryou")
        XCTAssertEqual(session.view.ghost?.reading, "しりょうをてんぷ")
        type("w")   // 「を」の打ちかけ。先読みどおりなので残す
        XCTAssertNotNil(session.view.ghost)
        session.handle(.backspace)
        type("n")   // 「を」にはならない打ちかけ。すぐに消す
        XCTAssertNil(session.view.ghost)
    }

    func testHabitLearnsReadingSequences() {
        XCTAssertNil(user.habit(after: "つむぎか"))
        for _ in 0..<2 {
            user.recordReading("おせわになっております。", continues: false)
            user.recordReading("つむぎかぶしきがいしゃのいしいです。", continues: true)
        }
        // 確定の区切りをまたいで、読みの並びとして覚えている
        let h = user.habit(after: "なっております。")
        XCTAssertEqual(h?.next, ["つ": 1])
        XCTAssertGreaterThan(h?.weight ?? 0, 0.3)
        XCTAssertEqual(user.habit(after: "つむぎか")?.next, ["ぶ": 1])
        // 別のまとまりの先頭とはつながない
        XCTAssertNil(user.habit(after: "いしいです。")?.next["お"])
        // 手がかりが短すぎるときは何も言わない
        XCTAssertNil(user.habit(after: "つむ"))
        // セッションは、確定した読みを書き癖として記録し、予測のときに LLM へ渡す
        let llm = FakeNeural()
        session = Session(converter: Converter(dictionary: Self.dictionary!, userModel: user), userModel: user, neural: llm)
        session.runsNeuralInline = true
        type("osewaninatteorimasu.")
        session.handle(.enter)
        XCTAssertEqual(llm.habits.last??("")?.next, ["つ": 1])
        user.forgetAll()
        XCTAssertNil(user.habit(after: "なっております。"))
    }

    func testRomajiKeys() {
        XCTAssertEqual(Romaji.keys(for: "きょうはがっこうにいった。"), "kyouhagakkouniitta.")
        XCTAssertEqual(Romaji.keys(for: "しんぶんをよんだ"), "sinnbunnwoyonnda")
        XCTAssertTrue(Romaji.isTyping("sh", toward: "しょうひん"))
        XCTAssertTrue(Romaji.isTyping("k", toward: "っか"))
        XCTAssertTrue(Romaji.isTyping("n", toward: "んで"))
        XCTAssertFalse(Romaji.isTyping("k", toward: "さ"))
        XCTAssertTrue(Romaji.isTyping("", toward: ""))
    }

    /// 入力中に英数へ切り替えても確定せず、英字を半角のまま足し、かなに戻ればローマ字に戻る。
    func testSwitchingToLatinKeepsComposition() {
        type("kore")
        session.setDirectInput(true)
        XCTAssertTrue(session.isComposing)
        XCTAssertTrue(commits.isEmpty)
        type("iPhone")
        session.handle(.space)
        type("15,")
        XCTAssertEqual(session.view.markedText, "これiPhone 15,")
        session.setDirectInput(false)
        type("noke-su")
        XCTAssertTrue(session.view.markedText.hasPrefix("これiPhone 15,"))
        XCTAssertTrue(session.view.markedText.hasSuffix("ケース"), session.view.markedText)
        session.handle(.enter)
        XCTAssertEqual(commits.count, 1)
        XCTAssertTrue(commits[0].hasPrefix("これiPhone 15,"))
    }

    /// 打ちかけのローマ字は切り替えた時点で文字にする。何も入力していなければ打鍵はアプリへ。
    func testLatinModeFlushesPendingAndPassesThroughWhenIdle() {
        type("kan")
        session.setDirectInput(true)
        XCTAssertFalse(session.view.markedText.contains("n"), session.view.markedText)  // 「かん」として変換される
        session.handle(.backspace)
        session.handle(.backspace)
        XCTAssertFalse(session.isComposing)
        XCTAssertFalse(session.handle(.char("a")))
        XCTAssertFalse(session.handle(.space))
        XCTAssertNil(session.view.ghost)
        session.setDirectInput(false)
        type("a")
        XCTAssertEqual(session.view.markedText, "あ")
    }
}

/// 呼ばれ方を記録するだけの LLM 役。
private final class FakeNeural: NeuralAssist {
    var contexts: [String] = []
    var habits: [HabitHint?] = []
    /// 続きの予測として返す読み。
    var prediction: String?

    func convert(reading: String, leftContext: String, isCancelled: () -> Bool) -> String? {
        contexts.append(leftContext)
        return nil
    }

    func predict(readingPrefix: String, leftContext: String, habit: HabitHint?, isCancelled: () -> Bool) -> NeuralPrediction? {
        contexts.append(leftContext)
        habits.append(habit)
        guard let p = prediction, p.hasPrefix(readingPrefix), p.count > readingPrefix.count else { return nil }
        return NeuralPrediction(reading: p, surface: nil, confidence: 0.9)
    }
}
