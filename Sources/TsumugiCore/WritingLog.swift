import Foundation

/// 打った文章の記録。文体の直しを作るための材料で、ふだんは無効 (入力メニューで有効にする)。
/// この Mac の中のファイルに足していくだけで、どこにも送らない。
///
/// 入力メソッドから見えるのは「自分が入れた文字」と「カーソルの手前の文章」だけなので、
/// 書き直しの経過は、出来事の並びとして残す:
/// - commit: 確定して入れた文字列
/// - direct: 英字モードなどで、そのままアプリへ渡した文字 (続けて打ったぶんを 1 件にまとめる)
/// - delete: 確定済みの文章に対して押した削除キーの回数 (続けて押したぶんを 1 件にまとめる)
/// - fix: Tab で反映した直し (直す前と後)
/// - snapshot: 改行を押す直前・入力先を離れるときの、カーソルの手前の文章 (書き直したあとの姿)
///
/// 1 行 1 件の JSON (`{"t": 時刻, "app": アプリ, "k": 種類, "s": 文字列, ...}`) を、月ごとのファイルに足す。
public final class WritingLog {
    public enum Kind: String { case commit, direct, delete, fix, snapshot }

    /// 記録しないアプリ (パスワードを扱うもの)。パスワード欄ではそもそも入力メソッドが呼ばれないが、
    /// 検索欄などに打った内容も残さない。
    public static let defaultExcludedApps: Set<String> = [
        "com.apple.keychainaccess", "com.apple.Passwords",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
    ]

    public var isEnabled: Bool {
        didSet { if !isEnabled { flush() } }
    }
    public var excludedApps: Set<String>

    private let directory: URL?
    private let now: () -> Date
    private let lock = NSLock()
    /// まとめている途中の direct / delete。
    private var pending: (kind: Kind, app: String, text: String, count: Int, at: Date)?
    /// 前の snapshot のあとに何か入れたか・消したか (アプリごと)。変わっていなければ snapshot を残さない。
    private var dirty: Set<String> = []
    private var lastSnapshot: [String: String] = [:]

    /// - Parameter directory: 記録を置く場所。nil なら何も書かない (検証用)。
    public init(directory: URL?, isEnabled: Bool = false, excludedApps: Set<String> = WritingLog.defaultExcludedApps,
                now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.isEnabled = isEnabled
        self.excludedApps = excludedApps
        self.now = now
    }

    public static func defaultDirectory() -> URL {
        UserModel.defaultURL().deletingLastPathComponent().appendingPathComponent("writing", isDirectory: true)
    }

    /// 確定して入れた文字列。
    public func commit(_ text: String, app: String?) { record(.commit, app: app, text: text) }

    /// そのままアプリへ渡した文字。
    public func direct(_ text: String, app: String?) { record(.direct, app: app, text: text) }

    /// 確定済みの文章に対する削除キー 1 回。
    public func delete(app: String?) { record(.delete, app: app, count: 1) }

    /// 反映した直し。
    public func fix(from: String, to: String, app: String?) { record(.fix, app: app, text: from, to: to) }

    /// カーソルの手前の文章。前の snapshot から何も打っていなければ残さない。
    public func snapshot(_ text: String, app: String?) { record(.snapshot, app: app, text: text) }

    /// まとめている途中のぶんを書き出す。
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        flushPending()
    }

    /// 記録をすべて消す。
    public func eraseAll() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
        dirty = []
        lastSnapshot = [:]
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// 記録の件数と大きさ (メニューの表示用)。
    public var size: Int {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func record(_ kind: Kind, app: String?, text: String = "", count: Int = 0, to: String? = nil) {
        guard isEnabled else { return }
        let app = app ?? "?"
        guard !excludedApps.contains(app) else { return }
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .direct, .delete:
            if let p = pending, p.kind == kind, p.app == app {
                pending = (kind, app, p.text + text, p.count + count, p.at)
            } else {
                flushPending()
                pending = (kind, app, text, count, now())
            }
            dirty.insert(app)
        case .commit, .fix:
            guard !text.isEmpty else { return }
            flushPending()
            var event: [String: Any] = ["s": text]
            if let to { event["to"] = to }
            write(kind, app: app, at: now(), event)
            dirty.insert(app)
        case .snapshot:
            flushPending()
            guard dirty.contains(app), !text.isEmpty, lastSnapshot[app] != text else { return }
            dirty.remove(app)
            lastSnapshot[app] = text
            write(kind, app: app, at: now(), ["s": text])
        }
    }

    private func flushPending() {
        guard let p = pending else { return }
        pending = nil
        write(p.kind, app: p.app, at: p.at, p.kind == .delete ? ["n": p.count] : ["s": p.text])
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func write(_ kind: Kind, app: String, at: Date, _ fields: [String: Any]) {
        guard let directory else { return }
        var event = fields
        event["t"] = Self.stamp.string(from: at)
        event["app"] = app
        event["k"] = kind.rawValue
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let month = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: at)
        let url = directory.appendingPathComponent(String(format: "%04d-%02d.jsonl", month.year ?? 0, month.month ?? 0))
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            // 本人だけが読み書きできるファイルとして作る
            fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
