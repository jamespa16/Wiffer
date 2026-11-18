// SHA-256, SHA-384 and SHA-512 (FIPS 180-4).
//
//   var h = SHA256()            // or SHA384(), SHA512()
//   h.update(bytes)             // any number of times
//   let d = h.finalize()        // 32 / 48 / 64 bytes; h can keep going
//   SHA256.hash(bytes)          // one shot
//
// The states are small value types, so copying one (a TLS transcript hash
// at a given point in the handshake) is a plain assignment.

struct SHA256Words {
    var a, b, c, d, e, f, g, h: UInt32
    init(_ v: [UInt32]) { a = v[0]; b = v[1]; c = v[2]; d = v[3]; e = v[4]; f = v[5]; g = v[6]; h = v[7] }
}

struct SHA512Words {
    var a, b, c, d, e, f, g, h: UInt64
    init(_ v: [UInt64]) { a = v[0]; b = v[1]; c = v[2]; d = v[3]; e = v[4]; f = v[5]; g = v[6]; h = v[7] }
}

func sha256Compress(_ s: inout SHA256Words, _ data: UnsafePointer<UInt8>, _ blocks: Int) {
    sha256K.withUnsafeBufferPointer { k in
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            var p = data
            for _ in 0..<blocks {
                for i in 0..<16 { w[i] = cryptoLoad32BE(p + 4 * i) }
                for i in 16..<64 {
                    let x = w[i - 15], y = w[i - 2]
                    let s0 = cryptoRotr32(x, 7) ^ cryptoRotr32(x, 18) ^ (x &>> 3)
                    let s1 = cryptoRotr32(y, 17) ^ cryptoRotr32(y, 19) ^ (y &>> 10)
                    w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                }
                var a = s.a, b = s.b, c = s.c, d = s.d, e = s.e, f = s.f, g = s.g, h = s.h
                for i in 0..<64 {
                    let s1 = cryptoRotr32(e, 6) ^ cryptoRotr32(e, 11) ^ cryptoRotr32(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                    let s0 = cryptoRotr32(a, 2) ^ cryptoRotr32(a, 13) ^ cryptoRotr32(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    h = g; g = f; f = e; e = d &+ t1
                    d = c; c = b; b = a; a = t1 &+ s0 &+ maj
                }
                s.a &+= a; s.b &+= b; s.c &+= c; s.d &+= d
                s.e &+= e; s.f &+= f; s.g &+= g; s.h &+= h
                p += 64
            }
        }
    }
}

func sha512Compress(_ s: inout SHA512Words, _ data: UnsafePointer<UInt8>, _ blocks: Int) {
    sha512K.withUnsafeBufferPointer { k in
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 80) { w in
            var p = data
            for _ in 0..<blocks {
                for i in 0..<16 { w[i] = cryptoLoad64BE(p + 8 * i) }
                for i in 16..<80 {
                    let x = w[i - 15], y = w[i - 2]
                    let s0 = cryptoRotr64(x, 1) ^ cryptoRotr64(x, 8) ^ (x &>> 7)
                    let s1 = cryptoRotr64(y, 19) ^ cryptoRotr64(y, 61) ^ (y &>> 6)
                    w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                }
                var a = s.a, b = s.b, c = s.c, d = s.d, e = s.e, f = s.f, g = s.g, h = s.h
                for i in 0..<80 {
                    let s1 = cryptoRotr64(e, 14) ^ cryptoRotr64(e, 18) ^ cryptoRotr64(e, 41)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                    let s0 = cryptoRotr64(a, 28) ^ cryptoRotr64(a, 34) ^ cryptoRotr64(a, 39)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    h = g; g = f; f = e; e = d &+ t1
                    d = c; c = b; b = a; a = t1 &+ s0 &+ maj
                }
                s.a &+= a; s.b &+= b; s.c &+= c; s.d &+= d
                s.e &+= e; s.f &+= f; s.g &+= g; s.h &+= h
                p += 128
            }
        }
    }
}

/// Block buffering shared by the SHA-2 family: feeds whole blocks to
/// `compress` and keeps the tail.
struct SHA2Buffer {
    var pending: [UInt8] = []
    var length: UInt64 = 0   // bytes hashed so far

