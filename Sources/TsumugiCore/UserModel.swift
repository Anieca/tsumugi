import Foundation

/// ユーザーが選んだ変換 (読み → 表記)。ラティスに追加ノードとして参加する。
public struct LearnedWord: Codable, Equatable {
    public var reading: String
    public var surface: String
    public var lid: UInt16
    public var rid: UInt16
    public var cost: Int32
    public var count: Double
    public var last: Double
}

/// 確定した文や句の履歴。先読み補完に使う。
public struct PhraseRecord: Codable, Equatable {
    public var reading: String
    public var surface: String
    public var count: Double
    public var last: Double
}

/// 入力履歴から学習する個人モデル。すべて端末内の 1 ファイルに保存される。
public final class UserModel {
    struct Snapshot: Codable {
        var version = 1
        var words: [String: [LearnedWord]] = [:]
        var phrases: [String: PhraseRecord] = [:]
        var nexts: [String: [String: PhraseRecord]] = [:]
        /// 確定した読みを、続けて打ったまとまりごとに並べたもの。書き癖 (読みの並び) を引くのに使う。
        var log: [String]?
    }

    private let lock = NSLock()
    private var snap = Snapshot()
    private let fileURL: URL?
    private var saveScheduled = false
    private let saveQueue = DispatchQueue(label: "tsumugi.usermodel.save", qos: .utility)
    /// テスト用に時刻を差し替えられる。
    public var now: () -> Double = { Date().timeIntervalSince1970 }
    /// true の間は何も学習しない。
    public var isPaused = false

    /// 書き癖を引くときに見る、直前の読みの最大文字数。
    public static let maxHabitOrder = 8
    private static let minHabitOrder = 3
    private static let maxHabitKana = 30000
    /// log を区切り文字でつないだもの。
    private var habitChars: [Character] = []
    /// 読み 3 文字 → その直後の文字の位置 (habitChars 内)。
    private var habitIndex: [String: [Int32]] = [:]
    private static let streamBreak: Character = "\n"

    public static let maxPhraseReadingLength = 40
    public static let maxLearnedLength = 24
    private static let maxPhrases = 4000

