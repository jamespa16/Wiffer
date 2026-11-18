// Font registry (ROADMAP Phase 8E): maps CSS font-family names, generics,
// weight and style onto the loaded faces, with synthetic bold/italic when a
// face is missing.

/// Generic families faces are filed under.
enum FontGeneric: Int {
    case sansSerif = 0, serif = 1, monospace = 2
}

final class FontFace {
    let id: Int
    let font: TTFont
    let family: String          // as registered, e.g. "DejaVu Sans"
    let generic: FontGeneric
    let weight: Int             // 400, 700
    let italic: Bool
    init(id: Int, font: TTFont, family: String, generic: FontGeneric, weight: Int, italic: Bool) {
        self.id = id; self.font = font; self.family = family
        self.generic = generic; self.weight = weight; self.italic = italic
    }
}

/// A face plus the synthetic styling needed to match the request.
struct TextFont {
    var face: FontFace
    var synthBold: Bool
    var synthItalic: Bool
}

/// An ordered fallback chain: shaping tries each font in turn per character.
struct FontChain {
    var fonts: [TextFont]
}

/// The bundled DejaVu files in rootfs, for the caller to read and register.
struct BundledFont {
    var path: String
    var family: String
    var generic: FontGeneric
    var bold: Bool
    var italic: Bool
}

let fontBundled: [BundledFont] = [
    BundledFont(path: "/fonts/DejaVuSans.ttf", family: "DejaVu Sans", generic: .sansSerif, bold: false, italic: false),
    BundledFont(path: "/fonts/DejaVuSans-Bold.ttf", family: "DejaVu Sans", generic: .sansSerif, bold: true, italic: false),
    BundledFont(path: "/fonts/DejaVuSans-Oblique.ttf", family: "DejaVu Sans", generic: .sansSerif, bold: false, italic: true),
    BundledFont(path: "/fonts/DejaVuSans-BoldOblique.ttf", family: "DejaVu Sans", generic: .sansSerif, bold: true, italic: true),
    BundledFont(path: "/fonts/DejaVuSerif.ttf", family: "DejaVu Serif", generic: .serif, bold: false, italic: false),
    BundledFont(path: "/fonts/DejaVuSerif-Bold.ttf", family: "DejaVu Serif", generic: .serif, bold: true, italic: false),
    BundledFont(path: "/fonts/DejaVuSerif-Italic.ttf", family: "DejaVu Serif", generic: .serif, bold: false, italic: true),
    BundledFont(path: "/fonts/DejaVuSerif-BoldItalic.ttf", family: "DejaVu Serif", generic: .serif, bold: true, italic: true),
    BundledFont(path: "/fonts/DejaVuSansMono.ttf", family: "DejaVu Sans Mono", generic: .monospace, bold: false, italic: false),
    BundledFont(path: "/fonts/DejaVuSansMono-Bold.ttf", family: "DejaVu Sans Mono", generic: .monospace, bold: true, italic: false),
    BundledFont(path: "/fonts/DejaVuSansMono-Oblique.ttf", family: "DejaVu Sans Mono", generic: .monospace, bold: false, italic: true),
    BundledFont(path: "/fonts/DejaVuSansMono-BoldOblique.ttf", family: "DejaVu Sans Mono", generic: .monospace, bold: true, italic: true),
]

/// ASCII-lowercase, trim whitespace and surrounding quotes.
func fontNormalizeFamily(_ s: String) -> String {
    var bytes: [UInt8] = []
    for b in s.utf8 { bytes.append(b >= 0x41 && b <= 0x5a ? b + 32 : b) }
    var lo = 0, hi = bytes.count
    func trimmable(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x22 || b == 0x27 || b == 0x0a }
    while lo < hi && trimmable(bytes[lo]) { lo += 1 }
    while hi > lo && trimmable(bytes[hi - 1]) { hi -= 1 }
    return String(decoding: bytes[lo..<hi], as: UTF8.self)
}

/// The generic family a (normalized) CSS family name stands for, or nil if it
/// is an unknown specific name.
func fontGenericForName(_ n: String) -> FontGeneric? {
    switch n {
    case "sans-serif", "system-ui", "ui-sans-serif", "-apple-system", "blinkmacsystemfont",
         "arial", "helvetica", "helvetica neue", "verdana", "tahoma", "segoe ui", "roboto",
         "trebuchet ms", "calibri", "open sans", "lucida grande", "liberation sans",
         "dejavu sans", "fantasy", "arimo":
        return .sansSerif
    case "serif", "ui-serif", "times", "times new roman", "georgia", "cambria", "palatino",
         "palatino linotype", "garamond", "book antiqua", "liberation serif", "dejavu serif",
         "cursive", "tinos", "baskerville":
        return .serif
    case "monospace", "ui-monospace", "courier", "courier new", "menlo", "monaco", "consolas",
         "lucida console", "liberation mono", "dejavu sans mono", "sf mono", "cousine":
        return .monospace
    default:
        return nil
    }
}

final class FontRegistry {
    private(set) var faces: [FontFace] = []

    init() {}

    /// Register a face from file bytes. Returns nil if it does not parse.
    @discardableResult
    func add(_ data: [UInt8], family: String, generic: FontGeneric, bold: Bool, italic: Bool) -> FontFace? {
        guard let f = TTFont(data) else { return nil }
        let face = FontFace(id: faces.count, font: f, family: family, generic: generic,
                            weight: bold ? 700 : 400, italic: italic)
        faces.append(face)
        return face
    }

    private func best(_ candidates: [FontFace], weight: Int, italic: Bool) -> TextFont? {
        var bestFace: FontFace? = nil
        var bestScore = Int.max
        for f in candidates {
            var score = abs(f.weight - weight)
            if f.italic != italic { score += 1000 }
            if score < bestScore { bestScore = score; bestFace = f }
        }
        guard let f = bestFace else { return nil }
        return TextFont(face: f, synthBold: weight >= 600 && f.weight < 600,
                        synthItalic: italic && !f.italic)
    }

    /// The best face for one family name (specific or generic), if any.
    func face(family: String, weight: Int, italic: Bool) -> TextFont? {
        let n = fontNormalizeFamily(family)
        var named: [FontFace] = []
        for f in faces where fontNormalizeFamily(f.family) == n { named.append(f) }
        if !named.isEmpty { return best(named, weight: weight, italic: italic) }
        if n == "inherit" || n == "initial" { return nil }
        guard let g = fontGenericForName(n) else { return nil }
        // Prefer the face family registered first for that generic.
        var generic: [FontFace] = []
        var chosen: String? = nil
        for f in faces where f.generic == g {
            if chosen == nil { chosen = f.family }
            if f.family == chosen { generic.append(f) }
        }
        return best(generic, weight: weight, italic: italic)
    }

    /// A fallback chain for a CSS font-family list: each listed family that
    /// resolves, then the default sans-serif (then serif and monospace, for
    /// coverage), without repeats.
    func chain(families: [String], weight: Int, italic: Bool) -> FontChain {
        var out: [TextFont] = []
        func push(_ f: TextFont?) {
            guard let f = f else { return }
            for e in out where e.face === f.face && e.synthBold == f.synthBold && e.synthItalic == f.synthItalic { return }
            out.append(f)
        }
        for fam in families { push(face(family: fam, weight: weight, italic: italic)) }
        push(face(family: "sans-serif", weight: weight, italic: italic))
        push(face(family: "serif", weight: weight, italic: italic))
        push(face(family: "monospace", weight: weight, italic: italic))
        return FontChain(fonts: out)
    }
}
