// RSA signature verification (RFC 8017): RSASSA-PKCS1-v1_5 and RSASSA-PSS
// with MGF1, for X.509 chains (mostly PKCS#1 v1.5) and TLS 1.3
// CertificateVerify (rsa_pss_rsae_*; salt length = hash length).
//
//   let key = RSAPublicKey(modulus: nBytes, exponent: eBytes)
//       big-endian unsigned integers (DER INTEGER contents are fine:
//       leading zeros are stripped). nil unless 1024 <= bits <= 4096, n odd,
//       e odd, 1 < e < n.
//   key.verifyPKCS1v15(signature: s, digest: h, hash: .sha256) -> Bool
//       h is the message digest; the DigestInfo encoding is built here and
//       compared as a whole (no parsing of the decrypted block).
//   key.verifyPSS(signature: s, digest: h, hash: .sha256, saltLength: nil)
//       saltLength nil means the digest length (what TLS 1.3 requires).
//   key.publicOperation(signature:) -> EM bytes?   s^e mod n, k bytes
//
// The signature must be exactly as long as the modulus (RFC 8017 8.2.2).

struct RSAPublicKey {
    static let minimumBits = 1024
    static let maximumBits = 4096

    let modulus: CryptoBigInt
    let exponent: [UInt64]
    let bitLength: Int
    let byteCount: Int
    let mont: CryptoMontgomery

    init?(modulus nBytes: [UInt8], exponent eBytes: [UInt8]) {
        let nb = Array(nBytes.drop(while: { $0 == 0 }))
        let eb = Array(eBytes.drop(while: { $0 == 0 }))
        guard !nb.isEmpty, nb.count <= RSAPublicKey.maximumBits / 8, !eb.isEmpty, eb.count <= nb.count else { return nil }
        let n = CryptoBigInt(bytes: nb)
        let bits = n.bitLength
        guard bits >= RSAPublicKey.minimumBits, bits <= RSAPublicKey.maximumBits, n.limbs[0] & 1 == 1 else { return nil }
        let e = CryptoBigInt(bytes: eb, limbCount: n.limbs.count)
        guard e.limbs[0] & 1 == 1, e.bitLength > 1, CryptoBigInt.compare(e.limbs, n.limbs) < 0,
              let m = CryptoMontgomery(modulus: n) else { return nil }
        modulus = n
        exponent = e.limbs
        bitLength = bits
        byteCount = (bits + 7) / 8
        mont = m
    }

    /// s^e mod n as byteCount bytes, or nil if s has the wrong length or s >= n.
    func publicOperation(signature: [UInt8]) -> [UInt8]? {
        guard signature.count == byteCount else { return nil }
        let s = CryptoBigInt(bytes: signature, limbCount: mont.limbs).limbs
        guard mont.isReduced(s) else { return nil }
        let m = mont.fromMont(mont.pow(mont.toMont(s), exponent))
        return CryptoBigInt(limbs: m).bytes(count: byteCount)
    }

    static func digestInfoPrefix(_ hash: CryptoHashAlgorithm) -> [UInt8] {
        let oidLast: UInt8
        switch hash {
        case .sha256: oidLast = 1
        case .sha384: oidLast = 2
        case .sha512: oidLast = 3
        }
        let h = UInt8(hash.digestSize)
        return [0x30, 0x11 + h, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, oidLast,
                0x05, 0x00, 0x04, h]
    }

    func verifyPKCS1v15(signature: [UInt8], digest: [UInt8], hash: CryptoHashAlgorithm) -> Bool {
        guard digest.count == hash.digestSize, let em = publicOperation(signature: signature) else { return false }
        let t = RSAPublicKey.digestInfoPrefix(hash) + digest
        guard byteCount >= t.count + 11 else { return false }
        var want: [UInt8] = [0x00, 0x01]
        want.append(contentsOf: [UInt8](repeating: 0xff, count: byteCount - t.count - 3))
        want.append(0x00)
        want.append(contentsOf: t)
        return cryptoEqual(em, want)
    }

    func verifyPSS(signature: [UInt8], digest: [UInt8], hash: CryptoHashAlgorithm, saltLength: Int? = nil) -> Bool {
        let hLen = hash.digestSize
        let sLen = saltLength ?? hLen
        guard digest.count == hLen, sLen >= 0, var em = publicOperation(signature: signature) else { return false }
        let emBits = bitLength - 1
        let emLen = (emBits + 7) / 8
        if em.count > emLen {             // emBits a multiple of 8: leading zero byte
            guard em[0] == 0 else { return false }
            em.removeFirst()
        }
        guard emLen >= hLen + sLen + 2, em.count == emLen, em[emLen - 1] == 0xbc else { return false }
        let dbLen = emLen - hLen - 1
        let topMask: UInt8 = 0xff >> UInt8(8 * emLen - emBits)
        guard em[0] & ~topMask == 0 else { return false }
        let h = Array(em[dbLen..<(dbLen + hLen)])
        var db = Array(em[0..<dbLen])
        let mask = rsaMGF1(seed: h, length: dbLen, hash: hash)
        for i in 0..<dbLen { db[i] ^= mask[i] }
        db[0] &= topMask
        let zeros = dbLen - sLen - 1
        var bad: UInt8 = 0
        for i in 0..<zeros { bad |= db[i] }
        bad |= db[zeros] ^ 0x01
        guard bad == 0 else { return false }
        let salt = Array(db[(dbLen - sLen)...])
        let mPrime = [UInt8](repeating: 0, count: 8) + digest + salt
        return cryptoEqual(hash.hash(mPrime), h)
    }
}

/// MGF1 (RFC 8017 B.2.1).
func rsaMGF1(seed: [UInt8], length: Int, hash: CryptoHashAlgorithm) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(length + hash.digestSize)
    var counter: UInt32 = 0
    while out.count < length {
        let c: [UInt8] = [UInt8(truncatingIfNeeded: counter >> 24), UInt8(truncatingIfNeeded: counter >> 16),
                          UInt8(truncatingIfNeeded: counter >> 8), UInt8(truncatingIfNeeded: counter)]
        out.append(contentsOf: hash.hash(seed + c))
        counter &+= 1
    }
    return Array(out[0..<length])
}