    mutating func feed(_ data: UnsafeRawBufferPointer, block: Int,
                       _ compress: (UnsafePointer<UInt8>, Int) -> Void) {
        guard let raw = data.baseAddress, data.count > 0 else { return }
        var p = raw.assumingMemoryBound(to: UInt8.self)
        var n = data.count
        length &+= UInt64(n)
        if !pending.isEmpty {
            let take = min(block - pending.count, n)
            pending.append(contentsOf: UnsafeBufferPointer(start: p, count: take))
            p += take; n -= take
            if pending.count == block {
                do {
                    let full = pending
                    full.withUnsafeBufferPointer { compress($0.baseAddress!, 1) }
                }
                pending.removeAll(keepingCapacity: true)
            }
        }
        if n >= block {
            let blocks = n / block
            compress(p, blocks)
            p += blocks * block; n -= blocks * block
        }
        if n > 0 { pending.append(contentsOf: UnsafeBufferPointer(start: p, count: n)) }
    }

    /// The final padding: 0x80, zeros, and the bit length (lenBytes wide).
    func padding(block: Int, lenBytes: Int) -> [UInt8] {
        var zeros = block - lenBytes - 1 - pending.count
        if zeros < 0 { zeros += block }
        var pad: [UInt8] = [0x80]
        pad.append(contentsOf: [UInt8](repeating: 0, count: zeros + lenBytes - 8))
        if lenBytes == 16 { pad[pad.count - 1] = UInt8(truncatingIfNeeded: length >> 61) }
        cryptoAppend64BE(&pad, length &<< 3)
        return pad
    }
}

struct SHA256: CryptoHash {
    static var digestSize: Int { 32 }
    static var blockSize: Int { 64 }
    private var words = SHA256Words(sha256IV)
    private var buf = SHA2Buffer()

    init() {}

    mutating func update(_ data: UnsafeRawBufferPointer) {
        var w = words
        buf.feed(data, block: 64) { p, n in sha256Compress(&w, p, n) }
        words = w
    }

    func finalize() -> [UInt8] {
        var c = self
        let pad = buf.padding(block: 64, lenBytes: 8)
        c.update(pad)
        let w = c.words
        var out = [UInt8](repeating: 0, count: 32)
        out.withUnsafeMutableBufferPointer { o in
            let p = o.baseAddress!
            cryptoStore32BE(p, w.a); cryptoStore32BE(p + 4, w.b)
            cryptoStore32BE(p + 8, w.c); cryptoStore32BE(p + 12, w.d)
            cryptoStore32BE(p + 16, w.e); cryptoStore32BE(p + 20, w.f)
            cryptoStore32BE(p + 24, w.g); cryptoStore32BE(p + 28, w.h)
        }
        return out
    }
}

/// SHA-512 and (with another IV, truncated) SHA-384.
struct SHA512Engine {
    var words: SHA512Words
    var buf = SHA2Buffer()

    init(iv: [UInt64]) { words = SHA512Words(iv) }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        var w = words
        buf.feed(data, block: 128) { p, n in sha512Compress(&w, p, n) }
        words = w
    }

    func finalize(_ count: Int) -> [UInt8] {
        var c = self
        let pad = buf.padding(block: 128, lenBytes: 16)
        pad.withUnsafeBytes { c.update($0) }
        let w = c.words
        var out = [UInt8](repeating: 0, count: 64)
        out.withUnsafeMutableBufferPointer { o in
            let p = o.baseAddress!
            cryptoStore64BE(p, w.a); cryptoStore64BE(p + 8, w.b)
            cryptoStore64BE(p + 16, w.c); cryptoStore64BE(p + 24, w.d)
            cryptoStore64BE(p + 32, w.e); cryptoStore64BE(p + 40, w.f)
            cryptoStore64BE(p + 48, w.g); cryptoStore64BE(p + 56, w.h)
        }
        return count == 64 ? out : Array(out[0..<count])
    }
}

struct SHA512: CryptoHash {
    static var digestSize: Int { 64 }
    static var blockSize: Int { 128 }
    private var engine = SHA512Engine(iv: sha512IV)
    init() {}
    mutating func update(_ data: UnsafeRawBufferPointer) { engine.update(data) }
    func finalize() -> [UInt8] { engine.finalize(64) }
}

struct SHA384: CryptoHash {
    static var digestSize: Int { 48 }
    static var blockSize: Int { 128 }
    private var engine = SHA512Engine(iv: sha384IV)
    init() {}
    mutating func update(_ data: UnsafeRawBufferPointer) { engine.update(data) }
    func finalize() -> [UInt8] { engine.finalize(48) }
}
