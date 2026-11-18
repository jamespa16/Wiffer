// ChaCha20, Poly1305 and ChaCha20-Poly1305 (RFC 8439).
//
//   ChaCha20.xor(key: k32, nonce: n12, counter: 1, data)  -> keystream XOR
//   ChaCha20.block(key:nonce:counter:)                     -> 64 bytes
//   var p = Poly1305(key: k32); p.update(m); p.finalize()  -> 16-byte tag
//   let c = ChaCha20Poly1305(key: k32)!                    // CryptoAEAD
//   c.seal(nonce:aad:plaintext:) -> ct || tag;  c.open(...) -> plaintext?
//   (seal traps on a nonce that isn't 12 bytes; open returns nil)
//
// Both are constant-time by construction (no secret-dependent branches or
// table lookups). Poly1305 uses five 26-bit limbs ("donna-32" layout).

struct ChaCha20Key {
    var k: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)

    init(_ key: [UInt8]) {
        precondition(key.count == 32)
        var w = [UInt32](repeating: 0, count: 8)
        key.withUnsafeBufferPointer { p in
            for i in 0..<8 { w[i] = cryptoLoad32LE(p.baseAddress! + 4 * i) }
        }
        k = (w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7])
    }

    init(words w: [UInt32]) { k = (w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]) }
}

enum ChaCha20 {
    @inline(__always) static func qr(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32) {
        a &+= b; d ^= a; d = cryptoRotl32(d, 16)
        c &+= d; b ^= c; b = cryptoRotl32(b, 12)
        a &+= b; d ^= a; d = cryptoRotl32(d, 8)
        c &+= d; b ^= c; b = cryptoRotl32(b, 7)
    }

    /// One 64-byte keystream block into `out`.
    static func block(_ key: ChaCha20Key, _ n0: UInt32, _ n1: UInt32, _ n2: UInt32,
                      _ counter: UInt32, _ out: UnsafeMutablePointer<UInt8>) {
        let c0: UInt32 = 0x6170_7865, c1: UInt32 = 0x3320_646e, c2: UInt32 = 0x7962_2d32, c3: UInt32 = 0x6b20_6574
        let k = key.k
        var x0 = c0, x1 = c1, x2 = c2, x3 = c3
        var x4 = k.0, x5 = k.1, x6 = k.2, x7 = k.3, x8 = k.4, x9 = k.5, x10 = k.6, x11 = k.7
        var x12 = counter, x13 = n0, x14 = n1, x15 = n2
        for _ in 0..<10 {
            qr(&x0, &x4, &x8, &x12); qr(&x1, &x5, &x9, &x13)
            qr(&x2, &x6, &x10, &x14); qr(&x3, &x7, &x11, &x15)
            qr(&x0, &x5, &x10, &x15); qr(&x1, &x6, &x11, &x12)
            qr(&x2, &x7, &x8, &x13); qr(&x3, &x4, &x9, &x14)
        }
        cryptoStore32LE(out, x0 &+ c0); cryptoStore32LE(out + 4, x1 &+ c1)
        cryptoStore32LE(out + 8, x2 &+ c2); cryptoStore32LE(out + 12, x3 &+ c3)
        cryptoStore32LE(out + 16, x4 &+ k.0); cryptoStore32LE(out + 20, x5 &+ k.1)
        cryptoStore32LE(out + 24, x6 &+ k.2); cryptoStore32LE(out + 28, x7 &+ k.3)
        cryptoStore32LE(out + 32, x8 &+ k.4); cryptoStore32LE(out + 36, x9 &+ k.5)
        cryptoStore32LE(out + 40, x10 &+ k.6); cryptoStore32LE(out + 44, x11 &+ k.7)
        cryptoStore32LE(out + 48, x12 &+ counter); cryptoStore32LE(out + 52, x13 &+ n0)
        cryptoStore32LE(out + 56, x14 &+ n1); cryptoStore32LE(out + 60, x15 &+ n2)
    }

    static func nonceWords(_ nonce: [UInt8]) -> (UInt32, UInt32, UInt32) {
        precondition(nonce.count == 12)
        return nonce.withUnsafeBufferPointer { p in
            (cryptoLoad32LE(p.baseAddress!), cryptoLoad32LE(p.baseAddress! + 4), cryptoLoad32LE(p.baseAddress! + 8))
        }
    }

    static func block(key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
        let n = nonceWords(nonce)
        var out = [UInt8](repeating: 0, count: 64)
        out.withUnsafeMutableBufferPointer { block(ChaCha20Key(key), n.0, n.1, n.2, counter, $0.baseAddress!) }
        return out
    }

