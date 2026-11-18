// Inflate: DEFLATE (RFC 1951), zlib (RFC 1950) and gzip (RFC 1952) decoding.
//
// Streaming API (what HTTP bodies and PNG IDAT chunks use):
//
//     var z = Inflater(format: .auto, maxOutput: 64 << 20)
//     try z.feed(chunk)            // any chunk sizes, including 0 or 1 byte
//     let out = z.take()           // decoded bytes so far (drains them)
//     try z.finish()               // at end of input: throws .truncated
//
// `z.isDone` becomes true once the stream (all gzip members) is complete;
// bytes after the end of a zlib/deflate stream or a gzip member that does not
// start another member are ignored. After an error the Inflater stays failed,
// but `take()` still returns whatever was decoded before the error.
//
// One-shot: `try inflateBytes(data, format: .auto, maxOutput: n)`.
//
// `maxOutput` bounds the total decoded size (decompression bombs): the
// error `.outputLimit` is thrown before the limit is exceeded. Hostile input
// never traps: every loop is bounded by the input or by `maxOutput`.

enum InflateError: Error, Equatable {
    case badHeader          // zlib/gzip header invalid or unsupported (FDICT)
    case badChecksum        // Adler-32, CRC-32, ISIZE or header CRC mismatch
    case truncated          // input ended before the stream did
    case invalidBlockType   // block type 3
    case invalidStoredLength// LEN and NLEN disagree
    case invalidCode        // bad Huffman tree or undecodable symbol
    case invalidDistance    // match reaches before the start of the output
    case outputLimit        // decoded size would exceed maxOutput
}

enum InflateFormat {
    case raw    // bare DEFLATE
    case zlib
    case gzip
    case auto   // gzip if it starts 1f 8b, zlib if the header checks out, else raw
}

private let inflateLenBase: [UInt16] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
private let inflateLenExtra: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
private let inflateDistBase: [UInt16] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
private let inflateDistExtra: [UInt8] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
private let inflateCLOrder: [UInt8] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

/// Canonical Huffman decoder: a direct table for codes up to `primary` bits
/// and the classic count/symbol walk for longer ones.
struct InflateHuffman {
    var fast: [UInt16] = []      // sym << 4 | len, 0 = not in the table
    var counts = [UInt16](repeating: 0, count: 16)
    var symbols: [UInt16] = []
    var primary = 0

    /// false if the lengths over-subscribe the code, or leave it incomplete
    /// (other than the single-code case).
    mutating func build(_ lengths: [UInt8], _ n: Int, primary p: Int) -> Bool {
        primary = p
        for i in 0..<16 { counts[i] = 0 }
        for i in 0..<n { counts[Int(lengths[i])] &+= 1 }
        var left = 1
        if counts[0] != UInt16(n) {
            for l in 1...15 {
                left <<= 1
                left -= Int(counts[l])
                if left < 0 { return false }
            }
            if left > 0 && n - Int(counts[0]) != 1 { return false }
        }
        var offs = [Int](repeating: 0, count: 17)
        for l in 1...15 { offs[l + 1] = offs[l] + Int(counts[l]) }
        if symbols.count < n { symbols = [UInt16](repeating: 0, count: n) }
        for s in 0..<n where lengths[s] != 0 {
            let l = Int(lengths[s])
            symbols[offs[l]] = UInt16(s)
            offs[l] += 1
        }
        // Fast table: canonical codes, bit-reversed.
        let size = 1 << p
        if fast.count != size { fast = [UInt16](repeating: 0, count: size) }
        else { for i in 0..<size { fast[i] = 0 } }
        var code = 0
        var idx = 0
        for l in 1...15 {
            let c = Int(counts[l])
            if l <= p {
                for k in 0..<c {
                    let sym = Int(symbols[idx + k])
                    var rev = 0
                    var v = code + k
                    for _ in 0..<l { rev = rev << 1 | (v & 1); v >>= 1 }
                    let entry = UInt16(truncatingIfNeeded: sym << 4 | l)
                    var j = rev
                    while j < size { fast[j] = entry; j += 1 << l }
                }
            }
            idx += c
            code = (code + c) << 1
        }
        return true
    }

