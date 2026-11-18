// ByteReader: bounds-checked big-endian reads over untrusted bytes, shared
// by every parser that reads network or file data (DNS, TLS, X.509, PNG,
// TrueType, ...). Every read returns nil past the end instead of trapping;
// once a read fails the reader stays failed (`ok` is false), so a parser
// can do a run of reads and check once.

struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int
    let end: Int
    private(set) var ok = true

    init(_ bytes: [UInt8], from start: Int = 0, count: Int? = nil) {
        self.bytes = bytes
        let s = min(max(start, 0), bytes.count)
        offset = s
        end = count.map { min(s + max($0, 0), bytes.count) } ?? bytes.count
        if let c = count, c < 0 || s + c > bytes.count { ok = false }
    }

    var remaining: Int { end - offset }
    var atEnd: Bool { offset >= end }

    private mutating func take(_ n: Int) -> Int? {
        guard ok, n >= 0, n <= end - offset else { ok = false; return nil }
        let at = offset
        offset += n
        return at
    }

    mutating func u8() -> UInt8? {
        guard let at = take(1) else { return nil }
        return bytes[at]
    }

    mutating func u16() -> UInt16? {
        guard let at = take(2) else { return nil }
        return UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    mutating func u24() -> UInt32? {
        guard let at = take(3) else { return nil }
        return UInt32(bytes[at]) << 16 | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2])
    }

    mutating func u32() -> UInt32? {
        guard let at = take(4) else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(bytes[at + i]) }
        return v
    }

    mutating func u64() -> UInt64? {
        guard let at = take(8) else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(bytes[at + i]) }
        return v
    }

    mutating func u16le() -> UInt16? {
        guard let at = take(2) else { return nil }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    mutating func u32le() -> UInt32? {
        guard let at = take(4) else { return nil }
        var v: UInt32 = 0
        for i in (0..<4).reversed() { v = v << 8 | UInt32(bytes[at + i]) }
        return v
    }

    /// The next n bytes, copied.
    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard let at = take(n) else { return nil }
        return Array(bytes[at..<(at + n)])
    }

    /// A reader over the next n bytes (for length-prefixed structures).
    mutating func sub(_ n: Int) -> ByteReader? {
        guard let at = take(n) else { return nil }
        return ByteReader(bytes, from: at, count: n)
    }

    mutating func skip(_ n: Int) -> Bool { take(n) != nil }

    /// Jump to an absolute offset inside [0, end] (for formats with offsets,
    /// like TrueType tables or DNS name compression).
    mutating func seek(_ to: Int) -> Bool {
        guard ok, to >= 0, to <= end else { ok = false; return false }
        offset = to
        return true
    }
}

/// FNV-1a, 64-bit: a cheap checksum for tests and transfers.
func fnv1a64<C: Collection>(_ data: C, _ seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 where C.Element == UInt8 {
    var h = seed
    for b in data { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return h
}
