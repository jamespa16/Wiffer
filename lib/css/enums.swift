// Keyword-valued computed properties. Each enum's raw value is the index of
// its keyword in `cssNames` (the order here is what the parser relies on).

protocol CSSKeywordEnum {
    init?(rawValue: UInt8)
    static var cssNames: [String] { get }
    static var cssDefault: Self { get }
}

extension CSSKeywordEnum {
    init(cssIndex k: UInt8) { self = Self(rawValue: k) ?? Self.cssDefault }
}

enum CSSDisplay: UInt8, CSSKeywordEnum {
    case none, block, inline, inlineBlock, listItem, table, inlineTable, tableRowGroup,
         tableHeaderGroup, tableFooterGroup, tableRow, tableColumnGroup, tableColumn,
         tableCell, tableCaption, flex, inlineFlex, contents
    static let cssNames = ["none", "block", "inline", "inline-block", "list-item", "table", "inline-table",
                           "table-row-group", "table-header-group", "table-footer-group", "table-row",
                           "table-column-group", "table-column", "table-cell", "table-caption", "flex",
                           "inline-flex", "contents"]
    static var cssDefault: CSSDisplay { .inline }
    var isInlineLevel: Bool { self == .inline || self == .inlineBlock || self == .inlineTable || self == .inlineFlex }
}

enum CSSPosition: UInt8, CSSKeywordEnum {
    case `static`, relative, absolute, fixed, sticky
    static let cssNames = ["static", "relative", "absolute", "fixed", "sticky"]
    static var cssDefault: CSSPosition { .static }
}

enum CSSFloat: UInt8, CSSKeywordEnum {
    case none, left, right
    static let cssNames = ["none", "left", "right"]
    static var cssDefault: CSSFloat { .none }
}

enum CSSClear: UInt8, CSSKeywordEnum {
    case none, left, right, both
    static let cssNames = ["none", "left", "right", "both"]
    static var cssDefault: CSSClear { .none }
}

enum CSSBoxSizing: UInt8, CSSKeywordEnum {
    case contentBox, borderBox
    static let cssNames = ["content-box", "border-box"]
    static var cssDefault: CSSBoxSizing { .contentBox }
}

enum CSSVisibility: UInt8, CSSKeywordEnum {
    case visible, hidden, collapse
    static let cssNames = ["visible", "hidden", "collapse"]
    static var cssDefault: CSSVisibility { .visible }
}

enum CSSOverflow: UInt8, CSSKeywordEnum {
    case visible, hidden, scroll, auto
    static let cssNames = ["visible", "hidden", "scroll", "auto"]
    static var cssDefault: CSSOverflow { .visible }
}

enum CSSTextAlign: UInt8, CSSKeywordEnum {
    case left, right, center, justify
    static let cssNames = ["left", "right", "center", "justify"]
    static var cssDefault: CSSTextAlign { .left }
}

enum CSSTextTransform: UInt8, CSSKeywordEnum {
    case none, capitalize, uppercase, lowercase
    static let cssNames = ["none", "capitalize", "uppercase", "lowercase"]
    static var cssDefault: CSSTextTransform { .none }
}

enum CSSWhiteSpace: UInt8, CSSKeywordEnum {
    case normal, nowrap, pre, preWrap, preLine
    static let cssNames = ["normal", "nowrap", "pre", "pre-wrap", "pre-line"]
    static var cssDefault: CSSWhiteSpace { .normal }
    /// Runs of spaces collapse.
    var collapsesSpaces: Bool { self == .normal || self == .nowrap || self == .preLine }
    var wraps: Bool { self != .nowrap && self != .pre }
    var preservesNewlines: Bool { self == .pre || self == .preWrap || self == .preLine }
}

enum CSSListStyleType: UInt8, CSSKeywordEnum {
    case none, disc, circle, square, decimal, decimalLeadingZero, lowerRoman, upperRoman,
         lowerAlpha, upperAlpha, lowerGreek
    static let cssNames = ["none", "disc", "circle", "square", "decimal", "decimal-leading-zero",
                           "lower-roman", "upper-roman", "lower-alpha", "upper-alpha", "lower-greek"]
    static var cssDefault: CSSListStyleType { .disc }
}

enum CSSListStylePosition: UInt8, CSSKeywordEnum {
    case outside, inside
    static let cssNames = ["outside", "inside"]
    static var cssDefault: CSSListStylePosition { .outside }
}

