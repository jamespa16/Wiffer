// CSS colors: named (full CSS Color 4 list), #rgb[a], #rrggbb[aa], rgb()/rgba()
// (legacy and space syntax), hsl()/hsla(), transparent and currentColor.

struct CSSColor: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }
    static let black = CSSColor(r: 0, g: 0, b: 0)
    static let white = CSSColor(r: 255, g: 255, b: 255)
    static let transparent = CSSColor(r: 0, g: 0, b: 0, a: 0)
    /// 0xAARRGGBB
    var argb: UInt32 { UInt32(a) << 24 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }
}

enum CSSColorValue {
    case rgba(CSSColor)
    case currentColor
}

private let cssNamedColorSource = """
aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 \
black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 \
cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc \
crimson dc143c cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 \
darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f \
darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f \
darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 \
deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 \
floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 \
goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 honeydew f0fff0 hotpink ff69b4 \
indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5 \
lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff \
lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 \
lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 \
lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff \
maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db \
mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc \
mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 \
navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 \
orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee \
palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd \
powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 \
saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d \
silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa \
springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 \
turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 \
yellowgreen 9acd32
"""

private let cssNamedColors: [String: UInt32] = {
    var d: [String: UInt32] = [:]
    var name: [UInt8] = []
    var wordIndex = 0
    var curName = ""
    func flush(_ w: [UInt8]) {
        if w.isEmpty { return }
        if wordIndex % 2 == 0 { curName = String(decoding: w, as: UTF8.self) }
        else {
            var v: UInt32 = 0
            for c in w { v = v << 4 | UInt32(cssHexVal(Int(c))) }
            d[curName] = v
        }
        wordIndex += 1
    }
    for b in cssNamedColorSource.utf8 {
        if b == 0x20 || b == 0x0a { flush(name); name = [] } else { name.append(b) }
    }
    flush(name)
    return d
}()

func cssHexVal(_ d: Int) -> Int {
    d <= 0x39 ? d - 0x30 : (d | 0x20) - 0x61 + 10
}

func cssNamedColor(_ lowercased: String) -> CSSColor? {
    guard let v = cssNamedColors[lowercased] else { return nil }
    return CSSColor(r: UInt8(v >> 16 & 255), g: UInt8(v >> 8 & 255), b: UInt8(v & 255))
}

func cssParseHexColor(_ s: String) -> CSSColor? {
    var d: [Int] = []
    for b in s.utf8 {
        guard cssIsHexDigit(Int(b)) else { return nil }
        d.append(cssHexVal(Int(b)))
    }
    switch d.count {
    case 3, 4:
        return CSSColor(r: UInt8(d[0] * 17), g: UInt8(d[1] * 17), b: UInt8(d[2] * 17),
                        a: d.count == 4 ? UInt8(d[3] * 17) : 255)
    case 6, 8:
        return CSSColor(r: UInt8(d[0] * 16 + d[1]), g: UInt8(d[2] * 16 + d[3]), b: UInt8(d[4] * 16 + d[5]),
                        a: d.count == 8 ? UInt8(d[6] * 16 + d[7]) : 255)
    default: return nil
    }
}

private func cssClamp255(_ v: Double) -> UInt8 {
    if !(v > 0) { return 0 }
    if v >= 255 { return 255 }
    return UInt8(v + 0.5 > 255 ? 255 : v + 0.5)
}

private func cssAlphaByte(_ v: Double) -> UInt8 { cssClamp255(max(0, min(1, v)) * 255) }

private enum CSSColorArg { case number(Double), percent(Double), angle(Double), none }