    /// XOR `data` with the keystream starting at block `counter`.
    static func xor(key: [UInt8], nonce: [UInt8], counter: UInt32, _ data: [UInt8]) -> [UInt8] {
        xor(ChaCha20Key(key), nonce, counter, data[...])
    }

    static func xor(_ key: ChaCha20Key, _ nonce: [UInt8], _ counter: UInt32, _ data: ArraySlice<UInt8>) -> [UInt8] {
        let n = nonceWords(nonce)
        var out = [UInt8](repeating: 0, count: data.count)
        var ks = [UInt8](repeating: 0, count: 64)
        data.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                ks.withUnsafeMutableBufferPointer { kp in
                    var off = 0, ctr = counter
                    while off < inp.count {
                        block(key, n.0, n.1, n.2, ctr, kp.baseAddress!)
                        let m = min(64, inp.count - off)
                        for i in 0..<m { o[off + i] = inp[off + i] ^ kp[i] }
                        off += m
                        ctr &+= 1
                    }
                }
            }
        }
        return out
    }
}

struct Poly1305 {
    private var r0, r1, r2, r3, r4: UInt64
    private var h0: UInt64 = 0, h1: UInt64 = 0, h2: UInt64 = 0, h3: UInt64 = 0, h4: UInt64 = 0
    private let pad: UInt128
    private var pending: [UInt8] = []

    init(key: [UInt8]) {
        precondition(key.count == 32)
        var r: UInt128 = 0, s: UInt128 = 0
        for i in (0..<16).reversed() {
            r = r << 8 | UInt128(key[i])
            s = s << 8 | UInt128(key[16 + i])
        }
        r &= 0x0fff_fffc_0fff_fffc_0fff_fffc_0fff_ffff
        let m: UInt128 = 0x3ff_ffff
        r0 = UInt64(r & m); r1 = UInt64((r >> 26) & m); r2 = UInt64((r >> 52) & m)
        r3 = UInt64((r >> 78) & m); r4 = UInt64((r >> 104) & m)
        pad = s
    }

    private mutating func blocks(_ p: UnsafePointer<UInt8>, _ count: Int, hibit: UInt64) {
        let mask: UInt64 = 0x3ff_ffff
        let s1 = r1 &* 5, s2 = r2 &* 5, s3 = r3 &* 5, s4 = r4 &* 5
        var a0 = h0, a1 = h1, a2 = h2, a3 = h3, a4 = h4
        var q = p
        for _ in 0..<count {
            let t0 = UInt64(cryptoLoad32LE(q)), t1 = UInt64(cryptoLoad32LE(q + 4))
            let t2 = UInt64(cryptoLoad32LE(q + 8)), t3 = UInt64(cryptoLoad32LE(q + 12))
            a0 &+= t0 & mask
            a1 &+= ((t0 >> 26) | (t1 << 6)) & mask
            a2 &+= ((t1 >> 20) | (t2 << 12)) & mask
            a3 &+= ((t2 >> 14) | (t3 << 18)) & mask
            a4 &+= (t3 >> 8) | hibit
            let d0 = a0 &* r0 &+ a1 &* s4 &+ a2 &* s3 &+ a3 &* s2 &+ a4 &* s1
            var d1 = a0 &* r1 &+ a1 &* r0 &+ a2 &* s4 &+ a3 &* s3 &+ a4 &* s2
            var d2 = a0 &* r2 &+ a1 &* r1 &+ a2 &* r0 &+ a3 &* s4 &+ a4 &* s3
            var d3 = a0 &* r3 &+ a1 &* r2 &+ a2 &* r1 &+ a3 &* r0 &+ a4 &* s4
            var d4 = a0 &* r4 &+ a1 &* r3 &+ a2 &* r2 &+ a3 &* r1 &+ a4 &* r0
            a0 = d0 & mask; d1 &+= d0 >> 26
            a1 = d1 & mask; d2 &+= d1 >> 26
            a2 = d2 & mask; d3 &+= d2 >> 26
            a3 = d3 & mask; d4 &+= d3 >> 26
            a4 = d4 & mask
            a0 &+= (d4 >> 26) &* 5
            a1 &+= a0 >> 26; a0 &= mask
            q += 16
        }
        h0 = a0; h1 = a1; h2 = a2; h3 = a3; h4 = a4
    }

    mutating func update(_ data: [UInt8]) { update(data[...]) }

