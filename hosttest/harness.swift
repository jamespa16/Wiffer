// The host test harness shared by every lib's tests (hosttest.sh).
//
// Each lib/<name>/tests/*.swift defines exactly one entry point,
//     func libTests(_ t: Tests)
// which the runner calls. Tests run from the repository root, so fixtures
// are read with paths like "lib/<name>/fixtures/foo.bin".

final class Tests {
    let lib: String
    var passed = 0
    var failed = 0
    var group = ""

    init(lib: String) { self.lib = lib }

    /// Label the checks that follow (shown in failure lines).
    func section(_ name: String) { group = name; host_guard_label("\(lib): \(name)") }

    func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        if ok { passed += 1; return }
        failed += 1
        let where_ = group.isEmpty ? "" : "\(group): "
        print("FAIL \(lib): \(where_)\(label)\(detail.isEmpty ? "" : " (\(detail))")")
    }

    func equal<T: Equatable>(_ got: T, _ want: T, _ label: String) {
        check(got == want, label)
    }

    func equal(_ got: String, _ want: String, _ label: String) {
        check(got == want, label, "got \"\(got)\", want \"\(want)\"")
    }

    func equal(_ got: Int, _ want: Int, _ label: String) {
        check(got == want, label, "got \(got), want \(want)")
    }

    func equal(_ got: [UInt8], _ want: [UInt8], _ label: String) {
        check(got == want, label, "got \(hex(got.prefix(48))), want \(hex(want.prefix(48)))")
    }

    /// The whole file, or nil (and a failure) if it can't be read.
    func readFile(_ path: String) -> [UInt8]? {
        let data = hostReadFile(path)
        if data == nil { check(false, "read \(path)") }
        return data
    }

    /// Like readFile, but a missing file is not a failure.
    func readFileIfPresent(_ path: String) -> [UInt8]? { hostReadFile(path) }

    /// Simple mutation fuzzer: `iterations` mutants of each seed (bit flips,
    /// byte sets, truncation, duplication and splicing between seeds) are fed
    /// to `body`, deterministically. A crash fails the whole run; so does a
    /// runaway allocation (the body should enforce its own limits).
    func fuzz(_ name: String, seeds: [[UInt8]], iterations: Int, _ body: ([UInt8]) -> Void) {
        var rng = TestRandom(seed: 0x5eed_0000 &+ UInt64(truncatingIfNeeded: name.utf8.count))
        for s in seeds { body(s) }
        guard !seeds.isEmpty else { return }
        for _ in 0..<iterations {
            var m = seeds[rng.below(seeds.count)]
            let ops = 1 + rng.below(4)
            for _ in 0..<ops {
                switch rng.below(6) {
                case 0 where !m.isEmpty: // flip a bit
                    let i = rng.below(m.count); m[i] ^= UInt8(1 << rng.below(8))
                case 1 where !m.isEmpty: // set an interesting byte
                    let vals: [UInt8] = [0, 1, 0x7f, 0x80, 0xff, 0x3c, 0x3e, 0x22, 0x26, 0x0a]
                    m[rng.below(m.count)] = vals[rng.below(vals.count)]
                case 2: // truncate
                    m = Array(m.prefix(rng.below(m.count + 1)))
                case 3 where !m.isEmpty: // duplicate a chunk
                    let a = rng.below(m.count), n = min(m.count - a, 1 + rng.below(64))
                    m.insert(contentsOf: m[a..<(a + n)], at: rng.below(m.count + 1))
                case 4: // splice with another seed
                    let o = seeds[rng.below(seeds.count)]
                    let cut = rng.below(m.count + 1), from = rng.below(o.count + 1)
                    m = Array(m.prefix(cut)) + Array(o[from...])
                default: // 16-bit/32-bit length-ish values
                    if m.count >= 2 {
                        let i = rng.below(m.count - 1)
                        m[i] = 0xff; m[i + 1] = UInt8(truncatingIfNeeded: rng.next())
                    }
                }
            }
            body(m)
        }
        passed += 1
    }
}

/// splitmix64, for tests and the fuzzer (deterministic).
struct TestRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}

func hex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    let digits: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
    var s = ""
    for b in bytes { s.append(digits[Int(b >> 4)]); s.append(digits[Int(b & 15)]) }
    return s
}

/// Hex string (whitespace ignored) to bytes, for test vectors.
func unhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var hi: UInt8? = nil
    for c in s.utf8 {
        let v: UInt8
        switch c {
        case 0x30...0x39: v = c - 0x30
        case 0x61...0x66: v = c - 0x61 + 10
        case 0x41...0x46: v = c - 0x41 + 10
        default: continue
        }
        if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
    }
    return out
}

func hostReadFile(_ path: String) -> [UInt8]? {
    guard let f = fopen(path, "rb") else { return nil }
    defer { fclose(f) }
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = buf.withUnsafeMutableBytes { fread($0.baseAddress, 1, 65536, f) }
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

/// Write a file (for dumping actual output next to an expected fixture).
func hostWriteFile(_ path: String, _ bytes: [UInt8]) -> Bool {
    guard let f = fopen(path, "wb") else { return false }
    defer { fclose(f) }
    return bytes.withUnsafeBytes { fwrite($0.baseAddress, 1, bytes.count, f) } == bytes.count
}

/// Milliseconds of CPU time, for rough timing in test output.
func hostMillis() -> Int { Int(clock()) / (Int(CLOCKS_PER_SEC) / 1000) }

@main struct HostTestMain {
    static func main() {
        let name = getenv("WIFFER_HOSTTEST_LIB").map { String(cString: $0) } ?? "?"
        let t = Tests(lib: name)
        host_guard_start()
        host_guard_label("\(name): start")
        let start = hostMillis()
        libTests(t)
        host_guard_finish()
        print("\(t.failed == 0 ? "ok" : "FAILED") \(name): \(t.passed) passed, \(t.failed) failed (\(hostMillis() - start) ms, peak \(host_peak_rss_mb()) MiB)")
        exit(t.failed == 0 ? 0 : 1)
    }
}
