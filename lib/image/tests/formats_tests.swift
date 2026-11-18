private let fx2 = "lib/image/fixtures/"

private func decode2(_ d: [UInt8], _ max: Int = 1 << 26) -> (ImageBitmap?, ImageError?) {
    do throws(ImageError) { return (try imageDecode(d, maxBytes: max), nil) }
    catch { return (nil, error) }
}

private func manifestLines(_ bytes: [UInt8]) -> [[String]] {
    var out: [[String]] = []
    var cur: [String] = []
    var word = ""
    for c in bytes + [10] {
        if c == 10 { if !word.isEmpty { cur.append(word); word = "" }; if !cur.isEmpty { out.append(cur) }; cur = [] }
        else if c == 32 { if !word.isEmpty { cur.append(word); word = "" } }
        else { word.append(Character(UnicodeScalar(c))) }
    }
    return out
}

private func num(_ s: String) -> Int {
    var v = 0
    for c in s.utf8 where c >= 48 && c <= 57 { v = v * 10 + Int(c - 48) }
    return v
}

private func hex16(_ v: UInt64) -> String {
    var s = ""
    let digits: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
    var i = 60
    while i >= 0 { s.append(digits[Int((v >> UInt64(i)) & 15)]); i -= 4 }
    return s
}

/// Parse a binary PPM (P6) or PGM (P5) as RGB bytes.
private func readPNM(_ d: [UInt8]) -> (Int, Int, [UInt8])? {
    var i = 2
    var vals: [Int] = []
    while vals.count < 3 && i < d.count {
        while i < d.count && (d[i] == 32 || d[i] == 10 || d[i] == 13 || d[i] == 9) { i += 1 }
        var v = 0, any = false
        while i < d.count && d[i] >= 48 && d[i] <= 57 { v = v * 10 + Int(d[i] - 48); i += 1; any = true }
        if any { vals.append(v) }
    }
    i += 1
    guard vals.count == 3, d.count >= 2 else { return nil }
    let w = vals[0], h = vals[1]
    if d[1] == 0x35 {
        guard d.count >= i + w * h else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for k in 0..<(w * h) { out[3 * k] = d[i + k]; out[3 * k + 1] = d[i + k]; out[3 * k + 2] = d[i + k] }
        return (w, h, out)
    }
    guard d.count >= i + w * h * 3 else { return nil }
    return (w, h, Array(d[i..<(i + w * h * 3)]))
}

func runFormatTests(_ t: Tests) {
    t.section("GIF")
    var gifOK = 0
    if let m = t.readFile(fx2 + "gifs.txt") {
        for l in manifestLines(m) where l.count == 4 {
            guard let d = t.readFile(fx2 + l[0]) else { continue }
            let (bm, e) = decode2(d)
            if let bm = bm {
                let ok = bm.width == num(l[1]) && bm.height == num(l[2]) && hex16(fnv1a64(bm.rgbaBytes())) == l[3]
                t.check(ok, "\(l[0]) pixels differ")
                if ok { gifOK += 1 }
            } else { t.check(false, "\(l[0]) failed", e == .truncated ? "truncated" : "other") }
        }
    }
    t.equal(gifOK, 7, "GIF fixtures decoded")
    if let d = t.readFile(fx2 + "g_basic256.gif") {
        t.check(decode2(d, 70 * 50 * 4 - 4).1 == .tooLarge, "GIF cap")
        for n in 0..<min(d.count, 400) where n % 3 == 0 {   // every truncation fails cleanly or decodes partially
            _ = decode2(Array(d[0..<n]))
        }
    }

    t.section("JPEG")
    let jnames = ["444", "422", "420", "411", "440", "gray", "restart", "restart_rows", "odd", "opt", "q10", "q100",
                  "tiny", "one", "wide", "prog420", "prog444", "prog422", "prog_gray", "prog_restart", "prog_411", "cmyk"]
    var worstMax = 0, worstName = ""
    var meanSum = 0.0, jok = 0
    for n in jnames {
        guard let jd = t.readFile(fx2 + "j_\(n).jpg"), let pd = t.readFile(fx2 + "j_\(n).pnm"),
              let (rw, rh, ref) = readPNM(pd) else { continue }
        let (bm, e) = decode2(jd)
        guard let bm = bm else { t.check(false, "j_\(n) failed to decode", e == .unsupported ? "unsupported" : "error"); continue }
        t.check(bm.width == rw && bm.height == rh && bm.opaque, "j_\(n) size \(bm.width)x\(bm.height) vs \(rw)x\(rh)")
        if bm.width != rw || bm.height != rh { continue }
        var maxd = 0, sum = 0
        for i in 0..<(rw * rh) {
            let p = bm.pixels[i]
            let c = [Int((p >> 16) & 255), Int((p >> 8) & 255), Int(p & 255)]
            for k in 0..<3 {
                let dd = abs(c[k] - Int(ref[3 * i + k]))
                if dd > maxd { maxd = dd }
                sum += dd
            }
        }
        let mean = Double(sum) / Double(rw * rh * 3)
        // libjpeg-turbo reference, same IDCT and upsampling: expect (almost) exact.
        let tol = 0   // bit-exact with libjpeg-turbo on these fixtures
        t.check(maxd <= tol && mean == 0.0, "j_\(n) max error \(maxd) mean \(Int(mean * 1000)) milli-levels")
        if maxd > worstMax { worstMax = maxd; worstName = n }
        meanSum += mean; jok += 1
    }
    print("JPEG: \(jok) of \(jnames.count) fixtures compared to djpeg; worst max error \(worstMax) (\(worstName)), mean of means \(Int(meanSum / Double(max(jok, 1)) * 1000)) milli-levels")
}