    /// symbol | length << 16; -1 invalid code; -2 not enough bits (`avail`).
    @inline(__always)
    func decode(_ bits: UInt64, _ avail: Int) -> Int {
        let e = Int(fast[Int(truncatingIfNeeded: bits) & ((1 << primary) - 1)])
        if e != 0 {
            let l = e & 15
            return l <= avail ? (e >> 4) | (l << 16) : -2
        }
        var code = 0, first = 0, index = 0
        var b = bits
        for len in 1...15 {
            if len > avail { return -2 }
            code |= Int(b & 1)
            b >>= 1
            let c = Int(counts[len])
            if code - c < first { return Int(symbols[index + (code - first)]) | (len << 16) }
            index += c
            first += c
            first <<= 1
            code <<= 1
        }
        return -1
    }
}

struct InflateCRC32 {
    private var table = [UInt32](repeating: 0, count: 256)
    init() {
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
    }
    /// Running state starts at 0 and is passed back in (pre/post inversion is internal).
    func update(_ crc: UInt32, _ data: [UInt8], _ from: Int, _ to: Int) -> UInt32 {
        var c = ~crc
        var i = from
        while i < to { c = table[Int((c ^ UInt32(data[i])) & 0xff)] ^ (c >> 8); i += 1 }
        return ~c
    }
    func of(_ data: [UInt8]) -> UInt32 { update(0, data, 0, data.count) }
}

func inflateAdler32(_ adler: UInt32, _ data: [UInt8], _ from: Int, _ to: Int) -> UInt32 {
    var a = adler & 0xffff, b = adler >> 16
    var i = from
    while i < to {
        let end = min(to, i + 5552)
        while i < end { a &+= UInt32(data[i]); b &+= a; i += 1 }
        a %= 65521; b %= 65521
    }
    return b << 16 | a
}

struct Inflater {
    private enum Phase { case header, blockHeader, stored, huffman, trailer, nextMember, done, failed }

    private let format: InflateFormat
    private let maxOutput: Int
    private var resolved: InflateFormat
    private var phase = Phase.header
    private var failure = InflateError.truncated

    // Input and bit buffer.
    private var inp: [UInt8] = []
    private var inPos = 0
    private var bitbuf: UInt64 = 0
    private var bitcnt = 0

    // Output: buf[0..<len] is the window plus undrained bytes.
    private var buf: [UInt8] = []
    private var len = 0
    private var base = 0        // bytes trimmed away before buf[0]
    private var drained = 0     // buf[drained..<len] is pending
    private var summed = 0      // buf[summed..<len] not yet in the checksum

    private var lastBlock = false
    private var storedLeft = 0
    private var lit = InflateHuffman()
    private var dist = InflateHuffman()
    private var lengths = [UInt8](repeating: 0, count: 320)

    private var crcTable: InflateCRC32? = nil
    private var crc: UInt32 = 0
    private var adler: UInt32 = 1
    private var memberOut: UInt32 = 0

    init(format: InflateFormat = .auto, maxOutput: Int = 1 << 30) {
        self.format = format
        self.maxOutput = maxOutput
        self.resolved = format
    }

    /// True once a complete stream (or, for gzip, a complete member) has been decoded.
    var isDone: Bool { phase == .done || phase == .nextMember }
    /// Decoded bytes waiting to be taken.
    var pendingCount: Int { len - drained }
    /// Total decoded bytes so far, taken or not.
    var totalOut: Int { base + len }

    // MARK: public

    mutating func feed(_ chunk: [UInt8]) throws(InflateError) {
        if phase == .failed { throw failure }
        if phase == .done { return }
        if inPos > 0 { inp.removeSubrange(0..<inPos); inPos = 0 }
        inp.append(contentsOf: chunk)
        do throws(InflateError) { try run() } catch {
            syncSums()
            phase = .failed; failure = error
            throw error
        }
        syncSums()
    }

    /// Call at end of input. Throws .truncated if the stream is incomplete.
    mutating func finish() throws(InflateError) {
        if phase == .failed { throw failure }
        if phase == .done { return }
        if phase == .nextMember { phase = .done; return }
        phase = .failed; failure = .truncated
        throw InflateError.truncated
    }

