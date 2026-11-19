private let fx = "lib/image/fixtures/"
private let cap = 1 << 26

private func hex64(_ v: UInt64) -> String {
    var s = ""
    let digits: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
    var i = 60
    while i >= 0 { s.append(digits[Int((v >> UInt64(i)) & 15)]); i -= 4 }
    return s
}

private func decode(_ d: [UInt8], _ max: Int = cap) -> (ImageBitmap?, ImageError?) {
    do throws(ImageError) { return (try imageDecode(d, maxBytes: max), nil) }
    catch { return (nil, error) }
}

private func lines(_ bytes: [UInt8]) -> [[String]] {
    var out: [[String]] = []
    var cur: [String] = []
    var word = ""
    for c in bytes {
        if c == 10 { if !word.isEmpty { cur.append(word); word = "" }; if !cur.isEmpty { out.append(cur) }; cur = [] }
        else if c == 32 { if !word.isEmpty { cur.append(word); word = "" } }
        else { word.append(Character(UnicodeScalar(c))) }
    }
    return out
}

private func parseInt(_ s: String) -> Int {
    var v = 0
    for c in s.utf8 where c >= 48 && c <= 57 { v = v * 10 + Int(c - 48) }
    return v
}

func libTests(_ t: Tests) {
    t.section("sniff")
    t.check(imageSniff([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) == .png, "png magic")
    t.check(imageSniff(Array("GIF89a".utf8)) == .gif && imageSniff(Array("GIF87a".utf8)) == .gif, "gif magic")
    t.check(imageSniff([0xff, 0xd8, 0xff, 0xe0]) == .jpeg, "jpeg magic")
    t.check(imageSniff(Array("<html>".utf8)) == .unknown && imageSniff([]) == .unknown, "unknown")
    t.check(decode(Array("<html>".utf8)).1 == .unknownFormat, "decode unknown")

    // PngSuite, checked against expected.txt (made by tests/refdecode.py).
    t.section("PngSuite")
    var accepted = 0, rejected = 0, total = 0
    if let manifest = t.readFile(fx + "pngsuite/expected.txt") {
        for l in lines(manifest) {
            guard l.count >= 2 else { continue }
            total += 1
            guard let data = t.readFile(fx + "pngsuite/" + l[0]) else { continue }
            let (bm, err) = decode(data)
            if l[1] == "reject" {
                t.check(bm == nil && err != nil, "\(l[0]) must be rejected")
                if bm == nil { rejected += 1 }
            } else if let bm = bm {
                let ok = bm.width == parseInt(l[1]) && bm.height == parseInt(l[2])
                    && hex64(fnv1a64(bm.rgbaBytes())) == l[3]
                t.check(ok, "\(l[0]) pixels differ from reference")
                if ok { accepted += 1 }
            } else {
                t.check(false, "\(l[0]) failed to decode")
            }
        }
    }
    t.equal(total, 176, "PngSuite file count")
    t.equal(rejected, 14, "PngSuite x*.png rejected")
    print("PngSuite: \(accepted) of \(total - 14) valid files decoded identically to the reference, \(rejected) of 14 corrupt files rejected")

    t.section("limits")
    if let d = t.readFile(fx + "pngsuite/basn2c08.png") {   // 32x32
        t.check(decode(d, 32 * 32 * 4).0 != nil, "exactly at the cap")
        t.check(decode(d, 32 * 32 * 4 - 1).1 == .tooLarge, "one byte over the cap")
        t.check(decode(d, 0).1 == .tooLarge, "zero cap")
    }
    // A header claiming 2^31-1 square must be rejected before allocating.
    let crcTool = InflateCRC32()
    func ihdr(_ w: UInt32, _ h: UInt32) -> [UInt8] {
        var body: [UInt8] = Array("IHDR".utf8)
        for v in [w, h] { body += [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
        body += [8, 2, 0, 0, 0]
        let c = crcTool.of(body)
        return [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13] + body
            + [UInt8(c >> 24), UInt8((c >> 16) & 255), UInt8((c >> 8) & 255), UInt8(c & 255)]
    }
    t.check(decode(ihdr(0x7fff_ffff, 0x7fff_ffff), 1 << 30).1 == .tooLarge, "2^31 x 2^31 rejected before allocating")
    t.check(decode(ihdr(65535, 65535), 1 << 30).1 == .tooLarge, "65535^2 over a 1 GiB cap")
    t.check(decode(ihdr(100, 100), 1 << 30).1 == .truncated, "valid header, no data")
    runFormatTests(t)
    runSVGImageTests(t)
    runFuzz(t)
}

private func runSVGImageTests(_ t: Tests) {
    t.section("svg")
    let icon = Array("<?xml version='1.0'?><svg xmlns='http://www.w3.org/2000/svg' width='16' height='8' viewBox='0 0 2 1'><rect width='1' height='1' fill='red'/></svg>".utf8)
    t.check(imageSniff(icon) == .svg, "sniff svg")
    do throws(ImageError) {
        let bm = try imageDecode(icon, maxBytes: 1 << 20)
        t.check(bm.width == 16 && bm.height == 8 && bm.svg != nil, "intrinsic size")
        t.check(bm.pixels.count == 128 && bm.pixels[0] == 0xffff_0000 && bm.pixels[15] >> 24 == 0, "rendered at intrinsic size")
        if let big = imageResample(bm, width: 160, height: 80, maxBytes: 1 << 20) {
            // Sharp at 10x: the edge between red and transparent is one pixel.
            t.check(big.pixels[40 * 160 + 79] == 0xffff_0000 && big.pixels[40 * 160 + 80] >> 24 == 0, "re-rendered, not scaled")
        } else { t.check(false, "resample svg") }
        t.check(imageResample(bm, width: 100_000, height: 100_000, maxBytes: 1 << 20) == nil, "resample cap")
    } catch { t.check(false, "decode svg") }
    func size(_ s: String) -> (Int, Int)? {
        guard let d = SVGDocument.parse(Array(s.utf8)) else { return nil }
        return imageSVGSize(d)
    }
    t.check(size("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'/>").map { $0 == (150, 150) } ?? false, "ratio only: fits 300x150")
    t.check(size("<svg xmlns='http://www.w3.org/2000/svg' width='30' viewBox='0 0 3 1'/>").map { $0 == (30, 10) } ?? false, "width and ratio")
    t.check(size("<svg xmlns='http://www.w3.org/2000/svg'/>").map { $0 == (300, 150) } ?? false, "nothing: 300x150")
    do throws(ImageError) {
        let huge = try imageDecode(Array("<svg xmlns='http://www.w3.org/2000/svg' width='90000' height='90000'/>".utf8), maxBytes: 1 << 20)
        t.check(huge.pixels.isEmpty && huge.width == 90000, "huge intrinsic size: no pixels, still usable")
    } catch { t.check(false, "decode huge svg") }
    t.check(decode(Array("<svg xmlns='http://example.com'/>".utf8)).1 == .malformed, "not svg")
}
