import Foundation

/// 文節。変換結果の最小の編集単位。
public struct Segment: Equatable {
    public var reading: String
    public var surface: String
    public var lid: UInt16
    public var rid: UInt16
    /// 文節内部のコスト (語のコスト + 文節内の接続コスト)。
    public var cost: Int32
    /// ユーザーの学習結果に由来するか。
    public var learned: Bool

    public init(reading: String, surface: String, lid: UInt16, rid: UInt16, cost: Int32, learned: Bool = false) {
        self.reading = reading
        self.surface = surface
        self.lid = lid
        self.rid = rid
        self.cost = cost
        self.learned = learned
    }
}

public struct Conversion: Equatable {
    public var segments: [Segment]
    public var cost: Int32
    public var text: String { segments.map(\.surface).joined() }
    public var reading: String { segments.map(\.reading).joined() }
}

/// ラティスを組んで Viterbi で最小コスト経路を求める、かな漢字変換の本体。
public final class Converter {
    public let dictionary: SystemDictionary
    public let userModel: UserModel?

    private static let maxWordLength = 24
    private static let maxEntriesPerReading = 120

    public init(dictionary: SystemDictionary, userModel: UserModel? = nil) {
        self.dictionary = dictionary
        self.userModel = userModel
    }

    // MARK: ラティス

    enum Kind {
        case dict(SystemDictionary.Entry)
        case text(String)
        case learned(String)
    }

    struct Node {
        let start: Int
        let end: Int
        let lid: UInt16
        let rid: UInt16
        let wcost: Int32
        let kind: Kind
        var best: Int32 = .max
        var prev: Int = -1
    }

    struct Lattice {
        var chars: [Character]
        var nodes: [Node] = []
        var starts: [[Int]]
        var ends: [[Int]]
        var total: Int32 = .max
        var last: Int = -1
    }

    private func surface(_ node: Node) -> String {
        switch node.kind {
        case .dict(let e): return dictionary.surface(of: e)
        case .text(let s), .learned(let s): return s
        }
    }

    private func buildLattice(_ reading: String) -> Lattice {
        let chars = Array(reading)
        let n = chars.count
        var lat = Lattice(chars: chars, starts: Array(repeating: [], count: n + 1), ends: Array(repeating: [], count: n + 1))
        var bounds = [0]
        bounds.reserveCapacity(n + 1)
        for c in chars { bounds.append(bounds.last! + c.utf8.count) }
        let unk = dictionary.unknownId

        func add(_ node: Node) {
            lat.starts[node.start].append(lat.nodes.count)
            lat.ends[node.end].append(lat.nodes.count)
            lat.nodes.append(node)
        }

        var s = reading
        s.withUTF8 { buf in
            for i in 0..<n {
                let last = min(n, i + Self.maxWordLength)
                dictionary.commonPrefixSearch(buf, start: bounds[i], ends: bounds[(i + 1)...last]) { k, range in
                    for e in range.prefix(Self.maxEntriesPerReading) {
                        let entry = dictionary.entry(e)
                        add(Node(start: i, end: k, lid: entry.lid, rid: entry.rid, wcost: Int32(entry.cost), kind: .dict(entry)))
                    }
                }
            }
        }

        // 辞書にない並びでも必ず経路ができるようにする
        var i = 0
        while i < n {
            if chars[i].isKana {
                add(Node(start: i, end: i + 1, lid: unk, rid: unk, wcost: 12000, kind: .text(String(chars[i]))))
                // 未知のカタカナ語
                var j = i + 1
                while j < n, chars[j].isKana, j - i < 12 {
                    j += 1
                    let kata = String(chars[i..<j]).katakana
                    add(Node(start: i, end: j, lid: unk, rid: unk, wcost: Int32(10000 + 1500 * (j - i)), kind: .text(kata)))
                }
                i += 1
            } else {
                var j = i
                while j < n, !chars[j].isKana { j += 1 }
                // 英数字・記号の並びはそのまま 1 語として通す
                for k in i..<j {
                    add(Node(start: k, end: j, lid: unk, rid: unk, wcost: k == i ? 2500 : 5000, kind: .text(String(chars[k..<j]))))
                    if j - k > 1 {
                        add(Node(start: k, end: k + 1, lid: unk, rid: unk, wcost: 6000, kind: .text(String(chars[k]))))
                    }
                }
                i = j
            }
        }

        if let userModel, userModel.hasLearnedWords {
            for i in 0..<n {
                for len in 1...min(UserModel.maxLearnedLength, n - i) {
                    for (w, cost) in userModel.learnedWords(reading: String(chars[i..<(i + len)])) {
                        add(Node(start: i, end: i + len, lid: w.lid, rid: w.rid, wcost: cost, kind: .learned(w.surface)))
                    }
                }
            }
        }
        return lat
    }

