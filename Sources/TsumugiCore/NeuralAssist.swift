import Foundation

/// ローカル LLM による補助。呼び出しはバックグラウンドスレッドから行われる。
public protocol NeuralAssist: AnyObject {
    /// 文脈を踏まえて読みを変換する。失敗や中断時は nil。
    func convert(reading: String, leftContext: String, isCancelled: () -> Bool) -> String?
    /// これから入力されそうな続きを予測する。自信がなければ nil。
    /// - Parameter habit: 利用者の書き癖。あれば LLM の予測と 1 文字ごとに混ぜ合わせる。
    func predict(readingPrefix: String, leftContext: String, habit: HabitHint?, isCancelled: () -> Bool) -> NeuralPrediction?
}

/// ここまでの読み (ひらがな) を受け取り、利用者が次に打ちそうなかなを返す。手がかりがなければ nil。
public typealias HabitHint = (_ readingSoFar: String) -> Habit?

/// 利用者の過去の入力から見た「次の 1 文字」。
public struct Habit: Equatable {
    /// 次に来たかなと、その割合 (合計 1 以下)。
    public var next: [Character: Float]
    /// LLM の予測に対してどれだけ重く見るか (0...1)。同じ並びを何度も打っているほど大きい。
    public var weight: Float

    public init(next: [Character: Float], weight: Float) {
        self.next = next
        self.weight = weight
    }
}

public struct NeuralPrediction: Equatable {
    /// 予測した読み全体 (ひらがな、readingPrefix を含む)。
    public var reading: String
    /// LLM が出した表記 (検証前)。
    public var surface: String?
    /// 読みの続きをどれだけ確信しているか (0...1)。
    public var confidence: Float

    public init(reading: String, surface: String?, confidence: Float) {
        self.reading = reading
        self.surface = surface
        self.confidence = confidence
    }
}