enum CSSFlexDirection: UInt8, CSSKeywordEnum {
    case row, rowReverse, column, columnReverse
    static let cssNames = ["row", "row-reverse", "column", "column-reverse"]
    static var cssDefault: CSSFlexDirection { .row }
}

enum CSSFlexWrap: UInt8, CSSKeywordEnum {
    case nowrap, wrap, wrapReverse
    static let cssNames = ["nowrap", "wrap", "wrap-reverse"]
    static var cssDefault: CSSFlexWrap { .nowrap }
}

enum CSSJustifyContent: UInt8, CSSKeywordEnum {
    case flexStart, flexEnd, center, spaceBetween, spaceAround, spaceEvenly
    static let cssNames = ["flex-start", "flex-end", "center", "space-between", "space-around", "space-evenly"]
    static var cssDefault: CSSJustifyContent { .flexStart }
}

enum CSSAlign: UInt8, CSSKeywordEnum {
    case auto, stretch, flexStart, flexEnd, center, baseline
    static let cssNames = ["auto", "stretch", "flex-start", "flex-end", "center", "baseline"]
    static var cssDefault: CSSAlign { .auto }
}

enum CSSBorderCollapse: UInt8, CSSKeywordEnum {
    case separate, collapse
    static let cssNames = ["separate", "collapse"]
    static var cssDefault: CSSBorderCollapse { .separate }
}

enum CSSTableLayout: UInt8, CSSKeywordEnum {
    case auto, fixed
    static let cssNames = ["auto", "fixed"]
    static var cssDefault: CSSTableLayout { .auto }
}

enum CSSBorderStyle: UInt8, CSSKeywordEnum {
    case none, hidden, dotted, dashed, solid, double, groove, ridge, inset, outset
    static let cssNames = ["none", "hidden", "dotted", "dashed", "solid", "double", "groove", "ridge",
                           "inset", "outset"]
    static var cssDefault: CSSBorderStyle { .none }
    var isVisible: Bool { self != .none && self != .hidden }
}

enum CSSFontStyle: UInt8, CSSKeywordEnum {
    case normal, italic, oblique
    static let cssNames = ["normal", "italic", "oblique"]
    static var cssDefault: CSSFontStyle { .normal }
}

enum CSSBackgroundRepeat: UInt8, CSSKeywordEnum {
    case `repeat`, repeatX, repeatY, noRepeat
    static let cssNames = ["repeat", "repeat-x", "repeat-y", "no-repeat"]
    static var cssDefault: CSSBackgroundRepeat { .repeat }
}

enum CSSVerticalAlignKind: UInt8, CSSKeywordEnum {
    case baseline, sub, `super`, top, textTop, middle, bottom, textBottom, length
    static let cssNames = ["baseline", "sub", "super", "top", "text-top", "middle", "bottom", "text-bottom"]
    static var cssDefault: CSSVerticalAlignKind { .baseline }
}

/// vertical-align: a keyword, or (kind == .length) `lengthPx` up from the baseline.
struct CSSVerticalAlign {
    var kind: CSSVerticalAlignKind = .baseline
    /// For `.length`: the offset in px (percentages are resolved against line-height).
    var lengthPx = 0.0
    init() {}
}

struct CSSTextDecoration: Equatable {
    var rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }
    static let none = CSSTextDecoration(rawValue: 0)
    static let underline = CSSTextDecoration(rawValue: 1)
    static let overline = CSSTextDecoration(rawValue: 2)
    static let lineThrough = CSSTextDecoration(rawValue: 4)
    var hasUnderline: Bool { rawValue & 1 != 0 }
    var hasOverline: Bool { rawValue & 2 != 0 }
    var hasLineThrough: Bool { rawValue & 4 != 0 }
}

enum CSSLineHeightKind: UInt8 { case normal, number, length }

/// line-height: `normal`, a multiplier, or a px length.
struct CSSLineHeight {
    var kind: CSSLineHeightKind = .normal
    var value = 0.0
    init() {}
    /// Used line height in px for text of `fontSize`.
    func resolve(fontSize: Double) -> Double {
        switch kind {
        case .normal: return fontSize * 1.2
        case .number: return fontSize * value
        case .length: return value
        }
    }
}

/// Which side/corner an item applies to, for the border and box arrays.
enum CSSSide: Int { case top = 0, right = 1, bottom = 2, left = 3 }