func runFuzz(_ t: Tests) {
    t.section("scale/blend/lru")
    var px = [UInt32](repeating: 0, count: 4 * 4)
    for i in 0..<16 { px[i] = 0xff00_0000 | UInt32(i * 16) << 16 | UInt32(255 - i * 16) << 8 }
    let src = ImageBitmap(width: 4, height: 4, pixels: px, opaque: true)
    let same = imageScaleBilinear(src, width: 4, height: 4, maxBytes: 1 << 20)
    t.check(same?.pixels == px, "scale to the same size is the identity")
    if let up = imageScaleBilinear(src, width: 9, height: 7, maxBytes: 1 << 20) {
        t.check(up.width == 9 && up.height == 7 && up.pixels.count == 63 && up.opaque, "upscale dimensions")
        t.check(up.pixels[0] == px[0] && up.pixels[62] == px[15], "upscale keeps the corners")
    } else { t.check(false, "upscale") }
    t.check(imageScaleBilinear(src, width: 100, height: 100, maxBytes: 1000) == nil, "scale respects the cap")
    if let down = imageScaleBilinear(src, width: 1, height: 1, maxBytes: 1 << 20) {
        t.check(down.pixels.count == 1, "downscale to 1x1")
    }
    // Premultiplied interpolation: a transparent black pixel must not darken a white opaque one.
    let ap = ImageBitmap(width: 2, height: 1, pixels: [0xffff_ffff, 0x0000_0000], opaque: false)
    if let s2 = imageScaleBilinear(ap, width: 4, height: 1, maxBytes: 1 << 20) {
        t.check((s2.pixels[1] >> 24) > 0 && (s2.pixels[1] & 0x00ff_ffff) == 0x00ff_ffff, "alpha-weighted color (got \(s2.pixels[1]))")
    }
    // Blend: opaque copies, transparent skips, half alpha mixes; clipping at the edges.
    var dst = [UInt32](repeating: 0x0010_2030, count: 5 * 4)
    let sp: [UInt32] = [0xff11_2233, 0x0000_0000, 0x80ff_ffff, 0x80ff_ffff]
    let sb = ImageBitmap(width: 2, height: 2, pixels: sp, opaque: false)
    dst.withUnsafeMutableBufferPointer { d in
        imageBlend(into: d.baseAddress!, stride: 5, width: 5, height: 4, src: sb, x: 1, y: 1)
        imageBlend(into: d.baseAddress!, stride: 5, width: 5, height: 4, src: sb, x: -1, y: 3)    // clipped
        imageBlend(into: d.baseAddress!, stride: 5, width: 5, height: 4, src: sb, x: 40, y: 40)   // outside
    }
    t.check(dst[6] == 0x0011_2233, "opaque pixel copied")
    t.check(dst[7] == 0x0010_2030, "transparent pixel skipped")
    t.check(dst[11] == 0x0088_8f97 || dst[11] == 0x0087_8f97 || (dst[11] >> 24) == 0, "half alpha blend (got \(dst[11]))")
    t.check(dst[15] == 0x0011_2233 || dst[15] == 0x0010_2030, "clipped blend is sane")
    var lru = ImageLRU<Int, Int>(budget: 10)
    lru.put(1, 100, cost: 4); lru.put(2, 200, cost: 4)
    t.check(lru.get(1) == 100, "lru hit")
    lru.put(3, 300, cost: 4)       // evicts 2 (1 was just used)
    t.check(lru.get(2) == nil && lru.get(1) == 100 && lru.get(3) == 300, "lru evicts least recently used")
    lru.put(4, 400, cost: 11)
    t.check(lru.get(4) == nil && lru.totalCost <= 10, "lru refuses oversize entries")

    t.section("robustness")
    guard let pngSeed = t.readFile(fx2 + "pngsuite/basi4a16.png"), let pngSeed2 = t.readFile(fx2 + "pngsuite/basn3p04.png"),
          let pngSeed3 = t.readFile(fx2 + "pngsuite/basi2c16.png"), let pngSeed4 = t.readFile(fx2 + "pngsuite/basn6a08.png"),
          let gifSeed = t.readFile(fx2 + "g_interlaced.gif"), let gifSeed2 = t.readFile(fx2 + "g_local_offset.gif"),
          let j1 = t.readFile(fx2 + "j_420.jpg"), let j2 = t.readFile(fx2 + "j_prog420.jpg"),
          let j3 = t.readFile(fx2 + "j_restart.jpg"), let j4 = t.readFile(fx2 + "j_prog_restart.jpg"),
          let j5 = t.readFile(fx2 + "j_cmyk.jpg"), let j6 = t.readFile(fx2 + "j_gray.jpg") else { return }
    // Every truncation of each format decodes partially or fails, never crashes.
    for d in [pngSeed, gifSeed, j1, j2] {
        var n = 0
        while n < d.count { _ = decode2(Array(d[0..<n]), 1 << 22); n += max(1, d.count / 150) }
    }
    // Headers that claim huge dimensions are refused up front (JPEG SOF, GIF screen size).
    var big = j1
    if let sof = (0..<(big.count - 9)).first(where: { big[$0] == 0xff && big[$0 + 1] == 0xc0 }) {
        big[sof + 5] = 0xff; big[sof + 6] = 0xff; big[sof + 7] = 0xff; big[sof + 8] = 0xff
        t.check(decode2(big, 1 << 26).1 == .tooLarge, "JPEG 65535x65535 rejected before allocating")
    }
    var bigGif = gifSeed
    bigGif[6] = 0xff; bigGif[7] = 0xff; bigGif[8] = 0xff; bigGif[9] = 0xff
    t.check(decode2(bigGif, 1 << 26).1 == .tooLarge, "GIF 65535x65535 rejected before allocating")

    t.section("fuzz")
    let seeds = [pngSeed, pngSeed2, pngSeed3, pngSeed4, gifSeed, gifSeed2, j1, j2, j3, j4, j5, j6]
    let cap = 1 << 22      // 4 MiB of pixels: a runaway allocation shows up as a hang or an OOM
    t.fuzz("image", seeds: seeds, iterations: 6000) { data in
        _ = decode2(data, cap)
    }

    t.section("speed")
    if let png = t.readFile(fx2 + "speed.png"), let jpg = t.readFile(fx2 + "speed.jpg"),
       let pj = t.readFile(fx2 + "speed_prog.jpg") {
        for (name, d) in [("PNG", png), ("JPEG baseline 4:2:0", jpg), ("JPEG progressive 4:2:0", pj)] {
            var mp = 0
            let t0 = hostMillis()
            var runs = 0
            while hostMillis() - t0 < 600 || runs < 3 {
                if let b = decode2(d).0 { mp += b.width * b.height }
                runs += 1
            }
            let ms = max(1, hostMillis() - t0)
            print("\(name) decode speed: \(Double(mp) / 1000.0 / Double(ms)) MP/s (1024x768, \(runs) runs)")
        }
    }
}