    /// - Parameter fileURL: nil ならメモリ上のみ (テスト用)。
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snap = s
        }
        rebuildHabit()
    }

    public static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tsumugi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user_model.json")
    }

    // MARK: 減衰

    /// 新しいほど 1 に近く、60 日で半減する。
    private func recency(_ last: Double, _ t: Double) -> Double {
        max(0.2, pow(0.5, max(0, t - last) / (60 * 86400)))
    }

    private func score(_ r: PhraseRecord, _ t: Double) -> Double { r.count * recency(r.last, t) }

    // MARK: 変換の学習

    /// 候補を自分で選び直した結果を覚える。
    /// - Parameter topCost: その読みの第 1 候補のコスト。選んだ語が必ず上に来るよう基準コストをここまで引き下げる。
    public func learnChoice(reading: String, surface: String, lid: UInt16, rid: UInt16, cost: Int32, topCost: Int32) {
        guard !isPaused, !reading.isEmpty, reading.count <= Self.maxLearnedLength else { return }
        lock.lock(); defer { lock.unlock() }
        let t = now()
        var list = snap.words[reading] ?? []
        if let i = list.firstIndex(where: { $0.surface == surface }) {
            list[i].count += 1
            list[i].last = t
            list[i].cost = min(list[i].cost, topCost)
        } else {
            list.append(LearnedWord(reading: reading, surface: surface, lid: lid, rid: rid,
                                    cost: min(cost, topCost), count: 1, last: t))
        }
        snap.words[reading] = list
        scheduleSave()
    }

    /// 選び間違いだった変換を 1 回分取り消す。1 回しか選んでいなければ忘れる。
    public func unlearnChoice(reading: String, surface: String) {
        lock.lock(); defer { lock.unlock() }
        guard var list = snap.words[reading], let i = list.firstIndex(where: { $0.surface == surface }) else { return }
        list[i].count -= 1
        if list[i].count <= 0 { list.remove(at: i) }
        snap.words[reading] = list.isEmpty ? nil : list
        scheduleSave()
    }

    /// 読みが一致する学習済みの語と、学習ボーナスを引いた実効コスト。
    public func learnedWords(reading: String) -> [(word: LearnedWord, cost: Int32)] {
        lock.lock(); defer { lock.unlock() }
        guard let list = snap.words[reading] else { return [] }
        let t = now()
        return list.map { w in
            let base = min(1500 + 1500 * log2(1 + w.count), 7000) * recency(w.last, t)
            // 同点のときは直近に選んだほうを優先する
            let fresh = 800 * pow(0.5, max(0, t - w.last) / 86400)
            return (w, w.cost - Int32(base + fresh))
        }
    }

    public var hasLearnedWords: Bool {
        lock.lock(); defer { lock.unlock() }
        return !snap.words.isEmpty
    }

    // MARK: 履歴の学習

    /// 確定した内容を記録する。
    /// - Parameter previous: 直前に確定した文字列 (続けて入力された場合のみ)。
    public func recordCommit(reading: String, surface: String, previous: String?) {
        guard !isPaused, reading.count >= 2, reading.count <= Self.maxPhraseReadingLength,
              reading != surface || reading.count >= 4 else { return }
        lock.lock(); defer { lock.unlock() }
        let t = now()
        let key = reading + "\t" + surface
        var r = snap.phrases[key] ?? PhraseRecord(reading: reading, surface: surface, count: 0, last: t)
        r.count += 1
        r.last = t
        snap.phrases[key] = r
        if let previous, !previous.isEmpty {
            let pk = Self.contextKey(previous)
            var m = snap.nexts[pk] ?? [:]
            var n = m[key] ?? PhraseRecord(reading: reading, surface: surface, count: 0, last: t)
            n.count += 1
            n.last = t
            m[key] = n
            snap.nexts[pk] = m
        }
        if snap.phrases.count > Self.maxPhrases * 11 / 10 { prune(t) }
        scheduleSave()
    }

    private static func contextKey(_ s: String) -> String { String(s.suffix(16)) }

    private func prune(_ t: Double) {
        let keep = snap.phrases.sorted { score($0.value, t) > score($1.value, t) }.prefix(Self.maxPhrases)
        snap.phrases = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        snap.nexts = snap.nexts.compactMapValues { m in
            let f = m.filter { snap.phrases[$0.key] != nil }
            return f.isEmpty ? nil : f
        }
    }

    // MARK: 書き癖 (読みの並び)

    /// 確定した読みを書き癖の記録に足す。
    /// - Parameter continues: 直前の確定に続けて打ったものか。
    public func recordReading(_ reading: String, continues: Bool) {
        guard !isPaused, !reading.isEmpty, !reading.contains(Self.streamBreak) else { return }
        lock.lock(); defer { lock.unlock() }
        var log = snap.log ?? []
        if continues, !log.isEmpty {
            log[log.count - 1] += reading
        } else {
            log.append(reading)
            appendHabit(Self.streamBreak)
        }
        snap.log = log
        reading.forEach(appendHabit)
        if habitChars.count > Self.maxHabitKana * 11 / 10 {
            var total = habitChars.count
            while total > Self.maxHabitKana, log.count > 1 { total -= log.removeFirst().count + 1 }
            snap.log = log
            rebuildHabit()
        }
        scheduleSave()
    }

    private func appendHabit(_ c: Character) {
        let i = habitChars.count
        habitChars.append(c)
        let n = Self.minHabitOrder
        guard c != Self.streamBreak, i >= n, !habitChars[(i - n)..<i].contains(Self.streamBreak) else { return }
        habitIndex[String(habitChars[(i - n)..<i]), default: []].append(Int32(i))
    }

    private func rebuildHabit() {
        habitChars = []
        habitIndex = [:]
        for stream in snap.log ?? [] {
            appendHabit(Self.streamBreak)
            stream.forEach(appendHabit)
        }
    }

    /// この読みの並びのあとに、過去の自分が次に打ったかな。
    /// 直前の読みが長く一致する箇所ほど信用し、同じ並びを何度も打っているほど重みを大きくする。
    public func habit(after reading: String) -> Habit? {
        let ctx = Array(reading.suffix(Self.maxHabitOrder))
        let n = Self.minHabitOrder
        guard ctx.count >= n else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let positions = habitIndex[String(ctx.suffix(n))] else { return nil }
        // 各出現箇所について、直前が何文字一致しているかを数える
        var found: [(length: Int, next: Character)] = []
        for p in positions {
            let pos = Int(p)
            var len = n
            while len < ctx.count, pos - 1 - len >= 0, habitChars[pos - 1 - len] == ctx[ctx.count - 1 - len] { len += 1 }
            found.append((len, habitChars[pos]))
        }
        // いちばん長く一致する並びから順に、十分な回数があるものを採る (長い一致なら 1 回でも手がかりにする)
        for length in stride(from: ctx.count, through: n, by: -1) {
            let hits = found.filter { $0.length >= length }
            guard hits.count >= (length >= 6 ? 1 : 2) else { continue }
            var next: [Character: Float] = [:]
            for h in hits { next[h.next, default: 0] += 1 / Float(hits.count) }
            // 重みは控えめにしてある。これより強くすると、癖のない文章で外れた先読みが増えた (Tools/eval)
            let evidence = Float(hits.count) / Float(hits.count + 2)
            let reach: Float = length >= 5 ? 1 : (length == 4 ? 0.7 : 0.5)
            return Habit(next: next, weight: min(0.85, evidence * reach))
        }
        return nil
    }

    /// 打ちかけの読みから、過去に確定した句を補完する。
    public func completePhrase(readingPrefix: String) -> PhraseRecord? {
        let n = readingPrefix.count
        guard n >= 1 else { return nil }
        lock.lock(); defer { lock.unlock() }
        let t = now()
        var best: (PhraseRecord, Double)?
        for r in snap.phrases.values where r.reading.count > n && r.reading.hasPrefix(readingPrefix) {
            // 打った量が少ないうちは、何度も使った句だけを出す
            let needed: Double = n >= 3 ? 1 : (n == 2 ? 2 : 4)
            guard r.count >= needed else { continue }
            let s = score(r, t)
            if best == nil || s > best!.1 { best = (r, s) }
        }
        return best?.0
    }

    /// 直前に確定した文字列の後に、よく続けて入力している句。
    public func nextPhrase(after previous: String) -> PhraseRecord? {
        guard !previous.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let m = snap.nexts[Self.contextKey(previous)] else { return nil }
        let t = now()
        let total = m.values.reduce(0) { $0 + $1.count }
        guard let top = m.values.max(by: { score($0, t) < score($1, t) }) else { return nil }
        // 2 回以上、かつ半分以上の割合で続いているときだけ提案する
        return top.count >= 2 && top.count / total >= 0.5 ? top : nil
    }

    // MARK: 管理

    public struct Stats { public let words: Int; public let phrases: Int }

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(words: snap.words.values.reduce(0) { $0 + $1.count }, phrases: snap.phrases.count)
    }

    public func forgetAll() {
        lock.lock()
        snap = Snapshot()
        rebuildHabit()
        lock.unlock()
        saveNow()
    }

    private func scheduleSave() {
        guard fileURL != nil, !saveScheduled else { return }
        saveScheduled = true
        saveQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.saveNow() }
    }

    public func saveNow() {
        guard let fileURL else { return }
        lock.lock()
        saveScheduled = false
        let data = try? JSONEncoder().encode(snap)
        lock.unlock()
        guard let data else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
