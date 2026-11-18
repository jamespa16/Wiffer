// AES-128/192/256 (FIPS 197, encryption only) and AES-GCM (NIST SP 800-38D).
//
//   let aes = AES(key: k)!                 // 16, 24 or 32 bytes
//   aes.encryptBlock(input, output)        // 16-byte blocks, raw pointers
//   let g = AESGCM(key: k)!                // CryptoAEAD
//   let sealed = g.seal(nonce: n12, aad: a, plaintext: p)   // ct || tag
//   let plain = g.open(nonce: n12, aad: a, ciphertextAndTag: sealed)  // nil if forged
//
// TLS only needs the forward cipher (GCM is CTR mode), so there is no
// decryptBlock. AES here is table-based (one 1 KiB T-table, rotated): fast
// in software but not constant-time against cache-timing attackers; AES-NI
// is the later fix. GHASH is constant-time: carry-less multiplication
// with integer multiplies on bit-masked operands (the "holes" trick
// described by Thomas Pornin for BearSSL's ghash_ctmul64; this code is an
// independent implementation of it).

struct AES {
    let roundKeys: [UInt32]
    let rounds: Int

    init?(key: [UInt8]) {
        guard key.count == 16 || key.count == 24 || key.count == 32 else { return nil }
        let nk = key.count / 4
        rounds = nk + 6
        let total = 4 * (rounds + 1)
        var w = [UInt32](repeating: 0, count: total)
        key.withUnsafeBufferPointer { k in
            for i in 0..<nk { w[i] = cryptoLoad32BE(k.baseAddress! + 4 * i) }
        }
        var rcon: UInt32 = 1
        for i in nk..<total {
            var t = w[i - 1]
            if i % nk == 0 {
                t = aesSubWord(cryptoRotl32(t, 8)) ^ (rcon << 24)
                rcon = (rcon << 1) ^ ((rcon >> 7) * 0x11b)
            } else if nk > 6 && i % nk == 4 {
                t = aesSubWord(t)
            }
            w[i] = w[i - nk] ^ t
        }
        roundKeys = w
    }

    func encryptBlock(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>) {
        let nr = rounds
        roundKeys.withUnsafeBufferPointer { rk in
            aesTe0.withUnsafeBufferPointer { te in
                aesSBox.withUnsafeBufferPointer { sb in
                    var s0 = cryptoLoad32BE(input) ^ rk[0]
                    var s1 = cryptoLoad32BE(input + 4) ^ rk[1]
                    var s2 = cryptoLoad32BE(input + 8) ^ rk[2]
                    var s3 = cryptoLoad32BE(input + 12) ^ rk[3]
                    @inline(__always) func t(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
                        te[Int(a >> 24)] ^ cryptoRotr32(te[Int((b >> 16) & 0xff)], 8)
                            ^ cryptoRotr32(te[Int((c >> 8) & 0xff)], 16) ^ cryptoRotr32(te[Int(d & 0xff)], 24)
                    }
                    var r = 1
                    while r < nr {
                        let k = 4 * r
                        let t0 = t(s0, s1, s2, s3) ^ rk[k]
                        let t1 = t(s1, s2, s3, s0) ^ rk[k + 1]
                        let t2 = t(s2, s3, s0, s1) ^ rk[k + 2]
                        let t3 = t(s3, s0, s1, s2) ^ rk[k + 3]
                        s0 = t0; s1 = t1; s2 = t2; s3 = t3
                        r += 1
                    }
                    @inline(__always) func f(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
                        UInt32(sb[Int(a >> 24)]) << 24 | UInt32(sb[Int((b >> 16) & 0xff)]) << 16
                            | UInt32(sb[Int((c >> 8) & 0xff)]) << 8 | UInt32(sb[Int(d & 0xff)])
                    }
                    let k = 4 * nr
                    cryptoStore32BE(output, f(s0, s1, s2, s3) ^ rk[k])
                    cryptoStore32BE(output + 4, f(s1, s2, s3, s0) ^ rk[k + 1])
                    cryptoStore32BE(output + 8, f(s2, s3, s0, s1) ^ rk[k + 2])
                    cryptoStore32BE(output + 12, f(s3, s0, s1, s2) ^ rk[k + 3])
                }
            }
        }
    }

    /// Convenience for tests: one 16-byte block.
    func encrypt(block: [UInt8]) -> [UInt8] {
        precondition(block.count == 16)
        var out = [UInt8](repeating: 0, count: 16)
        block.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in encryptBlock(i.baseAddress!, o.baseAddress!) }
        }
        return out
    }
}

