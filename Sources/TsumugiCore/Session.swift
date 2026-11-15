import Foundation

/// 入力メソッドが受け取るキー。
public enum Key: Equatable {
    case char(Character)
    case space, shiftSpace, enter, backspace, escape, tab
    case left, right, up, down, shiftLeft, shiftRight
    case hiragana, katakana, latin
}

/// Tab で確定できる先読み。
public struct Ghost: Equatable {
    public enum Source: Equatable { case history, neural }
    /// Tab を押したときに確定される文字列。
    public var text: String
    public var reading: String
    public var source: Source

    public init(text: String, reading: String, source: Source) {
        self.text = text
        self.reading = reading
        self.source = source
    }
}

/// 画面に出すべき内容。
public struct SessionView: Equatable {
    /// 未確定文字列を文節ごとに分けたもの。空なら未確定文字列なし。
    public var segments: [String] = []
    /// 選択中の文節 (候補選択中のみ)。
    public var focus: Int?
    public var candidates: [String] = []
    public var candidateIndex = 0
    public var ghost: Ghost?

    public init() {}

    public var markedText: String { segments.joined() }
    public var isComposing: Bool { !segments.isEmpty }
}

/// 1 つの入力先に対する入力状態。メインスレッドから使う。
public final class Session {
    private enum Mode { case idle, composing, selecting }

    private let converter: Converter
    private let userModel: UserModel
    private let neural: NeuralAssist?

    /// 確定文字列を入力先へ送る。
    public var onCommit: ((String) -> Void)?
    /// キー操作によらない表示の更新 (LLM の結果が後から届いたとき)。
    public var onAsyncUpdate: (() -> Void)?
    /// LLM の結果をこの秒数だけ待ってから表示する。間に合えば表示のちらつきがなくなる。
    public var neuralDeadline: TimeInterval = 0.03
    /// 続きの先読みを出すかどうか。
    public var predictionEnabled = true
    /// 先読みに自分の書き癖を混ぜるかどうか (計測用に切れるようにしてある)。
    public var usesHabit = true
    /// 入力先のカーソルより前にある文章 (取れないアプリでは nil)。
    /// あれば自分が確定した文字列の代わりに、これを LLM の左文脈にする。端末の外には出さず、保存もしない。
    public var contextProvider: (() -> String?)?
    /// テスト用: LLM の処理を呼び出し元スレッドで同期実行する。
    public var runsNeuralInline = false

    private var mode = Mode.idle
    private var composer = Composer()
    private var live: [Segment] = []
    private var ghost: Ghost?
    private var ghostSuppressed = false

    private var segments: [Segment] = []
    private var explicit: [Bool] = []
    private var focus = 0
    private var candidates: [Segment] = []
    private var candidateIndex = 0

    private var leftContext = ""
    /// この入力先で続けて確定した読み。書き癖 (読みの並び) を引くための手がかり。
    private var leftReading = ""
    private var lastCommit: (text: String, time: Double)?

    private let queue = DispatchQueue(label: "tsumugi.neural", qos: .userInitiated)
    private let genLock = NSLock()
    private var generation = 0

    public init(converter: Converter, userModel: UserModel, neural: NeuralAssist? = nil) {
        self.converter = converter
        self.userModel = userModel
        self.neural = neural
    }

    // MARK: 表示

    public var view: SessionView {
        var v = SessionView()
        switch mode {
        case .idle:
            break
        case .composing:
            v.segments = live.map(\.surface)
            if !composer.pending.isEmpty { v.segments.append(composer.pending) }
        case .selecting:
            v.segments = segments.map(\.surface)
            v.focus = focus
            v.candidates = candidates.map(\.surface)
            v.candidateIndex = candidateIndex
        }
        v.ghost = ghost
        return v
    }

    public var isComposing: Bool { mode != .idle }

    /// 英字入力モード (英数キー)。入力中に切り替えても確定せず、以降の打鍵を半角のまま足す。
    /// 何も入力していないときは、打鍵はアプリへそのまま渡す。
    public private(set) var directInput = false

    public func setDirectInput(_ on: Bool) {
        guard on != directInput else { return }
        directInput = on
        composer.direct = on
        if on { dismissGhost() }
        if mode == .composing { refreshComposition() }
    }

    // MARK: キー入力

    /// - Returns: キーを処理したら true。false のときは入力先のアプリに渡す。
    @discardableResult
    public func handle(_ key: Key) -> Bool {
        switch mode {
        case .idle: return handleIdle(key)
        case .composing: return handleComposing(key)
        case .selecting: return handleSelecting(key)
        }
    }

