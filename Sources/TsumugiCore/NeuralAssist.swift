import Foundation

/// ローカル LLM による補助。呼び出しはバックグラウンドスレッドから行われる。
public protocol NeuralAssist: AnyObject {
    /// 文脈を踏まえて読みを変換する。失敗や中断時は nil。
    func convert(reading: String, leftContext: String, isCancelled: () -> Bool) -> String?
    /// これから入力されそうな続きを予測する。自信がなければ nil。
    func predict(readingPrefix: String, leftContext: String, isCancelled: () -> Bool) -> NeuralPrediction?
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
