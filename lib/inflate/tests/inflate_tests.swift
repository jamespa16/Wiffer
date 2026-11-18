private let fx = "lib/inflate/fixtures/"

/// Stream `data` in `chunk`-byte pieces, draining output after every feed.
private func streamed(_ data: [UInt8], _ format: InflateFormat, chunk: Int, limit: Int = 1 << 28) -> ([UInt8], InflateError?) {
    var z = Inflater(format: format, maxOutput: limit)
    var out: [UInt8] = []
    var i = 0
    do throws(InflateError) {
        while i < data.count {
            let n = min(chunk, data.count - i)
            try z.feed(Array(data[i..<(i + n)]))
            out.append(contentsOf: z.take())
            i += n
        }
        try z.feed([])
        try z.finish()
        out.append(contentsOf: z.take())
    } catch {
        out.append(contentsOf: z.take())
        return (out, error)
    }
    return (out, nil)
}

private func oneShot(_ data: [UInt8], _ format: InflateFormat = .auto, limit: Int = 1 << 28) -> ([UInt8], InflateError?) {
    do throws(InflateError) { return (try inflateBytes(data, format: format, maxOutput: limit), nil) }
    catch { return ([], error) }
}

private func errName(_ e: InflateError?) -> String {
    guard let e = e else { return "ok" }
    switch e {
    case .badHeader: return "badHeader"
    case .badChecksum: return "badChecksum"
    case .truncated: return "truncated"
    case .invalidBlockType: return "invalidBlockType"
    case .invalidStoredLength: return "invalidStoredLength"
    case .invalidCode: return "invalidCode"
    case .invalidDistance: return "invalidDistance"
    case .outputLimit: return "outputLimit"
    }
}