    private func viterbi(_ lat: inout Lattice, leftRid: UInt16) {
        let n = lat.chars.count
        for pos in 0..<n {
            // 左側のノードを右文脈 ID ごとに最良 1 つへまとめてから接続を試す
            var left: [(rid: UInt16, cost: Int32, node: Int)] = []
            if pos == 0 {
                left = [(leftRid, 0, -1)]
            } else {
                var byRid: [UInt16: (Int32, Int)] = [:]
                for p in lat.ends[pos] {
                    let node = lat.nodes[p]
                    guard node.best != .max else { continue }
                    if let cur = byRid[node.rid], cur.0 <= node.best { continue }
                    byRid[node.rid] = (node.best, p)
                }
                left = byRid.map { ($0.key, $0.value.0, $0.value.1) }
            }
            guard !left.isEmpty else { continue }
            for q in lat.starts[pos] {
                let lid = lat.nodes[q].lid
                var best = Int32.max, prev = -1
                for l in left {
                    let c = l.cost + dictionary.connection(rid: l.rid, lid: lid)
                    if c < best { best = c; prev = l.node }
                }
                lat.nodes[q].best = best + lat.nodes[q].wcost
                lat.nodes[q].prev = prev
            }
        }
        var best = Int32.max, last = -1
        for p in lat.ends[n] where lat.nodes[p].best != .max {
            let c = lat.nodes[p].best + dictionary.connection(rid: lat.nodes[p].rid, lid: 0)
            if c < best { best = c; last = p }
        }
        lat.total = best
        lat.last = last
    }

    /// ノード列を文節にまとめる。自立語の前で区切り、付属語は前の文節に付ける。
    private func segments(_ path: [Node], chars: [Character]) -> [Segment] {
        var out: [Segment] = []
        var prevRid: UInt16 = 0
        var prevWasPrefix = false
        var prevWasText = false
        for node in path {
            let surf = surface(node)
            let reading = String(chars[node.start..<node.end])
            var learned = false
            if case .learned = node.kind { learned = true }
            var isText = false
            if case .text = node.kind { isText = true }
            let single = node.end - node.start == 1
            // 1 文字ずつのかなに砕けた未知語は同じ文節にまとめる
            let glue = isText && prevWasText && single
            let attach = !out.isEmpty && (dictionary.isFunctional(node.lid) && !isText || prevWasPrefix || glue)
            if attach {
                out[out.count - 1].reading += reading
                out[out.count - 1].surface += surf
                out[out.count - 1].cost += dictionary.connection(rid: prevRid, lid: node.lid) + node.wcost
                out[out.count - 1].rid = node.rid
                out[out.count - 1].learned = out[out.count - 1].learned || learned
            } else {
                out.append(Segment(reading: reading, surface: surf, lid: node.lid, rid: node.rid, cost: node.wcost, learned: learned))
            }
            prevRid = node.rid
            prevWasPrefix = dictionary.isPrefix(node.lid)
            prevWasText = isText && single
        }
        return out
    }

    private func conversion(_ lat: Lattice, path: [Node], cost: Int32) -> Conversion {
        Conversion(segments: segments(path, chars: lat.chars), cost: cost)
    }

    // MARK: 変換

