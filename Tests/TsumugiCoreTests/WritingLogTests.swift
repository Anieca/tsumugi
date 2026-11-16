import XCTest
@testable import TsumugiCore

final class WritingLogTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tsumugi-writing-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func events() -> [[String: Any]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.path < $1.path }.flatMap { url -> [[String: Any]] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
    }

    func testDisabledWritesNothing() {
        let log = WritingLog(directory: dir)
        log.commit("こんにちは", app: "a")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCoalescesDirectAndDelete() {
        let log = WritingLog(directory: dir, isEnabled: true)
        log.commit("会議をを開く", app: "a")
        log.delete(app: "a"); log.delete(app: "a"); log.delete(app: "a")
        for c in "ok" { log.direct(String(c), app: "a") }
        log.fix(from: "をを", to: "を", app: "a")
        let e = events()
        XCTAssertEqual(e.map { $0["k"] as? String }, ["commit", "delete", "direct", "fix"])
        XCTAssertEqual(e[1]["n"] as? Int, 3)
        XCTAssertEqual(e[2]["s"] as? String, "ok")
        XCTAssertEqual(e[3]["to"] as? String, "を")
    }

    func testSnapshotOnlyAfterChange() {
        let log = WritingLog(directory: dir, isEnabled: true)
        log.snapshot("何も打っていない", app: "a")
        log.commit("あ", app: "a")
        log.snapshot("あ", app: "a")
        log.snapshot("あ", app: "a")
        XCTAssertEqual(events().map { $0["k"] as? String }, ["commit", "snapshot"])
    }

    func testExcludedAppsAndPermissions() throws {
        let log = WritingLog(directory: dir, isEnabled: true)
        log.commit("ひみつ", app: "com.1password.1password")
        XCTAssertTrue(events().isEmpty)
        log.commit("あ", app: "a")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
        log.eraseAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