    mutating func update(_ data: ArraySlice<UInt8>) {
        var d = data
        if !pending.isEmpty {
            let take = min(16 - pending.count, d.count)
            pending.append(contentsOf: d.prefix(take))
            d = d.dropFirst(take)
            if pending.count < 16 { return }
            let full = pending
            full.withUnsafeBufferPointer { blocks($0.baseAddress!, 1, hibit: 1 << 24) }
            pending.removeAll(keepingCapacity: true)
        }
        let n = d.count / 16
        if n > 0 { d.withUnsafeBufferPointer { blocks($0.baseAddress!, n, hibit: 1 << 24) } }
        pending.append(contentsOf: d.dropFirst(n * 16))
    }

    func finalize() -> [UInt8] {
        var c = self
        if !c.pending.isEmpty {
            var last = c.pending
            last.append(1)
            last.append(contentsOf: [UInt8](repeating: 0, count: 16 - last.count))
            last.withUnsafeBufferPointer { c.blocks($0.baseAddress!, 1, hibit: 0) }
        }
        let mask: UInt64 = 0x3ff_ffff
        var a0 = c.h0, a1 = c.h1, a2 = c.h2, a3 = c.h3, a4 = c.h4
        // Full carry.
        a2 &+= a1 >> 26; a1 &= mask
        a3 &+= a2 >> 26; a2 &= mask
        a4 &+= a3 >> 26; a3 &= mask
        a0 &+= (a4 >> 26) &* 5; a4 &= mask
        a1 &+= a0 >> 26; a0 &= mask
        // g = h + 5 - 2^130; use it if it didn't go negative.
        var g0 = a0 &+ 5
        var g1 = a1 &+ (g0 >> 26); g0 &= mask
        var g2 = a2 &+ (g1 >> 26); g1 &= mask
        var g3 = a3 &+ (g2 >> 26); g2 &= mask
        var g4 = a4 &+ (g3 >> 26) &- (1 << 26); g3 &= mask
        let useG = (g4 >> 63) &- 1          // all ones if g4 >= 0
        g4 &= mask
        a0 = (a0 & ~useG) | (g0 & useG); a1 = (a1 & ~useG) | (g1 & useG)
        a2 = (a2 & ~useG) | (g2 & useG); a3 = (a3 & ~useG) | (g3 & useG)
        a4 = (a4 & ~useG) | (g4 & useG)
        var h = UInt128(a0) | UInt128(a1) << 26 | UInt128(a2) << 52 | UInt128(a3) << 78 | UInt128(a4) &<< 104
        h = h &+ c.pad
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { out[i] = UInt8(truncatingIfNeeded: h >> (UInt128(i) * 8)) }
        return out
    }

    static func mac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var p = Poly1305(key: key)
        p.update(message)
        return p.finalize()
    }
}

struct ChaCha20Poly1305: CryptoAEAD {
    static var keySize: Int { 32 }
    let key: ChaCha20Key

    init?(key: [UInt8]) {
        guard key.count == 32 else { return nil }
        self.key = ChaCha20Key(key)
    }

    private func tag(_ nonce: [UInt8], _ aad: [UInt8], _ ct: ArraySlice<UInt8>) -> [UInt8] {
        let n = ChaCha20.nonceWords(nonce)
        var otk = [UInt8](repeating: 0, count: 64)
        otk.withUnsafeMutableBufferPointer { ChaCha20.block(key, n.0, n.1, n.2, 0, $0.baseAddress!) }
        var p = Poly1305(key: Array(otk[0..<32]))
        let zeros = [UInt8](repeating: 0, count: 16)
        p.update(aad); p.update(zeros[0..<((16 - aad.count % 16) % 16)])
        p.update(ct); p.update(zeros[0..<((16 - ct.count % 16) % 16)])
        var lens: [UInt8] = []
        cryptoAppend64LE(&lens, UInt64(aad.count))
        cryptoAppend64LE(&lens, UInt64(ct.count))
        p.update(lens)
        return p.finalize()
    }

    func seal(nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> [UInt8] {
        var c = ChaCha20.xor(key, nonce, 1, plaintext[...])
        c.append(contentsOf: tag(nonce, aad, c[...]))
        return c
    }

    func open(nonce: [UInt8], aad: [UInt8], ciphertextAndTag: [UInt8]) -> [UInt8]? {
        guard nonce.count == 12, ciphertextAndTag.count >= 16 else { return nil }
        let n = ciphertextAndTag.count - 16
        let want = tag(nonce, aad, ciphertextAndTag[0..<n])
        guard cryptoEqual(want, Array(ciphertextAndTag[n...])) else { return nil }
        return ChaCha20.xor(key, nonce, 1, ciphertextAndTag[0..<n])
    }
}
