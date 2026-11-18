// Part 7 (Phase 7A): packet buffers and the small value types the network
// stack shares (addresses, checksums, a seeded RNG).
//
// A `Packet` is a fixed-size byte buffer with headroom: a sender appends its
// payload after `headroom` bytes, then each layer pushes its header in front
// (UDP, IPv4, Ethernet) without copying. A received frame starts at offset 0.
// `start`..<`end` is the live region; every accessor is bounds-checked and
// returns nil / false rather than trapping, because the bytes may be hostile.
//
// Buffers are pooled on a capped free list (`Packet.make` / `release`). With
// ARC a forgotten `release()` only costs a reallocation, but releasing a
// packet someone still uses is a bug: whoever receives a Packet in a callback
// owns it only for the duration of the call (copy `bytes()` to keep it).

/// IPv4 address in host order: 10.0.2.15 is 0x0A00020F.
typealias IPv4Addr = UInt32
/// 48-bit Ethernet address in the low bits of a UInt64.
typealias MACAddr = UInt64

let macBroadcast: MACAddr = 0xFFFF_FFFF_FFFF

func ipv4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> IPv4Addr { a << 24 | b << 16 | c << 8 | d }

func ipString(_ a: IPv4Addr) -> String {
    "\(a >> 24).\((a >> 16) & 255).\((a >> 8) & 255).\(a & 255)"
}

/// "a.b.c.d" (four decimal numbers 0-255), else nil.
func parseIPv4(_ s: Substring) -> IPv4Addr? {
    var value: UInt32 = 0
    var parts = 0
    for part in s.split(separator: ".", omittingEmptySubsequences: false) {
        guard parts < 4, !part.isEmpty, part.count <= 3,
              part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = parseInt(part), n <= 255
        else { return nil }
        value = value << 8 | UInt32(n)
        parts += 1
    }
    return parts == 4 ? value : nil
}

func macString(_ m: MACAddr) -> String {
    var s = ""
    for i in 0..<6 {
        if i > 0 { s += ":" }
        s += hexDigits((m >> UInt64(8 * (5 - i))) & 0xFF, 2)
    }
    return s
}

func isMulticastIP(_ a: IPv4Addr) -> Bool { a >> 28 == 0xE }

// MARK: Random numbers

/// xorshift64*: a seeded generator for LinkPair and the tests, and (seeded
/// from the TSC) for DHCP transaction ids, DNS ids and ephemeral ports.
/// Not cryptographic: TCP initial sequence numbers (7D) should mix in RDRAND.
struct NetRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
    /// 0 ..< n (n > 0).
    mutating func below(_ n: Int) -> Int { Int(next() >> 33) % max(n, 1) }
}

/// The stack's own generator, seeded from the TSC on first use.
var netRNG = NetRNG(seed: 0)
var netRNGSeeded = false
func netRandom() -> UInt64 {
    if !netRNGSeeded { netRNGSeeded = true; netRNG = NetRNG(seed: rdtsc() ^ 0xA5A5_5A5A_1234_5678) }
    return netRNG.next()
}

// MARK: Checksum

/// Add `count` bytes of `buf` from `from` to a running 16-bit one's-complement
/// sum (big-endian words; an odd last byte is padded with zero). Out-of-range
/// requests add nothing.
func csumAdd(_ sum: UInt32, _ buf: [UInt8], _ from: Int, _ count: Int) -> UInt32 {
    guard from >= 0, count > 0, from <= buf.count, count <= buf.count - from else { return sum }
    // Unchecked reads (the range was checked above) into a 64-bit
    // accumulator, folded back to 32 bits: 2^32 = 1 mod 0xFFFF, so the
    // one's-complement sum is unchanged. TCP checksums every segment twice.
    return buf.withUnsafeBufferPointer { b -> UInt32 in
        var s = UInt64(sum)
        var i = from
        let end = from + count
        while i + 1 < end {
            s &+= UInt64(b[i]) << 8 | UInt64(b[i + 1])
            i += 2
        }
        if i < end { s &+= UInt64(b[i]) << 8 }
        while s >> 32 != 0 { s = (s & 0xFFFF_FFFF) &+ (s >> 32) }
        return UInt32(truncatingIfNeeded: s)
    }
}

func csumFold(_ sum: UInt32) -> UInt16 {
    var s = sum
    while s >> 16 != 0 { s = (s & 0xFFFF) &+ (s >> 16) }
    return ~UInt16(truncatingIfNeeded: s)
}

/// The Internet checksum of a byte range; 0 over data that includes a valid checksum.
func inetChecksum(_ buf: [UInt8], _ from: Int, _ count: Int) -> UInt16 {
    csumFold(csumAdd(0, buf, from, count))
}

/// Sum of the TCP/UDP pseudo header (RFC 768 / 9293) for a segment of `length` bytes.
func pseudoHeaderSum(src: IPv4Addr, dst: IPv4Addr, proto: UInt8, length: Int) -> UInt32 {
    (src >> 16) &+ (src & 0xFFFF) &+ (dst >> 16) &+ (dst & 0xFFFF) &+ UInt32(proto) &+ UInt32(truncatingIfNeeded: length)
}

// MARK: Packet

final class Packet {
    /// Capacity of a pooled buffer: a full Ethernet frame plus headroom.
    static let size = 2048
    /// Room reserved in front of a new packet's payload (Ethernet 14 + IPv4
    /// up to 60 + a transport header with options).
    static let headroom = 128
    /// Most buffers kept on the free list.
    static let poolCap = 512

    var buf: [UInt8]
    var start: Int
    var end: Int
    /// On the free list (guards a double release).
    var pooled = false

    init(buffer: [UInt8], start: Int, end: Int) {
        buf = buffer
        self.start = start
        self.end = end
    }

