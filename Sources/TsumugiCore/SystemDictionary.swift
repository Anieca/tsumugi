import Foundation

/// Tools/build_dict.py が出力したバイナリ辞書を mmap して引く。読み取り専用でスレッドセーフ。
public final class SystemDictionary {
    public struct Entry {
        public let lid: UInt16
        public let rid: UInt16
        public let cost: Int16
        let surfaceOffset: UInt32
        let surfaceLength: UInt16
    }

    private let data: NSData
    private let base: UnsafeRawPointer
    public let readingCount: Int
    public let entryCount: Int
    public let connDim: Int
    public let unknownId: UInt16

    private let readingOffsets: UnsafeRawPointer
    private let entryStart: UnsafeRawPointer
    private let entries: UnsafeRawPointer
    private let posFlags: UnsafeRawPointer
    private let conn: UnsafeRawPointer
    private let readingBlob: UnsafePointer<UInt8>
    private let surfaceBlob: UnsafePointer<UInt8>

    public enum LoadError: Error { case invalidFormat }

    public init(url: URL) throws {
        let data = try NSData(contentsOf: url, options: .alwaysMapped)
        let base = data.bytes
        self.data = data
        self.base = base
        func u32(_ i: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
        guard data.length > 64, u32(0) == 0x474D_5354, u32(1) == 1 else { throw LoadError.invalidFormat }
        readingCount = u32(2)
        entryCount = u32(3)
        let readingBlobSize = u32(4)
        connDim = u32(6)
        unknownId = UInt16(u32(7))
        func pad4(_ n: Int) -> Int { (n + 3) & ~3 }
        var off = 64
        readingOffsets = base + off; off += (readingCount + 1) * 4
        entryStart = base + off; off += (readingCount + 1) * 4
        entries = base + off; off += entryCount * 12
        posFlags = base + off; off += pad4(connDim)
        conn = base + off; off += pad4(connDim * connDim * 2)
        readingBlob = (base + off).assumingMemoryBound(to: UInt8.self); off += readingBlobSize
        surfaceBlob = (base + off).assumingMemoryBound(to: UInt8.self)
    }

    // MARK: 接続コスト・品詞

    @inline(__always)
    public func connection(rid: UInt16, lid: UInt16) -> Int32 {
        Int32(conn.loadUnaligned(fromByteOffset: (Int(rid) * connDim + Int(lid)) * 2, as: Int16.self))
    }

    /// 付属語 (助詞・助動詞・接尾・非自立・記号) かどうか。文節の区切りに使う。
    public func isFunctional(_ lid: UInt16) -> Bool {
        posFlags.load(fromByteOffset: Int(lid), as: UInt8.self) & 1 != 0
    }

    public func isPrefix(_ lid: UInt16) -> Bool {
        posFlags.load(fromByteOffset: Int(lid), as: UInt8.self) & 2 != 0
    }

    // MARK: エントリ

    @inline(__always)
    private func readingRange(_ i: Int) -> (start: Int, end: Int) {
        (Int(readingOffsets.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)),
         Int(readingOffsets.loadUnaligned(fromByteOffset: (i + 1) * 4, as: UInt32.self)))
    }

    public func entryRange(forReadingIndex i: Int) -> Range<Int> {
        let lo = Int(entryStart.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
        let hi = Int(entryStart.loadUnaligned(fromByteOffset: (i + 1) * 4, as: UInt32.self))
        return lo..<hi
    }

    @inline(__always)
    public func entry(_ i: Int) -> Entry {
        let p = entries + i * 12
        return Entry(
            lid: p.loadUnaligned(as: UInt16.self),
            rid: p.loadUnaligned(fromByteOffset: 2, as: UInt16.self),
            cost: p.loadUnaligned(fromByteOffset: 4, as: Int16.self),
            surfaceOffset: p.loadUnaligned(fromByteOffset: 8, as: UInt32.self),
            surfaceLength: p.loadUnaligned(fromByteOffset: 6, as: UInt16.self)
        )
    }

    public func surface(of e: Entry) -> String {
        String(decoding: UnsafeBufferPointer(start: surfaceBlob + Int(e.surfaceOffset), count: Int(e.surfaceLength)), as: UTF8.self)
    }

    public func reading(at i: Int) -> String {
        let r = readingRange(i)
        return String(decoding: UnsafeBufferPointer(start: readingBlob + r.start, count: r.end - r.start), as: UTF8.self)
    }

    // MARK: 検索

    /// 読み i の先頭 len バイトと key を比較する (読みが短ければその長さまで)。
    @inline(__always)
    private func compare(_ i: Int, _ key: UnsafePointer<UInt8>, _ len: Int) -> Int {
        let r = readingRange(i)
        let n = min(r.end - r.start, len)
        let c = Int(memcmp(readingBlob + r.start, key, n))
        if c != 0 { return c }
        return (r.end - r.start) < len ? -1 : 0
    }

    /// [lo, hi) のうち key を接頭辞に持つ読みの範囲に絞る。
    private func narrow(_ lo: Int, _ hi: Int, _ key: UnsafePointer<UInt8>, _ len: Int) -> (Int, Int) {
        var a = lo, b = hi
        while a < b {
            let m = (a + b) / 2
            if compare(m, key, len) < 0 { a = m + 1 } else { b = m }
        }
        let first = a
        b = hi
        while a < b {
            let m = (a + b) / 2
            if compare(m, key, len) <= 0 { a = m + 1 } else { b = m }
        }
        return (first, a)
    }

    /// 共通接頭辞検索。utf8[start...] の接頭辞のうち辞書にある読みごとに body を呼ぶ。
    /// - Parameter ends: 文字境界になるバイト位置 (start より大きいもの、昇順)。
    public func commonPrefixSearch(
        _ utf8: UnsafeBufferPointer<UInt8>, start: Int, ends: ArraySlice<Int>,
        body: (_ endIndex: Int, _ entries: Range<Int>) -> Void
    ) {
        var lo = 0, hi = readingCount
        let key = utf8.baseAddress! + start
        for (k, end) in zip(ends.indices, ends) {
            let len = end - start
            (lo, hi) = narrow(lo, hi, key, len)
            if lo >= hi { return }
            let r = readingRange(lo)
            if r.end - r.start == len { body(k, entryRange(forReadingIndex: lo)) }
        }
    }

    /// 読みが完全一致するエントリ。
    public func lookup(_ reading: String) -> Range<Int> {
        var s = reading
        return s.withUTF8 { buf in
            guard buf.count > 0 else { return 0..<0 }
            let (lo, hi) = narrow(0, readingCount, buf.baseAddress!, buf.count)
            guard lo < hi else { return 0..<0 }
            let r = readingRange(lo)
            return r.end - r.start == buf.count ? entryRange(forReadingIndex: lo) : 0..<0
        }
    }

    /// prefix で始まる読みのインデックス範囲 (予測用)。
    public func readings(withPrefix prefix: String) -> Range<Int> {
        var s = prefix
        return s.withUTF8 { buf in
            guard buf.count > 0 else { return 0..<0 }
            let (lo, hi) = narrow(0, readingCount, buf.baseAddress!, buf.count)
            return lo..<hi
        }
    }
}
