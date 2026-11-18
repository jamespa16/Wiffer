// ChaChaDRBG: a ChaCha20 "fast key erasure" generator (the construction
// used by OpenBSD arc4random and Linux's getrandom pool output) for the
// kernel's getrandom and for user-space key generation.
//
//   var rng = ChaChaDRBG(seed: entropy)     // seeding is the caller's job:
//                                           // RDSEED/RDRAND, jitter, ...
//   rng.reseed(moreEntropy)                 // mix in more at any time
//   rng.generate(32) -> [UInt8]
//   rng.fill(buffer)                        // UnsafeMutableRawBufferPointer
//
// Each request runs ChaCha20 under the current key (zero nonce, counter
// from 0); the first 32 bytes of keystream replace the key before any
// output is released, so a later compromise of the state reveals nothing
// about earlier output. Seeds and reseeds are hashed into the key with
// SHA-256 (key = SHA-256(key || input)). Not thread-safe: the kernel wraps
// it in a lock.

struct ChaChaDRBG {
    private var key: ChaCha20Key
    private var requests: UInt64 = 0

    init(seed: [UInt8]) {
        key = ChaCha20Key(SHA256.hash(seed))
    }

    mutating func reseed(_ input: [UInt8]) {
        key = ChaCha20Key(SHA256.hash(keyBytes + input))
    }

    private var keyBytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let k = key.k
        let w = [k.0, k.1, k.2, k.3, k.4, k.5, k.6, k.7]
        out.withUnsafeMutableBufferPointer { p in
            for i in 0..<8 { cryptoStore32LE(p.baseAddress! + 4 * i, w[i]) }
        }
        return out
    }

    /// Fill `buffer` with output (any length up to 256 GiB per call).
    mutating func fill(_ buffer: UnsafeMutableRawBufferPointer) {
        requests &+= 1
        let n = buffer.count
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { block in
            let b = block.baseAddress!
            // Block 0: the first 32 bytes are the next key, the rest is output.
            ChaCha20.block(key, 0, 0, 0, 0, b)
            var w = [UInt32](repeating: 0, count: 8)
            for i in 0..<8 { w[i] = cryptoLoad32LE(b + 4 * i) }
            let current = key
            key = ChaCha20Key(words: w)
            var off = 0
            let first = min(32, n)
            for i in 0..<first { buffer[off + i] = b[32 + i] }
            off += first
            var counter: UInt32 = 1
            while off < n {
                ChaCha20.block(current, 0, 0, 0, counter, b)
                let m = min(64, n - off)
                for i in 0..<m { buffer[off + i] = b[i] }
                off += m
                counter &+= 1
            }
            for i in 0..<64 { b[i] = 0 }
        }
    }

    mutating func generate(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(count, 0))
        out.withUnsafeMutableBytes { fill($0) }
        return out
    }
}