func libTests(_ t: Tests) {
    t.section("checksums")
    let nine = Array("123456789".utf8)
    t.check(InflateCRC32().of(nine) == 0xcbf4_3926, "crc32 check value")
    t.check(inflateAdler32(1, nine, 0, 9) == 0x091e_01de, "adler32 check value")

    // Round trips against fixtures made by host zlib/gzip (gen.py).
    let names = ["empty", "one", "hello", "zeros", "noise", "text", "mixed", "big"]
    var variants: [(String, InflateFormat)] = []
    for l in [0, 1, 6, 9] {
        variants.append((".l\(l).zlib", .zlib)); variants.append((".l\(l).gz", .gzip))
        variants.append((".l\(l).deflate", .raw))
    }
    for s in ["huff", "rle", "fixed"] { variants.append((".\(s).deflate", .raw)) }
    var files = 0
    for name in names {
        guard let want = t.readFile(fx + name + ".raw") else { continue }
        for (suffix, fmt) in variants {
            guard let data = t.readFileIfPresent(fx + name + suffix) else { continue }
            files += 1
            t.section("\(name)\(suffix)")
            let (o, e) = oneShot(data, fmt)
            t.check(e == nil && o == want, "one-shot", "\(errName(e)) \(o.count) vs \(want.count)")
            let (oa, ea) = oneShot(data, .auto)
            t.check(ea == nil && oa == want, "one-shot auto")
            let chunks = want.count > 100_000 ? [4096, 100_000] : [1, 3, 64, 5000]
            for c in chunks {
                let (s, se) = streamed(data, fmt, chunk: c)
                t.check(se == nil && s == want, "stream chunk \(c)", "\(errName(se)) \(s.count) vs \(want.count)")
            }
        }
    }
    t.check(files > 100, "enough fixtures found (\(files))")

    t.section("alldist")
    if let d = t.readFile(fx + "alldist.deflate"), let w = t.readFile(fx + "alldist.raw") {
        for c in [1, 2, 13, 100000] {
            let (s, e) = streamed(d, .raw, chunk: c)
            t.check(e == nil && s == w, "every length/distance code, chunk \(c)")
        }
    }

    t.section("gzip headers")
    for n in ["extra", "name", "comment", "hcrc", "all"] {
        if let d = t.readFile(fx + "flags.\(n).gz"), let w = t.readFile(fx + "flags.raw") {
            t.check(oneShot(d).0 == w, "flags.\(n)")
            t.check(streamed(d, .gzip, chunk: 1).0 == w, "flags.\(n) bytewise")
            if n == "hcrc" {
                var bad = d; bad[10] ^= 1
                t.check(oneShot(bad).1 == .badChecksum, "header CRC mismatch")
            }
        }
    }
    if let d = t.readFile(fx + "multi.gz"), let w = t.readFile(fx + "multi.raw") {
        t.check(oneShot(d).0 == w, "multiple members")
        t.check(streamed(d, .gzip, chunk: 1).0 == w, "multiple members bytewise")
        var z = Inflater(format: .gzip)
        try? z.feed(d)
        t.check(z.isDone, "multi isDone")
    }
    if let d = t.readFile(fx + "multi_trailing.gz") {
        t.check(oneShot(d).0 == Array(String(repeating: "first member ", count: 40).utf8), "trailing garbage ignored")
    }

    t.section("failures")
    guard let hz = t.readFile(fx + "text.l6.zlib"), let hg = t.readFile(fx + "text.l6.gz"),
          let hd = t.readFile(fx + "hello.l6.deflate"), let helloZ = t.readFile(fx + "hello.l6.zlib"),
          let helloG = t.readFile(fx + "hello.l6.gz") else { return }
    t.check(oneShot([0x00, 0x00, 0x00], .zlib).1 == .badHeader, "zlib bad header")
    t.check(oneShot([0x78, 0x9d], .zlib).1 == .badHeader, "zlib fcheck")
    t.check(oneShot([0x78, 0xbb, 0, 0], .zlib).1 == .badHeader, "zlib FDICT unsupported")
    t.check(oneShot([0x1f, 0x8b, 9, 0, 0, 0, 0, 0, 0, 0], .gzip).1 == .badHeader, "gzip bad method")
    t.check(oneShot([0x1f, 0x8c, 8, 0, 0, 0, 0, 0, 0, 0], .gzip).1 == .badHeader, "gzip bad magic")
    t.check(oneShot([0x1f, 0x8b, 8, 0x80, 0, 0, 0, 0, 0, 0], .gzip).1 == .badHeader, "gzip reserved flags")
    var b = hz; b[b.count - 1] ^= 0xff
    t.check(oneShot(b).1 == .badChecksum, "adler mismatch")
    t.check(streamed(b, .zlib, chunk: 100).1 == .badChecksum, "adler mismatch streaming")
    b = hg; b[b.count - 8] ^= 1
    t.check(oneShot(b).1 == .badChecksum, "crc mismatch")
    b = hg; b[b.count - 1] ^= 1
    t.check(oneShot(b).1 == .badChecksum, "isize mismatch")
    t.check(oneShot([0x07], .raw).1 == .invalidBlockType || oneShot([0x07], .raw).1 == .truncated, "block type 3")
    t.check(oneShot([0x07, 0, 0, 0, 0], .raw).1 == .invalidBlockType, "block type 3 (enough input)")
    t.check(oneShot([0x01, 0x05, 0x00, 0x00, 0x00], .raw).1 == .invalidStoredLength, "stored LEN/NLEN")
    t.check(oneShot([0x03, 0x02, 0x00], .raw).1 == .invalidDistance, "distance too far back")
    // Dynamic block with an over-subscribed code-length code.
    t.check(oneShot([0x05, 0xe0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], .raw).1 == .invalidCode, "bad dynamic tree")
    t.check(oneShot([]).1 == .truncated, "empty input truncated")
    t.check(oneShot([], .raw).1 == .truncated, "empty raw input truncated")
    // Every proper prefix of a stream is truncated, never a crash or success.
    for (d, f) in [(helloZ, InflateFormat.zlib), (helloG, .gzip), (hd, .raw)] {
        var allTruncated = true
        for n in 0..<d.count {
            let e = oneShot(Array(d[0..<n]), f).1
            let e2 = streamed(Array(d[0..<n]), f, chunk: 1).1
            if e != .truncated || e2 != .truncated {
                // A raw stream's last byte may only be padding bits.
                if !(f == .raw && n == d.count - 1) { allTruncated = false }
            }
        }
        t.check(allTruncated, "all prefixes truncated")
    }
    // After a failure the Inflater stays failed.
    var z = Inflater(format: .zlib)
    try? z.feed([0, 0])
    t.check((try? z.feed([1, 2, 3])) == nil, "stays failed")

    t.section("limits")
    if let d = t.readFile(fx + "zeros.l9.zlib") {
        t.check(oneShot(d, .zlib, limit: 1000).1 == .outputLimit, "bomb stopped at limit")
        t.check(oneShot(d, .zlib, limit: 149_999).1 == .outputLimit, "limit one short")
        t.check(oneShot(d, .zlib, limit: 150_000).1 == nil, "limit exact")
        var zz = Inflater(format: .zlib, maxOutput: 1000)
        _ = try? zz.feed(d)
        t.check(zz.take().count == 1000 && zz.totalOut == 1000, "output up to the limit is kept")
    }
    if let d = t.readFile(fx + "noise.l0.zlib") {
        t.check(oneShot(d, .zlib, limit: 100).1 == .outputLimit, "stored block limit")
    }

    t.section("streaming")
    if let d = t.readFile(fx + "big.l9.gz"), let w = t.readFile(fx + "big.raw") {
        var z = Inflater(format: .gzip, maxOutput: w.count)
        var out: [UInt8] = []
        var maxPending = 0
        var i = 0
        while i < d.count {
            let n = min(1500, d.count - i)
            do throws(InflateError) { try z.feed(Array(d[i..<(i + n)])) } catch { t.check(false, "stream error", errName(error) + " at \(i), out \(z.totalOut)"); break }
            maxPending = max(maxPending, z.pendingCount)
            out.append(contentsOf: z.take())
            i += n
        }
        t.check(z.isDone && out == w, "1500-byte chunks of the 1 MB file")
        t.check(maxPending < 100_000, "pending output stays small (\(maxPending))")
    }

    t.section("speed")
    if let d = t.readFile(fx + "big.l9.zlib"), let w = t.readFile(fx + "big.raw") {
        let t0 = hostMillis()
        var total = 0
        for _ in 0..<20 { total += oneShot(d, .zlib).0.count }
        let ms = max(1, hostMillis() - t0)
        t.equal(total, w.count * 20, "speed loop")
        print("inflate speed: \(total / 1000 / ms) MB/s (\(w.count / 1000) KB text, level 9, 20 runs, \(ms) ms)")
    }

    t.section("fuzz")
    var seeds: [[UInt8]] = [hz, hg, hd, helloZ, helloG]
    if let d = t.readFile(fx + "alldist.deflate") { seeds.append(d) }
    if let d = t.readFile(fx + "mixed.l6.gz") { seeds.append(Array(d.prefix(8000))) }
    if let d = t.readFile(fx + "noise.l0.zlib") { seeds.append(Array(d.prefix(3000))) }
    if let d = t.readFile(fx + "multi.gz") { seeds.append(d) }
    seeds = seeds.map { Array($0.prefix(6000)) }
    t.fuzz("inflate", seeds: seeds, iterations: 6000) { data in
        for f in [InflateFormat.auto, .raw, .zlib, .gzip] {
            _ = oneShot(data, f, limit: 1 << 20)
        }
        _ = streamed(data, .auto, chunk: 1 + data.count % 17, limit: 1 << 20)
    }
}