    /// The decoded bytes produced since the last call.
    mutating func take() -> [UInt8] {
        syncSums()
        let out = Array(buf[drained..<len])
        drained = len
        if len > 262_144 {
            let k = len - 32_768
            buf.removeSubrange(0..<k)
            len -= k; base += k; drained = len; summed = len
        }
        return out
    }

    // MARK: internals

    private mutating func syncSums() {
        if summed >= len { return }
        memberOut &+= UInt32(truncatingIfNeeded: len - summed)
        if resolved == .zlib { adler = inflateAdler32(adler, buf, summed, len) }
        else if resolved == .gzip, let t = crcTable { crc = t.update(crc, buf, summed, len) }
        summed = len
    }

    private mutating func refill() {
        while bitcnt <= 56 && inPos < inp.count {
            bitbuf |= UInt64(inp[inPos]) << UInt64(bitcnt)
            inPos += 1
            bitcnt += 8
        }
    }

    /// Returns the n-bit value, or -1 if the bits aren't there (n <= 16).
    private mutating func bits(_ n: Int) -> Int {
        if bitcnt < n { refill(); if bitcnt < n { return -1 } }
        let v = Int(truncatingIfNeeded: bitbuf & ((1 << UInt64(n)) - 1))
        bitbuf >>= UInt64(n)
        bitcnt -= n
        return v
    }

    private mutating func ensureOut(_ n: Int) {
        if buf.count - len < n {
            buf.append(contentsOf: repeatElement(0, count: max(buf.count, 8192)))
        }
    }

    /// Give whole bytes held in the bit buffer back to the input.
    private mutating func unreadBits() {
        inPos -= bitcnt >> 3
        bitbuf = 0; bitcnt = 0
    }

    private mutating func run() throws(InflateError) {
        while true {
            switch phase {
            case .header:
                if !(try parseHeader()) { return }
                phase = .blockHeader
                lastBlock = false
            case .blockHeader:
                if !(try blockHeader()) { return }
            case .stored:
                if !(try copyStored()) { return }
            case .huffman:
                if !(try huffmanBlock()) { return }
            case .trailer:
                if !(try parseTrailer()) { return }
            case .nextMember:
                if inp.count - inPos < 2 { return }
                if inp[inPos] == 0x1f && inp[inPos + 1] == 0x8b { phase = .header }
                else { phase = .done }
            case .done, .failed:
                return
            }
        }
    }

    // MARK: wrappers

    private mutating func parseHeader() throws(InflateError) -> Bool {
        let avail = inp.count - inPos
        if resolved == .auto {
            if avail < 2 { return false }
            let a = inp[inPos], b = inp[inPos + 1]
            if a == 0x1f && b == 0x8b { resolved = .gzip }
            else if a & 0x0f == 8 && (Int(a) << 8 | Int(b)) % 31 == 0 { resolved = .zlib }
            else { resolved = .raw }
        }
        switch resolved {
        case .raw, .auto:
            return true
        case .zlib:
            if avail < 2 { return false }
            let cmf = Int(inp[inPos]), flg = Int(inp[inPos + 1])
            if cmf & 0x0f != 8 || cmf >> 4 > 7 || (cmf << 8 | flg) % 31 != 0 || flg & 0x20 != 0 {
                throw InflateError.badHeader
            }
            inPos += 2
            adler = 1
            return true
        case .gzip:
            if avail < 10 { return false }
            let p = inPos
            if inp[p] != 0x1f || inp[p + 1] != 0x8b || inp[p + 2] != 8 || inp[p + 3] & 0xe0 != 0 {
                throw InflateError.badHeader
            }
            let flg = inp[p + 3]
            var q = p + 10
            if flg & 4 != 0 {
                if inp.count - q < 2 { return false }
                let xlen = Int(inp[q]) | Int(inp[q + 1]) << 8
                q += 2
                if inp.count - q < xlen { return false }
                q += xlen
            }
            for bit in [UInt8(8), 16] where flg & bit != 0 {
                var n = 0
                while true {
                    if q >= inp.count { return false }
                    let c = inp[q]; q += 1; n += 1
                    if c == 0 { break }
                    if n > 65536 { throw InflateError.badHeader }
                }
            }
            if flg & 2 != 0 {
                if inp.count - q < 2 { return false }
                let t = InflateCRC32()
                let want = UInt32(inp[q]) | UInt32(inp[q + 1]) << 8
                if t.update(0, inp, p, q) & 0xffff != want { throw InflateError.badChecksum }
                q += 2
            }
            inPos = q
            if crcTable == nil { crcTable = InflateCRC32() }
            crc = 0
            memberOut = 0
            return true
        }
    }

