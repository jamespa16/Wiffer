// HMAC (RFC 2104) and HKDF (RFC 5869), generic over the hash.
//
//   HMAC<SHA256>.mac(key: k, message: m)       -> 32 bytes
//   var m = HMAC<SHA384>(key: k); m.update(x); m.finalize()
//   HKDF<SHA256>.extract(salt: s, ikm: k)      -> PRK (digestSize bytes)
//   HKDF<SHA256>.expand(prk: p, info: i, length: n) -> n bytes, or nil if
//                                                  n > 255 * digestSize
//   HKDF<SHA256>.expandLabel(secret:label:context:length:)
//       TLS 1.3 HKDF-Expand-Label (RFC 8446 section 7.1); the label is
//       given without the "tls13 " prefix, e.g. "key", "iv", "finished".
//   HKDF<SHA256>.deriveSecret(secret:label:transcriptHash:)
//       Derive-Secret with the transcript hash already computed.

struct HMAC<H: CryptoHash> {
    private var inner: H
    private var outerKey: [UInt8]

    init(key: [UInt8]) {
        var k = key.count > H.blockSize ? H.hash(key) : key
        k.append(contentsOf: [UInt8](repeating: 0, count: H.blockSize - k.count))
        var ipad = k, opad = k
        for i in 0..<k.count { ipad[i] ^= 0x36; opad[i] ^= 0x5c }
        inner = H()
        inner.update(ipad)
        outerKey = opad
    }

    mutating func update(_ data: [UInt8]) { inner.update(data) }
    mutating func update(_ data: ArraySlice<UInt8>) { inner.update(data) }

    func finalize() -> [UInt8] {
        var outer = H()
        outer.update(outerKey)
        outer.update(inner.finalize())
        return outer.finalize()
    }

    static func mac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var m = HMAC(key: key)
        m.update(message)
        return m.finalize()
    }
}

enum HKDF<H: CryptoHash> {
    static func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] {
        HMAC<H>.mac(key: salt.isEmpty ? [UInt8](repeating: 0, count: H.digestSize) : salt, message: ikm)
    }

    static func expand(prk: [UInt8], info: [UInt8], length: Int) -> [UInt8]? {
        guard length >= 0, length <= 255 * H.digestSize else { return nil }
        let base = HMAC<H>(key: prk)
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var t: [UInt8] = []
        var counter: UInt8 = 1
        while out.count < length {
            var m = base
            m.update(t)
            m.update(info)
            m.update([counter])
            t = m.finalize()
            out.append(contentsOf: t.prefix(length - out.count))
            counter &+= 1
        }
        return out
    }

    /// HKDF-Expand-Label: HkdfLabel = length(2) || "tls13 " + label (1-byte
    /// length) || context (1-byte length). nil if a field is too long.
    static func expandLabel(secret: [UInt8], label: String, context: [UInt8], length: Int) -> [UInt8]? {
        let full = Array("tls13 ".utf8) + Array(label.utf8)
        guard length >= 0, length <= 0xffff, full.count <= 255, context.count <= 255 else { return nil }
        var info: [UInt8] = [UInt8(length >> 8), UInt8(length & 0xff), UInt8(full.count)]
        info.append(contentsOf: full)
        info.append(UInt8(context.count))
        info.append(contentsOf: context)
        return expand(prk: secret, info: info, length: length)
    }

    static func deriveSecret(secret: [UInt8], label: String, transcriptHash: [UInt8]) -> [UInt8]? {
        expandLabel(secret: secret, label: label, context: transcriptHash, length: H.digestSize)
    }
}
