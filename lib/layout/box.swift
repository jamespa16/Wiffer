// The box tree (ROADMAP Phase 8F): one LayoutBox per generated box, built
// from the DOM and computed styles (build.swift), positioned by the layout
// passes (block, inline, table, flex) and turned into a display list
// (paint.swift).
//
// Coordinates. During layout every box stores its border box (x, y, w, h)
// relative to its *coordinate container*'s border box:
//   - absolutely positioned and fixed boxes: their containing block (`cb`),
//     or the page/viewport when `cb` is nil;
//   - boxes inside an inline formatting context (text, inline boxes,
//     atomic inlines): the block container that owns the line boxes (the
//     IFC root); inline boxes themselves have no single rectangle, only
//     per-line fragments (`frags`);
//   - everything else: the parent box.
// `LayoutEngine` then computes absolute page coordinates (ax, ay) in one
// walk, adding relative-position offsets and table-cell content shifts.
//
// Numbers. All geometry is Double. Values that come from CSS or attributes
// pass through `layoutSan` (NaN -> 0, clamped to +-layoutMaxCoord) so huge,
// negative or NaN inputs never trap; conversions to Int use `layoutInt`.

let layoutMaxCoord = 10_000_000.0

@inline(__always) func layoutSan(_ v: Double) -> Double {
    if v != v { return 0 }
    return v > layoutMaxCoord ? layoutMaxCoord : (v < -layoutMaxCoord ? -layoutMaxCoord : v)
}

/// Non-negative and sane.
@inline(__always) func layoutPos(_ v: Double) -> Double { let s = layoutSan(v); return s < 0 ? 0 : s }

/// Rounded Int, never traps.
@inline(__always) func layoutInt(_ v: Double) -> Int { Int(layoutSan(v).rounded()) }

/// Integer text for dumps (no Double formatting in Embedded Swift).
func layoutIntString(_ v: Int) -> String { "\(v)" }

struct LayoutRect: Equatable {
    var x = 0.0, y = 0.0, w = 0.0, h = 0.0
    init() {}
    init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    var maxX: Double { x + w }
    var maxY: Double { y + h }
    func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px < x + w && py >= y && py < y + h }
    func intersects(_ o: LayoutRect) -> Bool { x < o.x + o.w && o.x < x + w && y < o.y + o.h && o.y < y + h }
    func intersection(_ o: LayoutRect) -> LayoutRect {
        let x0 = max(x, o.x), y0 = max(y, o.y), x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return LayoutRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }
    func union(_ o: LayoutRect) -> LayoutRect {
        if w <= 0 && h <= 0 { return o }
        if o.w <= 0 && o.h <= 0 { return self }
        let x0 = min(x, o.x), y0 = min(y, o.y), x1 = max(maxX, o.maxX), y1 = max(maxY, o.maxY)
        return LayoutRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
    static let infinite = LayoutRect(x: -layoutMaxCoord, y: -layoutMaxCoord, w: 2 * layoutMaxCoord, h: 2 * layoutMaxCoord)
}

struct LayoutEdges {
    var t = 0.0, r = 0.0, b = 0.0, l = 0.0
    init() {}
    var horizontal: Double { l + r }
    var vertical: Double { t + b }
}

/// Collapsing margins: the largest positive and the most negative.
struct LayoutMargin {
    var pos = 0.0, neg = 0.0
    init() {}
    init(_ m: Double) { add(m) }
    mutating func add(_ m: Double) { if m > 0 { pos = max(pos, m) } else { neg = min(neg, m) } }
    mutating func merge(_ o: LayoutMargin) { pos = max(pos, o.pos); neg = min(neg, o.neg) }
    var value: Double { pos + neg }
}

/// Bounds on hostile input. The box tree is never deeper than `maxDepth`
/// (deeper elements generate no boxes); layout recurses once per box level,
/// so the stack use is bounded by maxDepth times the largest frame.
struct LayoutLimits {
    var maxDepth = 200
    var maxBoxes = 400_000
    var maxTableColumns = 1000
    var maxTableRows = 20_000
    var maxFloatsPerContext = 1000
    var maxFontSize = 512.0
    init() {}
}

