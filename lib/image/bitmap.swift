// Images: PNG, GIF and JPEG decoding to a common bitmap, plus bilinear
// scaling and alpha blending into an XRGB buffer. SVG is an image format too
// (ROADMAP Phase 8J): its bitmap is rasterized at the intrinsic size and
// keeps the document (`svg`), so imageResample draws it again, sharp, at
// whatever size layout asks for instead of scaling pixels.
//
// Pixel format (ImageBitmap): one UInt32 per pixel, 0xAARRGGBB, STRAIGHT
// (non-premultiplied) alpha, rows top to bottom, no padding (stride ==
// width). JPEG is always opaque (alpha 0xFF). The scaler interpolates in
// premultiplied space internally; imageBlend() composites straight alpha
// over a 32-bit XRGB destination (the browser's surface format).
//
// Every decoder takes `maxBytes`: width * height * 4 above it is rejected
// with .tooLarge before anything is allocated, because image headers lie.
// Nothing here traps on hostile input.

struct ImageBitmap {
    let width: Int
    let height: Int
    var pixels: [UInt32]
    /// True if every pixel has alpha 0xFF (blending can be a plain copy).
    var opaque: Bool
    /// The document of an SVG image (pixels are its intrinsic-size render,
    /// and may be empty if that size is over the cap).
    var svg: SVGDocument? = nil

    init(width: Int, height: Int, pixels: [UInt32], opaque: Bool) {
        self.width = width; self.height = height; self.pixels = pixels; self.opaque = opaque
    }

    /// Bytes of pixel storage (what `maxBytes` limits).
    var byteCount: Int { width * height * 4 }

    /// R, G, B, A byte order, for tests and for handing to other code.
    func rgbaBytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixels.count * 4)
        var o = 0
        for p in pixels {
            out[o] = UInt8(truncatingIfNeeded: p >> 16)
            out[o + 1] = UInt8(truncatingIfNeeded: p >> 8)
            out[o + 2] = UInt8(truncatingIfNeeded: p)
            out[o + 3] = UInt8(truncatingIfNeeded: p >> 24)
            o += 4
        }
        return out
    }
}

enum ImageError: Error, Equatable {
    case unknownFormat      // magic bytes match nothing we decode
    case unsupported        // valid but a feature we don't do (arithmetic JPEG, 12-bit...)
    case malformed          // structurally invalid
    case truncated          // data ends before the image does (PNG, GIF headers)
    case badChecksum        // CRC of a critical PNG chunk
    case tooLarge           // width * height * 4 exceeds the caller's cap
}

enum ImageFormat {
    case png, gif, jpeg, svg, unknown
}

/// Identify a format from its magic bytes.
func imageSniff(_ d: [UInt8]) -> ImageFormat {
    if d.count >= 8 && d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4e && d[3] == 0x47
        && d[4] == 0x0d && d[5] == 0x0a && d[6] == 0x1a && d[7] == 0x0a { return .png }
    if d.count >= 6 && d[0] == 0x47 && d[1] == 0x49 && d[2] == 0x46 && d[3] == 0x38
        && (d[4] == 0x37 || d[4] == 0x39) && d[5] == 0x61 { return .gif }
    if d.count >= 3 && d[0] == 0xff && d[1] == 0xd8 && d[2] == 0xff { return .jpeg }
    if svgSniff(d) { return .svg }
    return .unknown
}

/// Decode PNG, GIF (first frame) or JPEG by sniffing the magic bytes.
/// `maxBytes` caps width * height * 4.
func imageDecode(_ data: [UInt8], maxBytes: Int) throws(ImageError) -> ImageBitmap {
    switch imageSniff(data) {
    case .png: return try PNGDecoder.decode(data, maxBytes: maxBytes)
    case .gif: return try GIFDecoder.decode(data, maxBytes: maxBytes)
    case .jpeg: return try JPEGDecoder.decode(data, maxBytes: maxBytes)
    case .svg: return try imageDecodeSVG(data, maxBytes: maxBytes)
    case .unknown: throw ImageError.unknownFormat
    }
}

/// The intrinsic size of an SVG image in px: width/height when given, else
/// from the viewBox ratio, else the 300x150 default object size (a ratio
/// alone is fitted inside it).
func imageSVGSize(_ doc: SVGDocument) -> (Int, Int) {
    let (w0, h0, ratio) = doc.intrinsicSize()
    var w = w0, h = h0
    if w == nil && h == nil {
        if let r = ratio, r > 0 {
            if 300 / r <= 150 { w = 300; h = 300 / r } else { h = 150; w = 150 * r }
        } else { w = 300; h = 150 }
    } else if w == nil { w = ratio.map { h! * $0 } ?? 300 }
    else if h == nil { h = ratio.map { w! / $0 } ?? 150 }
    func px(_ v: Double?) -> Int {
        guard let v = v, v.isFinite else { return 1 }
        return Int(max(1, min(100_000, v.rounded())))
    }
    return (px(w), px(h))
}