    private mutating func parseTrailer() throws(InflateError) -> Bool {
        syncSums()
        switch resolved {
        case .zlib:
            if inp.count - inPos < 4 { return false }
            let want = UInt32(inp[inPos]) << 24 | UInt32(inp[inPos + 1]) << 16
                | UInt32(inp[inPos + 2]) << 8 | UInt32(inp[inPos + 3])
            if want != adler { throw InflateError.badChecksum }
            inPos += 4
            phase = .done
        case .gzip:
            if inp.count - inPos < 8 { return false }
            let p = inPos
            let c = UInt32(inp[p]) | UInt32(inp[p + 1]) << 8 | UInt32(inp[p + 2]) << 16 | UInt32(inp[p + 3]) << 24
            let n = UInt32(inp[p + 4]) | UInt32(inp[p + 5]) << 8 | UInt32(inp[p + 6]) << 16 | UInt32(inp[p + 7]) << 24
            if c != crc || n != memberOut { throw InflateError.badChecksum }
            inPos += 8
            phase = .nextMember
        default:
            phase = .done
        }
        return true
    }

    // MARK: blocks

    private mutating func blockHeader() throws(InflateError) -> Bool {
        if lastBlock {
            unreadBits()
            phase = .trailer
            return true
        }
        refill()
        let sb = bitbuf, sc = bitcnt, sp = inPos
        let h = bits(3)
        if h < 0 { return false }
        switch h >> 1 {
        case 0:
            let drop = bitcnt & 7
            bitbuf >>= UInt64(drop); bitcnt -= drop
            let l = bits(16), nl = bits(16)
            if l < 0 || nl < 0 { bitbuf = sb; bitcnt = sc; inPos = sp; return false }
            if l ^ nl != 0xffff { throw InflateError.invalidStoredLength }
            storedLeft = l
            phase = .stored
        case 1:
            for i in 0..<144 { lengths[i] = 8 }
            for i in 144..<256 { lengths[i] = 9 }
            for i in 256..<280 { lengths[i] = 7 }
            for i in 280..<288 { lengths[i] = 8 }
            if !lit.build(lengths, 288, primary: 10) { throw InflateError.invalidCode }
            for i in 0..<32 { lengths[i] = 5 }
            if !dist.build(lengths, 32, primary: 8) { throw InflateError.invalidCode }
            phase = .huffman
        case 2:
            if !(try dynamicTables()) {
                bitbuf = sb; bitcnt = sc; inPos = sp
                return false
            }
            phase = .huffman
        default:
            throw InflateError.invalidBlockType
        }
        lastBlock = h & 1 != 0
        return true
    }

    /// Reads a dynamic block's tables; false if input ran out (caller rewinds).
    private mutating func dynamicTables() throws(InflateError) -> Bool {
        let hlit = bits(5), hdist = bits(5), hclen = bits(4)
        if hlit < 0 || hdist < 0 || hclen < 0 { return false }
        let nlen = hlit + 257, ndist = hdist + 1
        if nlen > 286 || ndist > 30 { throw InflateError.invalidCode }
        var cl = [UInt8](repeating: 0, count: 19)
        for i in 0..<(hclen + 4) {
            let v = bits(3)
            if v < 0 { return false }
            cl[Int(inflateCLOrder[i])] = UInt8(v)
        }
        var clh = InflateHuffman()
        if !clh.build(cl, 19, primary: 7) { throw InflateError.invalidCode }
        var i = 0
        let total = nlen + ndist
        while i < total {
            refill()
            let r = clh.decode(bitbuf, bitcnt)
            if r == -1 { throw InflateError.invalidCode }
            if r == -2 { return false }
            let l = r >> 16
            bitbuf >>= UInt64(l); bitcnt -= l
            let sym = r & 0xffff
            if sym < 16 { lengths[i] = UInt8(sym); i += 1; continue }
            var prev: UInt8 = 0
            var rep = 0
            if sym == 16 {
                if i == 0 { throw InflateError.invalidCode }
                prev = lengths[i - 1]
                let e = bits(2); if e < 0 { return false }
                rep = 3 + e
            } else if sym == 17 {
                let e = bits(3); if e < 0 { return false }
                rep = 3 + e
            } else {
                let e = bits(7); if e < 0 { return false }
                rep = 11 + e
            }
            if i + rep > total { throw InflateError.invalidCode }
            for _ in 0..<rep { lengths[i] = prev; i += 1 }
        }
        if lengths[256] == 0 { throw InflateError.invalidCode }
        if !lit.build(lengths, nlen, primary: 10) { throw InflateError.invalidCode }
        var dl = [UInt8](repeating: 0, count: ndist)
        for k in 0..<ndist { dl[k] = lengths[nlen + k] }
        if !dist.build(dl, ndist, primary: 8) { throw InflateError.invalidCode }
        return true
    }