enum LayoutBoxKind: UInt8 {
    case block          // block container: block, list-item, inline-block, flex item, anonymous block
    case inline         // inline box (children inline-level)
    case text
    case replaced       // img, form controls, iframe, video, ...
    case lineBreak      // <br>
    case marker         // outside list marker
    case table, rowGroup, row, cell, caption
    case flex
}

enum LayoutReplacedKind: UInt8 {
    case none, image, textInput, password, checkbox, radio, button, select, textarea, frame, other, svg
    /// A form control (exposed to the browser through `LayoutEngine.formControls`).
    var isControl: Bool {
        switch self {
        case .textInput, .password, .checkbox, .radio, .button, .select, .textarea: return true
        default: return false
        }
    }
}

enum LayoutPseudo: UInt8 { case none, before, after, marker }

/// A piece of a text box or inline box on one line, relative to the IFC root's
/// border box. For text, [start, end) is the scalar range of the box's run.
struct LayoutFrag {
    var x = 0.0, y = 0.0, w = 0.0, h = 0.0
    var baseline = 0.0
    var start: Int32 = 0, end: Int32 = 0
    /// Inline boxes: this fragment has the left / right edge (first / last line).
    var hasLeft = true, hasRight = true
    init() {}
}

struct LayoutLine {
    var y = 0.0, h = 0.0, baseline = 0.0
    var x = 0.0, w = 0.0      // used content extent on the line
    init() {}
}

final class LayoutBox {
    var kind: LayoutBoxKind
    /// The element (or text node) this box is for; nil for anonymous boxes.
    /// Pseudo-element and marker boxes point at their originating element.
    var node: HTMLNode?
    var pseudo = LayoutPseudo.none
    var style: CSSComputedStyle
    var children: [LayoutBox] = []
    unowned(unsafe) var parent: LayoutBox? = nil
    var anonymous = false
    /// Outer display is inline (inline boxes, text, atomic inlines).
    var inlineLevel = false
    /// A block container whose in-flow children are inline-level (an IFC root).
    var childrenInline = false
    var replaced = LayoutReplacedKind.none
    var depth = 0

    // Geometry: border box relative to the coordinate container (see top).
    var x = 0.0, y = 0.0, w = 0.0, h = 0.0
    var margin = LayoutEdges(), border = LayoutEdges(), padding = LayoutEdges()
    /// Escaping bottom margin (when the bottom margin collapses through this box).
    var collapsedBottom = LayoutMargin()
    var collapseThrough = false
    /// Content shift applied to children (table cell vertical-align).
    var childOffsetY = 0.0
    /// Relative-position offset.
    var relX = 0.0, relY = 0.0
    /// Absolute page coordinates of the border box (after layout).
    var ax = 0.0, ay = 0.0
    /// Accumulated relative offset of inline boxes (applies to their contents).
    var shiftX = 0.0, shiftY = 0.0
    /// Clip from overflow ancestors (page coordinates), accumulated opacity,
    /// inside a position: fixed subtree, inside an overflow-clipped box.
    var clip = LayoutRect.infinite
    var opacityAcc = 1.0
    var inFixed = false
    var extentClipped = false
    /// False for the root/body whose background became the canvas.
    var paintsBackground = true

    // Inline formatting
    var frags: [LayoutFrag] = []
    var lines: [LayoutLine] = []
    var raw: [UInt32] = []           // text: scalars after text-transform
    var run: TextRun? = nil          // text and markers: the shaped (collapsed) text
    var items: [LayoutInlineItem]? = nil   // IFC roots: flattened inline content
    var deco: UInt8 = 0              // propagated text-decoration lines
    var decoColor = CSSColor.black

    // Positioning
    unowned(unsafe) var cb: LayoutBox? = nil   // abspos/fixed containing block (nil = initial / viewport)
    var absChildren: [LayoutBox] = []
    var staticX = 0.0, staticY = 0.0
    unowned(unsafe) var staticParent: LayoutBox? = nil