private func cssColorArg(_ c: CSSComponent) -> CSSColorArg? {
    guard case .token(let t) = c else { return nil }
    switch t {
    case .number(let v, _): return .number(v)
    case .percentage(let v): return .percent(v)
    case .dimension(let v, let u, _):
        switch cssLower(u) {
        case "deg": return .angle(v)
        case "grad": return .angle(v * 0.9)
        case "rad": return .angle(v * 57.29577951308232)
        case "turn": return .angle(v * 360)
        default: return nil
        }
    case .ident(let s): return cssLower(s) == "none" ? CSSColorArg.none : nil
    default: return nil
    }
}

private func cssHSLToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
    var hh = h.truncatingRemainder(dividingBy: 360)
    if hh < 0 { hh += 360 }
    hh /= 60
    let sat = max(0, min(1, s)), lig = max(0, min(1, l))
    let c = (1 - abs(2 * lig - 1)) * sat
    let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
    var r = 0.0, g = 0.0, b = 0.0
    switch Int(hh) {
    case 0: r = c; g = x
    case 1: r = x; g = c
    case 2: g = c; b = x
    case 3: g = x; b = c
    case 4: r = x; b = c
    default: r = c; b = x
    }
    let m = lig - c / 2
    return ((r + m) * 255, (g + m) * 255, (b + m) * 255)
}

func cssParseColorFunction(_ name: String, _ args: [CSSComponent]) -> CSSColor? {
    let lname = cssLower(name)
    let isRGB = lname == "rgb" || lname == "rgba"
    let isHSL = lname == "hsl" || lname == "hsla"
    guard isRGB || isHSL else { return nil }
    var vals: [CSSColorArg] = []
    var sawSlash = false
    var commas = 0
    for c in args {
        if case .token(.comma) = c { commas += 1; continue }
        if case .token(.delim(0x2f)) = c { sawSlash = true; continue }
        guard let a = cssColorArg(c) else { return nil }
        vals.append(a)
    }
    if vals.count != 3 && vals.count != 4 { return nil }
    if vals.count == 4 && !sawSlash && commas != 3 { return nil }
    var alpha = 1.0
    if vals.count == 4 {
        switch vals[3] {
        case .number(let v): alpha = v
        case .percent(let v): alpha = v / 100
        case .none: alpha = 0
        default: return nil
        }
    }
    func comp(_ a: CSSColorArg, _ pctScale: Double) -> Double? {
        switch a {
        case .number(let v): return v
        case .percent(let v): return v * pctScale / 100
        case .none: return 0
        case .angle: return nil
        }
    }
    if isRGB {
        guard let r = comp(vals[0], 255), let g = comp(vals[1], 255), let b = comp(vals[2], 255) else { return nil }
        return CSSColor(r: cssClamp255(r), g: cssClamp255(g), b: cssClamp255(b), a: cssAlphaByte(alpha))
    }
    var hue = 0.0
    switch vals[0] {
    case .number(let v), .angle(let v): hue = v
    case .none: hue = 0
    default: return nil
    }
    guard let s = comp(vals[1], 1), let l = comp(vals[2], 1) else { return nil }
    // Percent form maps to 0...1; a bare number is read as a percentage too.
    var sv = s, lv = l
    if case .number = vals[1] { sv = s / 100 }
    if case .number = vals[2] { lv = l / 100 }
    let (r, g, b) = cssHSLToRGB(hue, sv, lv)
    return CSSColor(r: cssClamp255(r), g: cssClamp255(g), b: cssClamp255(b), a: cssAlphaByte(alpha))
}

/// A single component as a color, or nil.
func cssParseColor(_ c: CSSComponent) -> CSSColorValue? {
    switch c {
    case .token(.hash(let s, _)):
        if let col = cssParseHexColor(s) { return .rgba(col) }
        return nil
    case .token(.ident(let s)):
        let l = cssLower(s)
        if l == "currentcolor" { return .currentColor }
        if l == "transparent" { return .rgba(.transparent) }
        if let col = cssNamedColor(l) { return .rgba(col) }
        return nil
    case .function(let name, let args):
        if let col = cssParseColorFunction(name, args) { return .rgba(col) }
        return nil
    default: return nil
    }
}