    private mutating func copyStored() throws(InflateError) -> Bool {
        while storedLeft > 0 {
            if base + len >= maxOutput { throw InflateError.outputLimit }
            ensureOut(1)
            if bitcnt >= 8 {
                buf[len] = UInt8(truncatingIfNeeded: bitbuf)
                bitbuf >>= 8; bitcnt -= 8
            } else if inPos < inp.count {
                buf[len] = inp[inPos]; inPos += 1
            } else { return false }
            len += 1
            storedLeft -= 1
        }
        phase = .blockHeader
        return true
    }

    private mutating func huffmanBlock() throws(InflateError) -> Bool {
        while true {
            ensureOut(258)
            refill()
            let sb = bitbuf, sc = bitcnt, sp = inPos
            let r = lit.decode(bitbuf, bitcnt)
            if r < 0 {
                if r == -1 { throw InflateError.invalidCode }
                return false
            }
            bitbuf >>= UInt64(r >> 16); bitcnt -= r >> 16
            let sym = r & 0xffff
            if sym < 256 {
                if base + len >= maxOutput { throw InflateError.outputLimit }
                buf[len] = UInt8(truncatingIfNeeded: sym)
                len += 1
                continue
            }
            if sym == 256 { phase = .blockHeader; return true }
            if sym > 285 { throw InflateError.invalidCode }
            let li = sym - 257
            var length = Int(inflateLenBase[li])
            let le = Int(inflateLenExtra[li])
            if le > 0 {
                if bitcnt < le { bitbuf = sb; bitcnt = sc; inPos = sp; return false }
                length += Int(truncatingIfNeeded: bitbuf & ((1 << UInt64(le)) - 1))
                bitbuf >>= UInt64(le); bitcnt -= le
            }
            let d = dist.decode(bitbuf, bitcnt)
            if d < 0 {
                if d == -1 { throw InflateError.invalidCode }
                bitbuf = sb; bitcnt = sc; inPos = sp
                return false
            }
            bitbuf >>= UInt64(d >> 16); bitcnt -= d >> 16
            let ds = d & 0xffff
            if ds >= 30 { throw InflateError.invalidCode }
            var distance = Int(inflateDistBase[ds])
            let de = Int(inflateDistExtra[ds])
            if de > 0 {
                if bitcnt < de { bitbuf = sb; bitcnt = sc; inPos = sp; return false }
                distance += Int(truncatingIfNeeded: bitbuf & ((1 << UInt64(de)) - 1))
                bitbuf >>= UInt64(de); bitcnt -= de
            }
            if distance > len { throw InflateError.invalidDistance }
            if base + len + length > maxOutput {
                // Keep everything up to the limit, then fail.
                length = maxOutput - base - len
                var s = len - distance, o = len
                for _ in 0..<length { buf[o] = buf[s]; o += 1; s += 1 }
                len = o
                throw InflateError.outputLimit
            }
            var s = len - distance
            var o = len
            for _ in 0..<length { buf[o] = buf[s]; o += 1; s += 1 }
            len = o
        }
    }
}

/// One-shot decode. `maxOutput` bounds the decoded size.
func inflateBytes(_ data: [UInt8], format: InflateFormat = .auto, maxOutput: Int = 1 << 30) throws(InflateError) -> [UInt8] {
    var z = Inflater(format: format, maxOutput: maxOutput)
    try z.feed(data)
    try z.finish()
    return z.take()
}