    private func handleIdle(_ key: Key) -> Bool {
        if directInput {
            dismissGhost()
            leftContext = ""
            leftReading = ""
            return false
        }
        switch key {
        case .tab:
            guard let g = ghost else { return false }
            commit(text: g.text, reading: g.reading)
            return true
        case .escape:
            guard ghost != nil else { return false }
            dismissGhost()
            return true
        case .char(let c):
            // かなにならない数字や記号は、未入力のときはそのままアプリへ渡す
            guard c.isLetter || RomajiTable.table[String(c)] != nil else {
                dismissGhost()
                leftContext = String((leftContext + String(c)).suffix(Self.contextWindow))
                leftReading = ""
                return false
            }
            ghost = nil
            ghostSuppressed = false
            syncContext(appending: "")
            mode = .composing
            composer.input(c)
            refreshComposition()
            return true
        default:
            dismissGhost()
            if key == .enter || key == .backspace { leftContext = ""; leftReading = ""; lastCommit = nil }
            return false
        }
    }

    private func handleComposing(_ key: Key) -> Bool {
        switch key {
        case .char(let c):
            composer.input(c)
            refreshComposition()
        case .backspace:
            composer.backspace()
            refreshComposition()
        case .enter:
            finalizeLive()
            commit(text: live.map(\.surface).joined(), reading: composer.kana)
        case .tab:
            if let g = ghost { commit(text: g.text, reading: g.reading) }
        case .escape:
            if ghost != nil {
                ghost = nil
                ghostSuppressed = true
                bumpGeneration()
            } else {
                composer.clear()
                refreshComposition()
            }
        case .space where directInput, .shiftSpace where directInput:
            composer.input(" ")
            refreshComposition()
        case .space, .shiftSpace, .down:
            finalizeLive()
            enterSelecting()
            moveCandidate(1)
        case .left, .right, .shiftLeft, .shiftRight:
            finalizeLive()
            enterSelecting()
            if key == .left { focus = segments.count - 1; loadCandidates() }
            if key == .shiftLeft || key == .shiftRight { _ = handleSelecting(key) }
        case .hiragana, .katakana, .latin:
            finalizeLive()
            transliterate(key)
        case .up:
            break
        }
        return true
    }

    private func handleSelecting(_ key: Key) -> Bool {
        switch key {
        case .space, .down, .tab:
            moveCandidate(1)
        case .shiftSpace, .up:
            moveCandidate(-1)
        case .left:
            focus = (focus + segments.count - 1) % segments.count
            loadCandidates()
        case .right:
            focus = (focus + 1) % segments.count
            loadCandidates()
        case .shiftLeft:
            resizeFocused(-1)
        case .shiftRight:
            resizeFocused(1)
        case .enter:
            commitSelection()
        case .escape, .backspace:
            // 変換前の入力中の状態に戻る
            mode = .composing
            refreshComposition()
        case .hiragana, .katakana, .latin:
            transliterate(key)
        case .char(let c):
            if let d = c.wholeNumberValue, c.isASCII, (1...9).contains(d) {
                let page = candidateIndex / 9 * 9
                if page + d - 1 < candidates.count {
                    select(page + d - 1)
                    if focus < segments.count - 1 {
                        focus += 1
                        loadCandidates()
                    } else {
                        commitSelection()
                    }
                }
            } else {
                // 文字を打ち始めたら、いまの変換を確定して次の入力へ
                commitSelection()
                return handleIdle(key)
            }
        }
        return true
    }

    // MARK: 入力中 (ライブ変換)

    private func refreshComposition() {
        if composer.isEmpty {
            mode = .idle
            live = []
            ghost = nil
            bumpGeneration()
            return
        }
        let reading = composer.kana
        live = reading.isEmpty ? [] : (converter.convert(reading).first?.segments ?? [])
        if ghostSuppressed || !predictionEnabled || directInput {
            ghost = nil
        } else if composer.pending.isEmpty {
            if let phrase = userModel.completePhrase(readingPrefix: reading) {
                ghost = Ghost(text: phrase.surface, reading: phrase.reading, source: .history)
            } else if let g = ghost, g.reading.hasPrefix(reading), g.reading.count > reading.count {
                // 先読みどおりに打ち進めている間は、同じ先読みを出したままにする (ちらつかせない)
            } else {
                ghost = nil
            }
        } else if let g = ghost,
                  !g.reading.hasPrefix(reading) || !Romaji.isTyping(composer.pending, toward: String(g.reading.dropFirst(reading.count))) {
            // 打ちかけのローマ字が先読みと食い違ったら、すぐに消す
            ghost = nil
        }
        scheduleNeural(reading: reading)
    }

    /// 変換・確定の前に、打ちかけのローマ字を確定させて読みを固める。
    private func finalizeLive() {
        guard !composer.pending.isEmpty else { return }
        composer.flush()
        let reading = composer.kana
        live = converter.convert(reading).first?.segments ?? []
        scheduleNeural(reading: reading, predict: false)
    }