/// Parse an SVG file into an image whose pixels are rendered at the
/// intrinsic size (left empty if that is over `maxBytes` or the renderer's
/// limit; imageResample still renders it at smaller sizes).
func imageDecodeSVG(_ data: [UInt8], maxBytes: Int) throws(ImageError) -> ImageBitmap {
    guard let doc = SVGDocument.parse(data) else { throw ImageError.malformed }
    let (w, h) = imageSVGSize(doc)
    var bm = ImageBitmap(width: w, height: h, pixels: [], opaque: false)
    if imageSizeOK(w, h, maxBytes), let r = svgRender(doc, width: w, height: h) {
        bm.pixels = r.pixels
    }
    bm.svg = doc
    return bm
}

/// `src` at dw x dh: an SVG is rendered again at that size, anything else
/// is resampled bilinearly. nil if the result would exceed maxBytes.
func imageResample(_ src: ImageBitmap, width dw: Int, height dh: Int, maxBytes: Int) -> ImageBitmap? {
    if let doc = src.svg {
        guard imageSizeOK(dw, dh, maxBytes), let r = svgRender(doc, width: dw, height: dh) else { return nil }
        var out = ImageBitmap(width: dw, height: dh, pixels: r.pixels, opaque: false)
        out.svg = doc
        return out
    }
    return imageScaleBilinear(src, width: dw, height: dh, maxBytes: maxBytes)
}

/// width * height * 4 <= maxBytes, without overflow. Dimensions must be > 0.
func imageSizeOK(_ w: Int, _ h: Int, _ maxBytes: Int) -> Bool {
    if w <= 0 || h <= 0 || maxBytes <= 0 { return false }
    if w > 0x7fff_ffff || h > 0x7fff_ffff { return false }
    return w <= maxBytes / 4 / h
}

/// Bilinear resample to dw x dh (pixel centers aligned, edges clamped,
/// premultiplied interpolation). nil if the result would exceed maxBytes.
func imageScaleBilinear(_ src: ImageBitmap, width dw: Int, height dh: Int, maxBytes: Int) -> ImageBitmap? {
    guard imageSizeOK(dw, dh, maxBytes), src.width > 0, src.height > 0,
          src.pixels.count >= src.width * src.height else { return nil }
    let sw = src.width, sh = src.height
    if dw == sw && dh == sh { return src }
    var out = [UInt32](repeating: 0, count: dw * dh)
    // Source coordinate of each destination column: x0 and a 0...256 weight.
    var xi = [Int](repeating: 0, count: dw)
    var xw = [Int](repeating: 0, count: dw)
    for x in 0..<dw {
        // (x + 0.5) * sw / dw - 0.5 in 8.8 fixed point
        var fx = ((2 * x + 1) * sw * 256) / (2 * dw) - 128
        if fx < 0 { fx = 0 }
        var i = fx >> 8
        if i >= sw - 1 { i = sw - 1; fx = i << 8 }
        xi[x] = i
        xw[x] = fx & 255
    }
    src.pixels.withUnsafeBufferPointer { sp in
        out.withUnsafeMutableBufferPointer { op in
            for y in 0..<dh {
                var fy = ((2 * y + 1) * sh * 256) / (2 * dh) - 128
                if fy < 0 { fy = 0 }
                var y0 = fy >> 8
                if y0 >= sh - 1 { y0 = sh - 1; fy = y0 << 8 }
                let wy = fy & 255
                let y1 = min(y0 + 1, sh - 1)
                let r0 = y0 * sw, r1 = y1 * sw
                for x in 0..<dw {
                    let x0 = xi[x], x1 = min(x0 + 1, sw - 1)
                    let wx = xw[x]
                    let p00 = sp[r0 + x0], p10 = sp[r0 + x1], p01 = sp[r1 + x0], p11 = sp[r1 + x1]
                    let w00 = (256 - wx) * (256 - wy), w10 = wx * (256 - wy)
                    let w01 = (256 - wx) * wy, w11 = wx * wy
                    if src.opaque {
                        var px: UInt32 = 0xff00_0000
                        var sh8 = 0
                        while sh8 < 24 {
                            let s = UInt64(sh8)
                            let v = Int((p00 >> s) & 255) * w00 + Int((p10 >> s) & 255) * w10
                                + Int((p01 >> s) & 255) * w01 + Int((p11 >> s) & 255) * w11
                            px |= UInt32(truncatingIfNeeded: (v + 32768) >> 16) << UInt32(sh8)
                            sh8 += 8
                        }
                        op[y * dw + x] = px
                    } else {
                        let a00 = Int(p00 >> 24), a10 = Int(p10 >> 24), a01 = Int(p01 >> 24), a11 = Int(p11 >> 24)
                        let k00 = w00 * a00, k10 = w10 * a10, k01 = w01 * a01, k11 = w11 * a11
                        let asum = k00 + k10 + k01 + k11          // alpha * 65536 * 255 scale: 2^16 * 255
                        if asum == 0 { op[y * dw + x] = 0; continue }
                        var px = UInt32(truncatingIfNeeded: (asum + 32768) >> 16) << 24
                        var sh8 = 0
                        while sh8 < 24 {
                            let s = UInt64(sh8)
                            let v = Int((p00 >> s) & 255) * k00 + Int((p10 >> s) & 255) * k10
                                + Int((p01 >> s) & 255) * k01 + Int((p11 >> s) & 255) * k11
                            px |= UInt32(truncatingIfNeeded: min(255, (v + asum / 2) / asum)) << UInt32(sh8)
                            sh8 += 8
                        }
                        op[y * dw + x] = px
                    }
                }
            }
        }
    }
    var opaque = true
    if !src.opaque { for p in out where p >> 24 != 255 { opaque = false; break } }
    return ImageBitmap(width: dw, height: dh, pixels: out, opaque: opaque)
}