func aesSubWord(_ w: UInt32) -> UInt32 {
    aesSBox.withUnsafeBufferPointer { sb in
        UInt32(sb[Int(w >> 24)]) << 24 | UInt32(sb[Int((w >> 16) & 0xff)]) << 16
            | UInt32(sb[Int((w >> 8) & 0xff)]) << 8 | UInt32(sb[Int(w & 0xff)])
    }
}

// MARK: GHASH

@inline(__always) func cryptoRev64(_ v: UInt64) -> UInt64 {
    var x = v
    x = ((x >> 1) & 0x5555_5555_5555_5555) | ((x & 0x5555_5555_5555_5555) << 1)
    x = ((x >> 2) & 0x3333_3333_3333_3333) | ((x & 0x3333_3333_3333_3333) << 2)
    x = ((x >> 4) & 0x0f0f_0f0f_0f0f_0f0f) | ((x & 0x0f0f_0f0f_0f0f_0f0f) << 4)
    return x.byteSwapped
}

/// Low 64 bits of the carry-less product x * y. Each operand is split into
/// four interleaved bit classes, so every column of an integer product
/// sums at most 15 ones below bit 60 (16 at bit 60, whose carry falls off
/// the top), and the carries never reach the next bit of the same class.
@inline(__always) func cryptoBMul64(_ x: UInt64, _ y: UInt64) -> UInt64 {
    let m0: UInt64 = 0x1111_1111_1111_1111, m1: UInt64 = 0x2222_2222_2222_2222
    let m2: UInt64 = 0x4444_4444_4444_4444, m3: UInt64 = 0x8888_8888_8888_8888
    let x0 = x & m0, x1 = x & m1, x2 = x & m2, x3 = x & m3
    let y0 = y & m0, y1 = y & m1, y2 = y & m2, y3 = y & m3
    var z0 = (x0 &* y0) ^ (x1 &* y3) ^ (x2 &* y2) ^ (x3 &* y1)
    var z1 = (x0 &* y1) ^ (x1 &* y0) ^ (x2 &* y3) ^ (x3 &* y2)
    var z2 = (x0 &* y2) ^ (x1 &* y1) ^ (x2 &* y0) ^ (x3 &* y3)
    var z3 = (x0 &* y3) ^ (x1 &* y2) ^ (x2 &* y1) ^ (x3 &* y0)
    z0 &= m0; z1 &= m1; z2 &= m2; z3 &= m3
    return z0 | z1 | z2 | z3
}

/// GHASH over GF(2^128). Field elements are kept in "normal" order
/// (bit i of (lo, hi) is the coefficient of x^i), which is the bit
/// reversal of GCM's byte order.
struct GHASH {
    let h0, h1, h01: UInt64           // H
    let r0, r1, r01: UInt64           // bit-reversed H words
    var y0: UInt64 = 0, y1: UInt64 = 0

    init(h: [UInt8]) {
        var a: UInt64 = 0, b: UInt64 = 0
        h.withUnsafeBufferPointer { p in
            a = cryptoRev64(cryptoLoad64BE(p.baseAddress!))
            b = cryptoRev64(cryptoLoad64BE(p.baseAddress! + 8))
        }
        h0 = a; h1 = b; h01 = a ^ b
        r0 = cryptoRev64(a); r1 = cryptoRev64(b); r01 = r0 ^ r1
    }

    @inline(__always) static func clmul(_ x: UInt64, _ y: UInt64, _ yr: UInt64) -> (UInt64, UInt64) {
        let lo = cryptoBMul64(x, y)
        let hi = cryptoRev64(cryptoBMul64(cryptoRev64(x), yr)) >> 1
        return (lo, hi)
    }

    /// y = (y ^ block) * H
    mutating func absorb(_ p: UnsafePointer<UInt8>) {
        let a0 = y0 ^ cryptoRev64(cryptoLoad64BE(p))
        let a1 = y1 ^ cryptoRev64(cryptoLoad64BE(p + 8))
        let (p0l, p0h) = GHASH.clmul(a0, h0, r0)
        let (p2l, p2h) = GHASH.clmul(a1, h1, r1)
        var (p1l, p1h) = GHASH.clmul(a0 ^ a1, h01, r01)
        p1l ^= p0l ^ p2l; p1h ^= p0h ^ p2h
        var z0 = p0l, z1 = p0h ^ p1l, z2 = p2l ^ p1h
        let z3 = p2h
        // Reduce modulo x^128 + x^7 + x^2 + x + 1.
        z1 ^= z3 ^ (z3 << 1) ^ (z3 << 2) ^ (z3 << 7)
        z2 ^= (z3 >> 63) ^ (z3 >> 62) ^ (z3 >> 57)
        z0 ^= z2 ^ (z2 << 1) ^ (z2 << 2) ^ (z2 << 7)
        z1 ^= (z2 >> 63) ^ (z2 >> 62) ^ (z2 >> 57)
        y0 = z0; y1 = z1
    }