    /// 読み全体を変換し、コストの低い順に最大 nbest 件返す。
    public func convert(_ reading: String, nbest: Int = 1, leftRid: UInt16 = 0) -> [Conversion] {
        guard !reading.isEmpty else { return [] }
        var lat = buildLattice(reading)
        viterbi(&lat, leftRid: leftRid)
        guard lat.last >= 0 else { return [] }
        if nbest <= 1 {
            var path: [Node] = []
            var p = lat.last
            while p >= 0 { path.append(lat.nodes[p]); p = lat.nodes[p].prev }
            return [conversion(lat, path: path.reversed(), cost: lat.total)]
        }
        return nBest(lat, count: nbest, leftRid: leftRid)
    }

    private struct Partial {
        let f: Int32      // 完成時の総コストの見積もり (前向きコストにより厳密)
        let g: Int32      // このノードより右側のコスト
        let node: Int
        let next: Int     // arena 内の次 (右側) の要素。-1 なら文末
    }

    /// 後ろ向き A* で上位 N 件を列挙する。
    private func nBest(_ lat: Lattice, count: Int, leftRid: UInt16) -> [Conversion] {
        var arena: [Partial] = []
        var heap = Heap()
        let n = lat.chars.count
        for p in lat.ends[n] where lat.nodes[p].best != .max {
            let g = dictionary.connection(rid: lat.nodes[p].rid, lid: 0)
            arena.append(Partial(f: lat.nodes[p].best + g, g: g, node: p, next: -1))
            heap.push(lat.nodes[p].best + g, arena.count - 1)
        }
        var results: [Conversion] = []
        var seen = Set<String>()
        var pops = 0
        while let idx = heap.pop(), results.count < count, pops < 4000 {
            pops += 1
            let cur = arena[idx]
            let node = lat.nodes[cur.node]
            if node.start == 0 {
                var path: [Node] = []
                var i = idx
                while i >= 0 { path.append(lat.nodes[arena[i].node]); i = arena[i].next }
                let conv = conversion(lat, path: path, cost: cur.f)
                if seen.insert(conv.text).inserted { results.append(conv) }
                continue
            }
            let g = cur.g + node.wcost
            for p in lat.ends[node.start] where lat.nodes[p].best != .max {
                let g2 = g + dictionary.connection(rid: lat.nodes[p].rid, lid: node.lid)
                arena.append(Partial(f: lat.nodes[p].best + g2, g: g2, node: p, next: idx))
                heap.push(lat.nodes[p].best + g2, arena.count - 1)
            }
        }
        return results
    }

    /// 読みが surface と読めるか確かめ、読めるなら最小コストの分け方を返す (LLM の出力の検証用)。
    public func match(reading: String, surface target: String) -> Conversion? {
        guard !reading.isEmpty, !target.isEmpty else { return nil }
        let lat = buildLattice(reading)
        let t = Array(target)
        let n = lat.chars.count
        struct State { var cost: Int32; var node: Int; var from: Int }  // from: states 内のインデックス
        var states: [State] = []
        var table: [[Int: Int]] = Array(repeating: [:], count: n + 1)  // pos -> [tpos: state index]
        states.append(State(cost: 0, node: -1, from: -1))
        table[0][0] = 0
        var surfCache: [Int: [Character]] = [:]
        var extra: [Node] = []   // 辞書外の英字ノード。states からは -2 - index で参照する
        let unk = dictionary.unknownId
        func node(_ i: Int) -> Node { i >= 0 ? lat.nodes[i] : extra[-2 - i] }
        for pos in 0..<n {
            for (tpos, si) in table[pos] {
                let st = states[si]
                let prevRid: UInt16 = st.node == -1 ? 0 : node(st.node).rid
                // 辞書にない英字表記 (例: ちゃっとじーぴーてぃー → ChatGPT) は、かなの並びと対応づけて通す
                if tpos < t.count, t[tpos].isASCII, t[tpos].isLetter {
                    var te = tpos
                    while te < t.count, t[te].isASCII, t[te].isLetter || t[te].isNumber { te += 1 }
                    var pe = pos
                    while pe < n, lat.chars[pe].isKana, pe - pos < 14 {
                        pe += 1
                        guard pe - pos >= 2 else { continue }
                        let word = String(t[tpos..<te])
                        let cost = st.cost + dictionary.connection(rid: prevRid, lid: unk) + 9000
                        let q = extra.count
                        extra.append(Node(start: pos, end: pe, lid: unk, rid: unk, wcost: 9000, kind: .text(word)))
                        if let ex = table[pe][te] {
                            if states[ex].cost > cost { states[ex] = State(cost: cost, node: -2 - q, from: si) }
                        } else {
                            states.append(State(cost: cost, node: -2 - q, from: si))
                            table[pe][te] = states.count - 1
                        }
                    }
                }
                for q in lat.starts[pos] {
                    let node = lat.nodes[q]
                    let sc: [Character]
                    if let c = surfCache[q] { sc = c } else { sc = Array(surface(node)); surfCache[q] = sc }
                    guard tpos + sc.count <= t.count, t[tpos..<(tpos + sc.count)].elementsEqual(sc) else { continue }
                    let cost = st.cost + dictionary.connection(rid: prevRid, lid: node.lid) + node.wcost
                    let key = tpos + sc.count
                    if let ex = table[node.end][key] {
                        if states[ex].cost > cost { states[ex] = State(cost: cost, node: q, from: si) }
                    } else {
                        states.append(State(cost: cost, node: q, from: si))
                        table[node.end][key] = states.count - 1
                    }
                }
            }
        }
        guard let end = table[n][t.count] else { return nil }
        var path: [Node] = []
        var i = end
        while i > 0 { path.append(node(states[i].node)); i = states[i].from }
        let last = node(states[end].node)
        return conversion(lat, path: path.reversed(), cost: states[end].cost + dictionary.connection(rid: last.rid, lid: 0))
    }