    @discardableResult
    private func bumpGeneration() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ gen: Int) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return generation == gen
    }

    /// LLM に変換の見直しと続きの予測を頼む。
    private func scheduleNeural(reading: String, predict: Bool = true) {
        let gen = bumpGeneration()
        guard let neural, !reading.isEmpty else { return }
        let context = leftContext
        let habit = habitHint()
        let wantsPrediction = predict && predictionEnabled && !directInput && ghost == nil && !ghostSuppressed && composer.pending.isEmpty
        let converter = self.converter
        let cancelled = { [weak self] in !(self?.isCurrent(gen) ?? false) }

        let refine: () -> [Segment]? = {
            guard reading.count >= 2, !cancelled(),
                  let out = neural.convert(reading: reading, leftContext: context, isCancelled: cancelled),
                  let conv = converter.match(reading: reading, surface: out) else { return nil }
            return conv.segments
        }
        let predictGhost: () -> Ghost? = {
            guard wantsPrediction, !cancelled(),
                  let p = neural.predict(readingPrefix: reading, leftContext: context, habit: habit, isCancelled: cancelled),
                  p.reading.count >= reading.count + 2 else { return nil }
            var text = converter.convert(p.reading).first?.text
            if let out = neural.convert(reading: p.reading, leftContext: context, isCancelled: cancelled),
               converter.match(reading: p.reading, surface: out) != nil {
                text = out
            }
            return text.map { Ghost(text: $0, reading: p.reading, source: .neural) }
        }

        if runsNeuralInline {
            if let r = refine() { applyRefined(r) }
            if let g = predictGhost() { ghost = g }
            return
        }

        // 変換の見直しは締め切りまで待ち、間に合えば最初からその結果を表示する
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            let refined = refine()
            box.set(refined)
            done.signal()
            if box.timedOut, let refined {
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(gen), self.mode == .composing else { return }
                    self.applyRefined(refined)
                    self.onAsyncUpdate?()
                }
            }
            if let g = predictGhost() {
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(gen), self.mode == .composing else { return }
                    self.ghost = g
                    self.onAsyncUpdate?()
                }
            }
        }
        if done.wait(timeout: .now() + neuralDeadline) == .success {
            if let refined = box.value { applyRefined(refined) }
        } else {
            box.markTimedOut()
            // 待っている間に終わっていた場合を拾う
            if let refined = box.value { applyRefined(refined) }
        }
    }

    /// LLM の変換を採用する。ただし、ユーザーが自分で覚えさせた表記は上書きしない。
    private func applyRefined(_ refined: [Segment]) {
        let text = refined.map(\.surface).joined()
        for seg in live where seg.learned && !text.contains(seg.surface) { return }
        live = refined
    }

    // MARK: 候補選択

    private func enterSelecting() {
        bumpGeneration()
        ghost = nil
        mode = .selecting
        segments = live
        explicit = Array(repeating: false, count: segments.count)
        focus = 0
        loadCandidates()
    }

    private func loadCandidates() {
        guard focus < segments.count else { return }
        let current = segments[focus]
        var list = converter.segmentCandidates(current.reading)
        if let i = list.firstIndex(where: { $0.surface == current.surface }) {
            list.remove(at: i)
        }
        list.insert(current, at: 0)
        candidates = list
        candidateIndex = 0
    }

    private func moveCandidate(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        select((candidateIndex + delta + candidates.count) % candidates.count)
    }

    private func select(_ index: Int) {
        candidateIndex = index
        if segments[focus].surface != candidates[index].surface {
            segments[focus] = candidates[index]
            explicit[focus] = true
        }
    }

    /// 選択中の文節を伸び縮みさせ、右側を変換し直す。
    private func resizeFocused(_ delta: Int) {
        let reading = Array(segments[focus...].map(\.reading).joined())
        let newLength = segments[focus].reading.count + delta
        guard newLength >= 1, newLength <= reading.count else { return }
        let head = String(reading[..<newLength])
        let tail = String(reading[newLength...])
        guard let first = converter.segmentCandidates(head, limit: 1).first else { return }
        let rest = tail.isEmpty ? [] : (converter.convert(tail, leftRid: first.rid).first?.segments ?? [])
        segments = Array(segments[..<focus]) + [first] + rest
        explicit = Array(explicit[..<focus]) + Array(repeating: false, count: rest.count + 1)
        loadCandidates()
    }

    /// ひらがな・カタカナ・英数への直接変換。
    private func transliterate(_ key: Key) {
        let reading = mode == .selecting ? segments.map(\.reading).joined() : composer.kana
        guard !reading.isEmpty else { return }
        let surface: String
        switch key {
        case .katakana: surface = reading.katakana
        case .latin: surface = composer.raw
        default: surface = reading
        }
        let unk = converter.dictionary.unknownId
        bumpGeneration()
        ghost = nil
        mode = .selecting
        segments = [Segment(reading: reading, surface: surface, lid: unk, rid: unk, cost: 6000)]
        explicit = [key != .latin]
        focus = 0
        loadCandidates()
    }

    private func commitSelection() {
        for (i, seg) in segments.enumerated() where explicit[i] {
            let top = converter.segmentCandidates(seg.reading, limit: 12).map(\.cost).min() ?? seg.cost
            userModel.learnChoice(reading: seg.reading, surface: seg.surface, lid: seg.lid, rid: seg.rid, cost: seg.cost, topCost: top)
        }
        commit(text: segments.map(\.surface).joined(), reading: segments.map(\.reading).joined())
    }

    // MARK: 確定

    private func commit(text: String, reading: String) {
        let gen = bumpGeneration()
        composer.clear()
        mode = .idle
        live = []
        segments = []
        candidates = []
        ghostSuppressed = false
        ghost = nil
        guard !text.isEmpty else { return }
        onCommit?(text)
        let now = userModel.now()
        let previous = lastCommit.flatMap { now - $0.time < 30 ? $0.text : nil }
        userModel.recordCommit(reading: reading, surface: text, previous: previous)
        userModel.recordReading(reading, continues: previous != nil)
        lastCommit = (text, now)
        syncContext(appending: text)
        leftReading = String((leftReading + reading).suffix(UserModel.maxHabitOrder))

        // 続けて入力しそうな句を先読みする
        guard predictionEnabled else { return }
        if let next = userModel.nextPhrase(after: text) {
            ghost = Ghost(text: next.surface, reading: next.reading, source: .history)
            return
        }
        guard let neural else { return }
        let context = leftContext
        let habit = habitHint()
        let converter = self.converter
        let cancelled = { [weak self] in !(self?.isCurrent(gen) ?? false) }
        let work: () -> Ghost? = {
            guard let p = neural.predict(readingPrefix: "", leftContext: context, habit: habit, isCancelled: cancelled),
                  p.reading.count >= 3, p.confidence >= 0.45 else { return nil }
            var out = converter.convert(p.reading).first?.text
            if let o = neural.convert(reading: p.reading, leftContext: context, isCancelled: cancelled),
               converter.match(reading: p.reading, surface: o) != nil {
                out = o
            }
            return out.map { Ghost(text: $0, reading: p.reading, source: .neural) }
        }
        if runsNeuralInline {
            ghost = work()
            return
        }
        queue.async { [weak self] in
            guard let g = work() else { return }
            DispatchQueue.main.async {
                guard let self, self.isCurrent(gen), self.mode == .idle else { return }
                self.ghost = g
                self.onAsyncUpdate?()
            }
        }
    }

    /// 左文脈を最新にする。入力先の文章が読めるならそれを使い、読めなければ自分が確定した文字列をつなぐ。
    /// - Parameter text: いま確定した文字列。入力先への反映が遅れるアプリでも文脈に含める。
    private func syncContext(appending text: String) {
        if let doc = contextProvider?() {
            leftContext = doc.hasSuffix(text) ? doc : doc + text
        } else {
            leftContext += text
        }
        leftContext = String(leftContext.suffix(Self.contextWindow))
    }

    private static let contextWindow = 300

    /// LLM が読みの続きを 1 文字ずつ予測するときに、自分の書き癖を混ぜるための関数。
    private func habitHint() -> HabitHint? {
        guard usesHabit else { return nil }
        let userModel = self.userModel
        let before = leftReading
        return { soFar in userModel.habit(after: before + soFar) }
    }

    private func dismissGhost() {
        if ghost != nil {
            ghost = nil
            bumpGeneration()
        }
    }

    /// 入力先が切り替わるときなどに、未確定文字列をそのまま確定する。
    public func commitAll() {
        switch mode {
        case .idle: break
        case .composing:
            finalizeLive()
            commit(text: live.map(\.surface).joined(), reading: composer.kana)
        case .selecting:
            commitSelection()
        }
        dismissGhost()
    }

    /// 文脈を忘れる (入力先が変わったとき)。
    public func resetContext() {
        leftContext = ""
        leftReading = ""
        lastCommit = nil
        dismissGhost()
    }
}

/// バックグラウンドの結果を締め切りつきで受け取るための箱。
private final class ResultBox {
    private let lock = NSLock()
    private var stored: [Segment]?
    private var timeout = false

    var value: [Segment]? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timeout
    }

    func set(_ v: [Segment]?) {
        lock.lock(); defer { lock.unlock() }
        stored = v
    }

    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        timeout = true
    }
}