    // Tables
    var colspan = 1, rowspan = 1, col = 0, rowIndex = 0
    /// border-collapse: cell edges whose border the neighbor draws (1 top, 2 right, 4 bottom, 8 left).
    var dropBorders: UInt8 = 0
    var table: LayoutTableData? = nil

    // Replaced
    var intrinsicW: Double? = nil, intrinsicH: Double? = nil
    var src: String? = nil
    /// img alt text, button/input value, select label, textarea text.
    var label = ""
    var labelIsPlaceholder = false
    var options: [String] = []
    var labelRun: TextRun? = nil
    /// Inline <svg> (svg.swift): the converted document, the external files
    /// its `use` elements reference, and the last render with its key.
    var svgDoc: SVGDocument? = nil
    var svgExternals: [String] = []
    var svgRaster: ImageBitmap? = nil
    var svgKey = ""
    var listValue = 0
    /// Outside list marker (laid out beside the first line).
    var marker: LayoutBox? = nil
    /// A display: contents element's style holder (never in the tree).
    var isContentsHolder = false
    /// Inside <center> or align=center: block children are centered.
    var legacyCenter = false

    // Font metrics of this box's style (valid for the life of the box tree).
    var cachedMetrics: LayoutFontMetrics? = nil
    var cachedLineHeight = 0.0

    // Caches (valid when the generation matches)
    var intrinsicGen = -1
    var minContent = 0.0, maxContent = 0.0
    var layoutGen = -1
    var layoutKeyW = -1.0, layoutKeyH = -2.0, layoutKeyAvail = -2.0, layoutKeyForce = -2.0
    var layoutKeyShrink = false

    init(kind: LayoutBoxKind, node: HTMLNode?, style: CSSComputedStyle) {
        self.kind = kind
        self.node = node
        self.style = style
    }

    var isBlockContainer: Bool { kind == .block || kind == .cell || kind == .caption }
    var isFloat: Bool { style.float != .none && style.position != .absolute && style.position != .fixed && kind != .text }
    var isAbs: Bool { (style.position == .absolute || style.position == .fixed) && kind != .text }
    var isOutOfFlow: Bool { isFloat || isAbs }
    /// Inline-level box that is laid out as a unit inside a line.
    var isAtomicInline: Bool {
        inlineLevel && (kind == .block || kind == .replaced || kind == .table || kind == .flex)
    }
    /// The element this box represents, for hit testing (text: its parent element).
    var element: HTMLNode? {
        if let n = node {
            if n.kind == .element { return n }
            return n.parentElement
        }
        var p = parent
        while let b = p { if let n = b.node, n.kind == .element { return n }; p = b.parent }
        return nil
    }
    var borderBox: LayoutRect { LayoutRect(x: ax, y: ay, w: w, h: h) }
    var paddingBox: LayoutRect {
        LayoutRect(x: ax + border.l, y: ay + border.t, w: max(0, w - border.horizontal), h: max(0, h - border.vertical))
    }
    var contentBox: LayoutRect {
        LayoutRect(x: ax + border.l + padding.l, y: ay + border.t + padding.t,
                   w: max(0, w - border.horizontal - padding.horizontal), h: max(0, h - border.vertical - padding.vertical))
    }

    func append(_ c: LayoutBox) {
        c.parent = self
        children.append(c)
    }
}

/// Per-table grid data, rebuilt with the box tree.
final class LayoutTableData {
    var rows: [LayoutBox] = []           // in visual order
    var cells: [LayoutBox] = []          // with col/rowIndex/colspan/rowspan filled in
    var columns = 0
    var colMin: [Double] = [], colMax: [Double] = [], colPct: [Double] = [], colFixed: [Double] = []
    var colGen = -1
    var colSpecWidth: [Double?] = []     // from <col width> / style
    /// Height of the captions above the table's border box.
    var gridTop = 0.0
    init() {}
}
