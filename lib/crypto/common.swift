// lib/crypto: pure-Swift cryptographic primitives for TLS 1.3 and X.509
// (ROADMAP Phase 8A). Written for Wiffer, not ported; see ROADMAP.md for
// the survey. Hobby-OS crypto: constant-time is a goal, not a guarantee.
//
// API shared by every file:
//
//   protocol CryptoHash          SHA256, SHA384, SHA512 (sha2.swift)
//     static digestSize, blockSize
//     init(); mutating update(_: [UInt8] / ArraySlice / UnsafeRawBufferPointer)
//     finalize() -> [UInt8]     non-mutating: a copy of the state keeps
//                               going, so a TLS transcript hash can be
//                               snapshotted with `let h = transcript.finalize()`
//     static hash(_:) -> [UInt8]
//   enum CryptoHashAlgorithm     .sha256 / .sha384 / .sha512 chosen at run
//                               time (signature algorithms in X.509 / TLS)
//   cryptoEqual(a, b)            constant-time comparison (length may leak)
//   protocol CryptoAEAD          AESGCM, ChaCha20Poly1305 (generic, no `any`)

protocol CryptoHash {
    static var digestSize: Int { get }
    static var blockSize: Int { get }
    init()
    mutating func update(_ data: UnsafeRawBufferPointer)
    /// The digest of everything so far; the state is left as it was.
    func finalize() -> [UInt8]
}

extension CryptoHash {
    mutating func update(_ data: [UInt8]) { data.withUnsafeBytes { update($0) } }
    mutating func update(_ data: ArraySlice<UInt8>) { data.withUnsafeBytes { update($0) } }
    static func hash(_ data: [UInt8]) -> [UInt8] {
        var h = Self()
        h.update(data)
        return h.finalize()
    }
}

/// A hash picked at run time (from a signature algorithm identifier).
enum CryptoHashAlgorithm: Equatable {
    case sha256, sha384, sha512

    var digestSize: Int {
        switch self {
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        }
    }

    func hash(_ data: [UInt8]) -> [UInt8] {
        switch self {
        case .sha256: return SHA256.hash(data)
        case .sha384: return SHA384.hash(data)
        case .sha512: return SHA512.hash(data)
        }
    }
}

/// An authenticated cipher with a 12-byte nonce and a 16-byte tag.
/// `seal` returns ciphertext || tag; `open` takes the same and returns the
/// plaintext, or nil if the tag doesn't match (nothing is released then).
protocol CryptoAEAD {
    static var keySize: Int { get }
    init?(key: [UInt8])
    func seal(nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> [UInt8]
    func open(nonce: [UInt8], aad: [UInt8], ciphertextAndTag: [UInt8]) -> [UInt8]?
}

let cryptoAEADTagSize = 16
let cryptoAEADNonceSize = 12

/// Constant-time equality of two byte strings (the lengths are not secret).
func cryptoEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var d: UInt8 = 0
    for i in 0..<a.count { d |= a[i] ^ b[i] }
    return d == 0
}

@inline(__always) func cryptoRotr32(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x &>> n) | (x &<< (32 &- n))
}

@inline(__always) func cryptoRotl32(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x &<< n) | (x &>> (32 &- n))
}

@inline(__always) func cryptoRotr64(_ x: UInt64, _ n: UInt64) -> UInt64 {
    (x &>> n) | (x &<< (64 &- n))
}

@inline(__always) func cryptoLoad32BE(_ p: UnsafePointer<UInt8>) -> UInt32 {
    UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
}

@inline(__always) func cryptoLoad32LE(_ p: UnsafePointer<UInt8>) -> UInt32 {
    UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
}

@inline(__always) func cryptoLoad64BE(_ p: UnsafePointer<UInt8>) -> UInt64 {
    UInt64(cryptoLoad32BE(p)) << 32 | UInt64(cryptoLoad32BE(p + 4))
}

@inline(__always) func cryptoStore32BE(_ p: UnsafeMutablePointer<UInt8>, _ v: UInt32) {
    p[0] = UInt8(truncatingIfNeeded: v >> 24); p[1] = UInt8(truncatingIfNeeded: v >> 16)
    p[2] = UInt8(truncatingIfNeeded: v >> 8); p[3] = UInt8(truncatingIfNeeded: v)
}

@inline(__always) func cryptoStore32LE(_ p: UnsafeMutablePointer<UInt8>, _ v: UInt32) {
    p[0] = UInt8(truncatingIfNeeded: v); p[1] = UInt8(truncatingIfNeeded: v >> 8)
    p[2] = UInt8(truncatingIfNeeded: v >> 16); p[3] = UInt8(truncatingIfNeeded: v >> 24)
}

@inline(__always) func cryptoStore64BE(_ p: UnsafeMutablePointer<UInt8>, _ v: UInt64) {
    cryptoStore32BE(p, UInt32(truncatingIfNeeded: v >> 32))
    cryptoStore32BE(p + 4, UInt32(truncatingIfNeeded: v))
}

func cryptoAppend64BE(_ out: inout [UInt8], _ v: UInt64) {
    for i in (0..<8).reversed() { out.append(UInt8(truncatingIfNeeded: v >> (UInt64(i) * 8))) }
}

func cryptoAppend64LE(_ out: inout [UInt8], _ v: UInt64) {
    for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> (UInt64(i) * 8))) }
}