/// Composite `src` (straight alpha) over the XRGB destination with its
/// top-left at (x, y), clipping to the destination. `stride` is in pixels.
/// Written destination pixels keep a zero high byte.
func imageBlend(into dst: UnsafeMutablePointer<UInt32>, stride: Int, width dw: Int, height dh: Int,
                src: ImageBitmap, x: Int, y: Int) {
    guard src.pixels.count >= src.width * src.height, stride >= dw else { return }
    let x0 = max(x, 0), y0 = max(y, 0)
    let x1 = min(x &+ src.width, dw), y1 = min(y &+ src.height, dh)
    if x0 >= x1 || y0 >= y1 { return }
    src.pixels.withUnsafeBufferPointer { sp in
        for dy in y0..<y1 {
            let srow = (dy - y) * src.width - x
            let drow = dy * stride
            for dx in x0..<x1 {
                let s = sp[srow + dx]
                let a = Int(s >> 24)
                if a == 255 { dst[drow + dx] = s & 0x00ff_ffff; continue }
                if a == 0 { continue }
                let d = dst[drow + dx]
                let ia = 255 - a
                let r = (Int((s >> 16) & 255) * a + Int((d >> 16) & 255) * ia + 127) / 255
                let g = (Int((s >> 8) & 255) * a + Int((d >> 8) & 255) * ia + 127) / 255
                let b = (Int(s & 255) * a + Int(d & 255) * ia + 127) / 255
                dst[drow + dx] = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            }
        }
    }
}

/// A tiny generic LRU cache with a byte budget (for decoded images, say).
/// Linear scans: meant for tens of entries, not thousands.
struct ImageLRU<Key: Equatable, Value> {
    private var keys: [Key] = []
    private var values: [Value] = []
    private var costs: [Int] = []
    private(set) var totalCost = 0
    let budget: Int

    init(budget: Int) { self.budget = budget }

    var count: Int { keys.count }

    /// Look up and mark as most recently used.
    mutating func get(_ key: Key) -> Value? {
        guard let i = keys.firstIndex(of: key) else { return nil }
        let k = keys.remove(at: i), v = values.remove(at: i), c = costs.remove(at: i)
        keys.append(k); values.append(v); costs.append(c)
        return v
    }

    /// Insert (replacing any entry with the key), then evict the least
    /// recently used until the total cost fits. An entry bigger than the
    /// whole budget is not stored.
    mutating func put(_ key: Key, _ value: Value, cost: Int) {
        if let i = keys.firstIndex(of: key) {
            totalCost -= costs[i]
            keys.remove(at: i); values.remove(at: i); costs.remove(at: i)
        }
        if cost > budget { return }
        keys.append(key); values.append(value); costs.append(cost)
        totalCost += cost
        while totalCost > budget && !keys.isEmpty {
            totalCost -= costs[0]
            keys.remove(at: 0); values.remove(at: 0); costs.remove(at: 0)
        }
    }
}