    /// Absorb bytes, zero-padding the last partial block.
    mutating func absorbPadded(_ data: UnsafeBufferPointer<UInt8>) {
        guard let base = data.baseAddress else { return }
        let full = data.count / 16
        for i in 0..<full { absorb(base + 16 * i) }
        let rest = data.count - 16 * full
        if rest > 0 {
            var last = [UInt8](repeating: 0, count: 16)
            for i in 0..<rest { last[i] = base[16 * full + i] }
            last.withUnsafeBufferPointer { absorb($0.baseAddress!) }
        }
    }

    mutating func absorbLengths(_ aBytes: Int, _ cBytes: Int) {
        var l = [UInt8](repeating: 0, count: 16)
        l.withUnsafeMutableBufferPointer { p in
            cryptoStore64BE(p.baseAddress!, UInt64(aBytes) &* 8)
            cryptoStore64BE(p.baseAddress! + 8, UInt64(cBytes) &* 8)
        }
        l.withUnsafeBufferPointer { absorb($0.baseAddress!) }
    }

    var digest: [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        out.withUnsafeMutableBufferPointer { p in
            cryptoStore64BE(p.baseAddress!, cryptoRev64(y0))
            cryptoStore64BE(p.baseAddress! + 8, cryptoRev64(y1))
        }
        return out
    }
}

// MARK: GCM

struct AESGCM: CryptoAEAD {
    static var keySize: Int { 16 }   // AES-128; AES-256 keys (32 bytes) work too
    let aes: AES
    let ghashKey: [UInt8]

    init?(key: [UInt8]) {
        guard let a = AES(key: key) else { return nil }
        aes = a
        ghashKey = a.encrypt(block: [UInt8](repeating: 0, count: 16))
    }

    private func j0(_ nonce: [UInt8]) -> [UInt8] {
        if nonce.count == 12 { return nonce + [0, 0, 0, 1] }
        var g = GHASH(h: ghashKey)
        nonce.withUnsafeBufferPointer { g.absorbPadded($0) }
        g.absorbLengths(0, nonce.count)
        return g.digest
    }

    /// CTR keystream XOR from counter block inc32(j0) on.
    private func ctr(_ j0: [UInt8], _ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count)
        var ctrBlock = j0
        var ks = [UInt8](repeating: 0, count: 16)
        var c = UInt32(j0[12]) << 24 | UInt32(j0[13]) << 16 | UInt32(j0[14]) << 8 | UInt32(j0[15])
        input.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                ctrBlock.withUnsafeMutableBufferPointer { cb in
                    ks.withUnsafeMutableBufferPointer { k in
                        var off = 0
                        let n = inp.count
                        while off < n {
                            c &+= 1
                            cryptoStore32BE(cb.baseAddress! + 12, c)
                            aes.encryptBlock(cb.baseAddress!, k.baseAddress!)
                            let m = min(16, n - off)
                            for i in 0..<m { o[off + i] = inp[off + i] ^ k[i] }
                            off += m
                        }
                    }
                }
            }
        }
        return out
    }

    private func tag(_ j0: [UInt8], _ aad: [UInt8], _ ct: ArraySlice<UInt8>) -> [UInt8] {
        var g = GHASH(h: ghashKey)
        aad.withUnsafeBufferPointer { g.absorbPadded($0) }
        ct.withUnsafeBufferPointer { g.absorbPadded($0) }
        g.absorbLengths(aad.count, ct.count)
        var t = g.digest
        let e = aes.encrypt(block: j0)
        for i in 0..<16 { t[i] ^= e[i] }
        return t
    }

    func seal(nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> [UInt8] {
        let j = j0(nonce)
        var c = ctr(j, plaintext)
        c.append(contentsOf: tag(j, aad, c[...]))
        return c
    }

    func open(nonce: [UInt8], aad: [UInt8], ciphertextAndTag: [UInt8]) -> [UInt8]? {
        guard ciphertextAndTag.count >= 16 else { return nil }
        let n = ciphertextAndTag.count - 16
        let j = j0(nonce)
        let want = tag(j, aad, ciphertextAndTag[0..<n])
        guard cryptoEqual(want, Array(ciphertextAndTag[n...])) else { return nil }
        return ctr(j, Array(ciphertextAndTag[0..<n]))
    }
}