    /// An empty packet with `headroom` bytes in front, from the free list if
    /// possible.
    static func make() -> Packet {
        if let p = packetPool.popLast() {
            p.pooled = false
            p.start = headroom
            p.end = headroom
            packetStats.reused += 1
            return p
        }
        packetStats.fresh += 1
        return Packet(buffer: [UInt8](repeating: 0, count: size), start: headroom, end: headroom)
    }

    /// A packet holding a copy of `bytes` at offset 0 (a received frame),
    /// or nil if it doesn't fit a pooled buffer.
    static func received(_ bytes: [UInt8]) -> Packet? {
        guard bytes.count <= size else { return nil }
        let p = make()
        p.start = 0
        p.end = 0
        p.append(bytes)
        return p
    }

    /// A packet of any size (reassembled datagrams). Never pooled.
    static func large(_ bytes: [UInt8], start: Int = 0) -> Packet {
        Packet(buffer: bytes, start: min(start, bytes.count), end: bytes.count)
    }

    /// Hand the buffer back for reuse. The caller must not touch it afterwards.
    func release() {
        guard !pooled, buf.count == Packet.size else { return }
        if packetPool.count < Packet.poolCap {
            pooled = true
            packetPool.append(self)
        } else {
            packetStats.dropped += 1
        }
    }

    var length: Int { end - start }

    /// A copy, in a fresh pooled buffer (nil if too large).
    func clone() -> Packet? {
        guard buf.count == Packet.size else { return nil }
        let p = Packet.make()
        p.start = start
        p.end = end
        for i in start..<end { p.buf[i] = buf[i] }
        return p
    }

    // Reads, relative to `start`. nil when any byte is outside start..<end.

    func u8(_ at: Int) -> UInt8? {
        guard at >= 0, at < length else { return nil }
        return buf[start + at]
    }

    func u16(_ at: Int) -> UInt16? {
        guard at >= 0, at <= length - 2 else { return nil }
        return UInt16(buf[start + at]) << 8 | UInt16(buf[start + at + 1])
    }

    func u32(_ at: Int) -> UInt32? {
        guard at >= 0, at <= length - 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(buf[start + at + i]) }
        return v
    }

    func u48(_ at: Int) -> UInt64? {
        guard at >= 0, at <= length - 6 else { return nil }
        var v: UInt64 = 0
        for i in 0..<6 { v = v << 8 | UInt64(buf[start + at + i]) }
        return v
    }

    /// Copy of `count` bytes at `at` (default: to the end).
    func bytes(_ at: Int = 0, _ count: Int? = nil) -> [UInt8]? {
        let n = count ?? (length - at)
        guard at >= 0, n >= 0, at <= length - n else { return nil }
        return Array(buf[(start + at)..<(start + at + n)])
    }

    /// A bounds-checked reader over the live region (its offsets are into `buf`).
    func reader() -> ByteReader { ByteReader(buf, from: start, count: length) }

    // Writes, relative to `start`, inside the live region.

    @discardableResult func setU8(_ at: Int, _ v: UInt8) -> Bool {
        guard at >= 0, at < length else { return false }
        buf[start + at] = v
        return true
    }

    @discardableResult func setU16(_ at: Int, _ v: UInt16) -> Bool {
        guard at >= 0, at <= length - 2 else { return false }
        buf[start + at] = UInt8(truncatingIfNeeded: v >> 8)
        buf[start + at + 1] = UInt8(truncatingIfNeeded: v)
        return true
    }

    // Growing at either end.

    /// Append bytes; false (nothing written) if the buffer is full.
    @discardableResult func append(_ bytes: [UInt8]) -> Bool {
        guard bytes.count <= buf.count - end else { return false }
        let at = end
        if !bytes.isEmpty {
            buf.withUnsafeMutableBytes { dst in
                bytes.withUnsafeBytes { src in (dst.baseAddress! + at).copyMemory(from: src.baseAddress!, byteCount: src.count) }
            }
        }
        end += bytes.count
        return true
    }

    @discardableResult func appendU8(_ v: UInt8) -> Bool {
        guard end < buf.count else { return false }
        buf[end] = v
        end += 1
        return true
    }

    @discardableResult func appendU16(_ v: UInt16) -> Bool {
        appendU8(UInt8(truncatingIfNeeded: v >> 8)) && appendU8(UInt8(truncatingIfNeeded: v))
    }

    @discardableResult func appendU32(_ v: UInt32) -> Bool {
        appendU16(UInt16(truncatingIfNeeded: v >> 16)) && appendU16(UInt16(truncatingIfNeeded: v))
    }

    @discardableResult func appendZeros(_ n: Int) -> Bool {
        guard n >= 0, n <= buf.count - end else { return false }
        for _ in 0..<n { buf[end] = 0; end += 1 }
        return true
    }

    /// Make room for a header of `n` zeroed bytes in front; false if there is no headroom.
    @discardableResult func push(_ n: Int) -> Bool {
        guard n >= 0, n <= start else { return false }
        start -= n
        for i in start..<(start + n) { buf[i] = 0 }
        return true
    }

    /// Drop `n` bytes from the front (the header just parsed). The bytes stay
    /// in `buf` before `start` (ICMP errors quote them).
    @discardableResult func pull(_ n: Int) -> Bool {
        guard n >= 0, n <= length else { return false }
        start += n
        return true
    }

    /// Keep only the first `n` bytes.
    func trim(to n: Int) {
        if n >= 0 && n < length { end = start + n }
    }
}

var packetPool: [Packet] = []

struct PacketStats {
    var fresh: UInt64 = 0
    var reused: UInt64 = 0
    /// Releases refused because the free list was full.
    var dropped: UInt64 = 0
}
var packetStats = PacketStats()