    /// 1 つの文節として読みを変換したときの候補一覧。
    public func segmentCandidates(_ reading: String, limit: Int = 60) -> [Segment] {
        var out: [Segment] = []
        var seen = Set<String>()
        func push(_ s: Segment) {
            if out.count < limit, seen.insert(s.surface).inserted { out.append(s) }
        }
        func merged(_ c: Conversion) -> Segment {
            Segment(reading: reading, surface: c.text, lid: c.segments.first!.lid, rid: c.segments.last!.rid,
                    cost: c.cost, learned: c.segments.contains(where: \.learned))
        }
        let nbest = convert(reading, nbest: 10)
        if let first = nbest.first { push(merged(first)) }
        // 学習済み・辞書の単語をコスト順に
        var words: [Segment] = []
        if let userModel {
            for (w, cost) in userModel.learnedWords(reading: reading) {
                words.append(Segment(reading: reading, surface: w.surface, lid: w.lid, rid: w.rid, cost: cost, learned: true))
            }
        }
        for e in dictionary.lookup(reading) {
            let entry = dictionary.entry(e)
            words.append(Segment(reading: reading, surface: dictionary.surface(of: entry), lid: entry.lid, rid: entry.rid, cost: Int32(entry.cost)))
        }
        words.sort { $0.cost < $1.cost }
        // 単語として引けるものを先に、複合的な変換を後に
        var rest = nbest.dropFirst().map(merged)
        let head = rest.prefix(3)
        rest = Array(rest.dropFirst(3))
        head.forEach(push)
        words.forEach(push)
        rest.forEach(push)
        let unk = dictionary.unknownId
        push(Segment(reading: reading, surface: reading, lid: unk, rid: unk, cost: 8000))
        push(Segment(reading: reading, surface: reading.katakana, lid: unk, rid: unk, cost: 8000))
        return out
    }
}

/// (コスト, 値) の最小ヒープ。
struct Heap {
    private var items: [(Int32, Int)] = []

    mutating func push(_ cost: Int32, _ value: Int) {
        items.append((cost, value))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if items[p].0 <= items[i].0 { break }
            items.swapAt(p, i)
            i = p
        }
    }

    mutating func pop() -> Int? {
        guard !items.isEmpty else { return nil }
        let top = items[0].1
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, items[l].0 < items[m].0 { m = l }
                if r < items.count, items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(m, i)
                i = m
            }
        }
        return top
    }
}
