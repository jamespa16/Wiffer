// The typed computed style the layout engine consumes, and how a specified
// value becomes a computed one. Em, rem, viewport and absolute units are
// already px; percentages (and calc() mixing them) stay as CSSLP / CSSDimension
// until layout knows the containing block.

enum CSSContentKind: UInt8 { case normal, none, items }

struct CSSComputedStyle {
    // Box
    var display = CSSDisplay.inline
    var position = CSSPosition.static
    var float = CSSFloat.none
    var clear = CSSClear.none
    var boxSizing = CSSBoxSizing.contentBox
    var top = CSSDimension.auto, right = CSSDimension.auto, bottom = CSSDimension.auto, left = CSSDimension.auto
    var width = CSSDimension.auto, height = CSSDimension.auto
    var minWidth = CSSDimension.auto, minHeight = CSSDimension.auto
    var maxWidth = CSSDimension.none, maxHeight = CSSDimension.none
    var marginTop = CSSDimension.zero, marginRight = CSSDimension.zero
    var marginBottom = CSSDimension.zero, marginLeft = CSSDimension.zero
    var paddingTop = CSSLP.zero, paddingRight = CSSLP.zero, paddingBottom = CSSLP.zero, paddingLeft = CSSLP.zero
    /// Computed border widths in px (0 where the style is none/hidden).
    var borderTopWidth = 3.0, borderRightWidth = 3.0, borderBottomWidth = 3.0, borderLeftWidth = 3.0
    var borderTopStyle = CSSBorderStyle.none, borderRightStyle = CSSBorderStyle.none
    var borderBottomStyle = CSSBorderStyle.none, borderLeftStyle = CSSBorderStyle.none
    var borderTopColor = CSSColor.black, borderRightColor = CSSColor.black
    var borderBottomColor = CSSColor.black, borderLeftColor = CSSColor.black
    var overflowX = CSSOverflow.visible, overflowY = CSSOverflow.visible
    var visibility = CSSVisibility.visible
    /// nil = auto
    var zIndex: Int? = nil
    var opacity = 1.0

    // Colors and background
    var color = CSSColor.black
    var backgroundColor = CSSColor.transparent
    /// The url() as given (or resolved by the parser's resolveURL); nil = none.
    var backgroundImage: String? = nil
    var backgroundRepeat = CSSBackgroundRepeat.repeat

    // Text
    var fontFamily: [String] = ["serif"]
    var fontSize = 16.0
    var fontWeight = 400
    var fontStyle = CSSFontStyle.normal
    var lineHeight = CSSLineHeight()
    var textAlign = CSSTextAlign.left
    /// Not inherited by the cascade (per spec); it propagates to descendants'
    /// inline boxes, which is layout's job.
    var textDecoration = CSSTextDecoration.none
    var textIndent = CSSLP.zero
    var textTransform = CSSTextTransform.none
    var whiteSpace = CSSWhiteSpace.normal
    var verticalAlign = CSSVerticalAlign()

    // Lists, tables
    var listStyleType = CSSListStyleType.disc
    var listStylePosition = CSSListStylePosition.outside
    var borderCollapse = CSSBorderCollapse.separate
    var borderSpacingH = 0.0, borderSpacingV = 0.0
    var tableLayout = CSSTableLayout.auto

    // Flex
    var flexDirection = CSSFlexDirection.row
    var flexWrap = CSSFlexWrap.nowrap
    var flexGrow = 0.0, flexShrink = 1.0
    var flexBasis = CSSDimension.auto
    var justifyContent = CSSJustifyContent.flexStart
    var alignItems = CSSAlign.stretch
    var alignSelf = CSSAlign.auto
    var rowGap = CSSLP.zero, columnGap = CSSLP.zero

    // Generated content (::before/::after): `contentKind == .items` => `contentItems`.
    var contentKind = CSSContentKind.normal
    var contentItems: [String] = []
    var cursor = "auto"

    /// Computed custom properties (inherited), values already var()-resolved.
    var customProperties: [String: [CSSComponent]] = [:]

    init() {}

    // MARK: Convenience for layout

    func margin(_ s: CSSSide) -> CSSDimension {
        switch s { case .top: return marginTop; case .right: return marginRight; case .bottom: return marginBottom; case .left: return marginLeft }
    }
    func padding(_ s: CSSSide) -> CSSLP {
        switch s { case .top: return paddingTop; case .right: return paddingRight; case .bottom: return paddingBottom; case .left: return paddingLeft }
    }
    func borderWidth(_ s: CSSSide) -> Double {
        switch s { case .top: return borderTopWidth; case .right: return borderRightWidth; case .bottom: return borderBottomWidth; case .left: return borderLeftWidth }
    }
    func borderStyle(_ s: CSSSide) -> CSSBorderStyle {
        switch s { case .top: return borderTopStyle; case .right: return borderRightStyle; case .bottom: return borderBottomStyle; case .left: return borderLeftStyle }
    }
    func borderColor(_ s: CSSSide) -> CSSColor {
        switch s { case .top: return borderTopColor; case .right: return borderRightColor; case .bottom: return borderBottomColor; case .left: return borderLeftColor }
    }
    func inset(_ s: CSSSide) -> CSSDimension {
        switch s { case .top: return top; case .right: return right; case .bottom: return bottom; case .left: return left }
    }
    /// Used line height in px.
    var lineHeightPx: Double { lineHeight.resolve(fontSize: fontSize) }
    /// A positioned element (relative, absolute, fixed, sticky).
    var isPositioned: Bool { position != .static }
    var isOutOfFlow: Bool { position == .absolute || position == .fixed || float != .none }
    var generatesBox: Bool { display != .none }

    // MARK: Inheritance

    /// Start from the parent's inherited properties (and custom properties).
    mutating func inheritProperties(from p: CSSComputedStyle) {
        color = p.color; fontSize = p.fontSize; fontFamily = p.fontFamily; fontWeight = p.fontWeight
        fontStyle = p.fontStyle; lineHeight = p.lineHeight; textAlign = p.textAlign
        textIndent = p.textIndent; textTransform = p.textTransform; whiteSpace = p.whiteSpace
        listStyleType = p.listStyleType; listStylePosition = p.listStylePosition
        visibility = p.visibility; borderCollapse = p.borderCollapse
        borderSpacingH = p.borderSpacingH; borderSpacingV = p.borderSpacingV; cursor = p.cursor
        customProperties = p.customProperties
    }

    mutating func copyProperty(_ prop: CSSProp, from s: CSSComputedStyle) {
        switch prop {
        case .color: color = s.color
        case .fontSize: fontSize = s.fontSize
        case .fontFamily: fontFamily = s.fontFamily
        case .fontWeight: fontWeight = s.fontWeight
        case .fontStyle: fontStyle = s.fontStyle
        case .lineHeight: lineHeight = s.lineHeight
        case .display: display = s.display
        case .position: position = s.position
        case .top: top = s.top
        case .right: right = s.right
        case .bottom: bottom = s.bottom
        case .left: left = s.left
        case .float: float = s.float
        case .clear: clear = s.clear
        case .zIndex: zIndex = s.zIndex
        case .width: width = s.width
        case .height: height = s.height
        case .minWidth: minWidth = s.minWidth
        case .minHeight: minHeight = s.minHeight
        case .maxWidth: maxWidth = s.maxWidth
        case .maxHeight: maxHeight = s.maxHeight
        case .marginTop: marginTop = s.marginTop
        case .marginRight: marginRight = s.marginRight
        case .marginBottom: marginBottom = s.marginBottom
        case .marginLeft: marginLeft = s.marginLeft
        case .paddingTop: paddingTop = s.paddingTop
        case .paddingRight: paddingRight = s.paddingRight
        case .paddingBottom: paddingBottom = s.paddingBottom
        case .paddingLeft: paddingLeft = s.paddingLeft
        case .borderTopWidth: borderTopWidth = s.borderTopWidth
        case .borderRightWidth: borderRightWidth = s.borderRightWidth
        case .borderBottomWidth: borderBottomWidth = s.borderBottomWidth
        case .borderLeftWidth: borderLeftWidth = s.borderLeftWidth
        case .borderTopStyle: borderTopStyle = s.borderTopStyle
        case .borderRightStyle: borderRightStyle = s.borderRightStyle
        case .borderBottomStyle: borderBottomStyle = s.borderBottomStyle
        case .borderLeftStyle: borderLeftStyle = s.borderLeftStyle
        case .borderTopColor: borderTopColor = s.borderTopColor
        case .borderRightColor: borderRightColor = s.borderRightColor
        case .borderBottomColor: borderBottomColor = s.borderBottomColor
        case .borderLeftColor: borderLeftColor = s.borderLeftColor
        case .boxSizing: boxSizing = s.boxSizing
        case .backgroundColor: backgroundColor = s.backgroundColor
        case .backgroundImage: backgroundImage = s.backgroundImage
        case .backgroundRepeat: backgroundRepeat = s.backgroundRepeat
        case .textAlign: textAlign = s.textAlign
        case .textDecorationLine: textDecoration = s.textDecoration
        case .textIndent: textIndent = s.textIndent
        case .textTransform: textTransform = s.textTransform
        case .whiteSpace: whiteSpace = s.whiteSpace
        case .verticalAlign: verticalAlign = s.verticalAlign
        case .listStyleType: listStyleType = s.listStyleType
        case .listStylePosition: listStylePosition = s.listStylePosition
        case .visibility: visibility = s.visibility
        case .overflowX: overflowX = s.overflowX
        case .overflowY: overflowY = s.overflowY
        case .opacity: opacity = s.opacity
        case .flexDirection: flexDirection = s.flexDirection
        case .flexWrap: flexWrap = s.flexWrap
        case .flexGrow: flexGrow = s.flexGrow
        case .flexShrink: flexShrink = s.flexShrink
        case .flexBasis: flexBasis = s.flexBasis
        case .justifyContent: justifyContent = s.justifyContent
        case .alignItems: alignItems = s.alignItems
        case .alignSelf: alignSelf = s.alignSelf
        case .rowGap: rowGap = s.rowGap
        case .columnGap: columnGap = s.columnGap
        case .borderCollapse: borderCollapse = s.borderCollapse
        case .borderSpacingH: borderSpacingH = s.borderSpacingH
        case .borderSpacingV: borderSpacingV = s.borderSpacingV
        case .tableLayout: tableLayout = s.tableLayout
        case .content: contentKind = s.contentKind; contentItems = s.contentItems
        case .cursor: cursor = s.cursor
        case .custom: break
        }
    }

    // MARK: Specified -> computed

    private func dimension(_ v: CSSValue, _ ctx: CSSContext) -> CSSDimension {
        switch v {
        case .ident(let s):
            switch s {
            case "none": return .none
            case "min-content": return CSSDimension(kind: .minContent)
            case "max-content": return CSSDimension(kind: .maxContent)
            case "fit-content": return CSSDimension(kind: .fitContent)
            default: return .auto
            }
        case .dimension(let c):
            var d = CSSDimension()
            d.lp = cssResolveCalc(c, fontSize: fontSize, ctx: ctx)
            return d
        default: return .auto
        }
    }

    private func lengthPercentage(_ v: CSSValue, _ ctx: CSSContext) -> CSSLP {
        if case .dimension(let c) = v { return cssResolveCalc(c, fontSize: fontSize, ctx: ctx) }
        return .zero
    }

    private func px(_ v: CSSValue, _ ctx: CSSContext) -> Double {
        if case .dimension(let c) = v { return max(0, cssResolveCalc(c, fontSize: fontSize, ctx: ctx).px) }
        return 0
    }

    private func colorOf(_ v: CSSValue, current: CSSColor) -> CSSColor {
        if case .color(let c) = v {
            switch c {
            case .rgba(let col): return col
            case .currentColor: return current
            }
        }
        return current
    }

    private func kw(_ v: CSSValue) -> UInt8 {
        if case .keyword(let k) = v { return k }
        return 0
    }

    mutating func apply(_ prop: CSSProp, _ v: CSSValue, parent: CSSComputedStyle, ctx: CSSContext) {
        switch prop {
        case .color: color = colorOf(v, current: parent.color)
        case .fontSize:
            switch v {
            case .ident(let s):
                switch s {
                case "xx-small": fontSize = ctx.defaultFontSize * 9 / 16
                case "x-small": fontSize = ctx.defaultFontSize * 10 / 16
                case "small": fontSize = ctx.defaultFontSize * 13 / 16
                case "medium": fontSize = ctx.defaultFontSize
                case "large": fontSize = ctx.defaultFontSize * 18 / 16
                case "x-large": fontSize = ctx.defaultFontSize * 24 / 16
                case "xx-large": fontSize = ctx.defaultFontSize * 32 / 16
                case "xxx-large": fontSize = ctx.defaultFontSize * 48 / 16
                case "larger": fontSize = parent.fontSize * 1.2
                case "smaller": fontSize = parent.fontSize / 1.2
                default: break
                }
            case .dimension(let c):
                let l = cssResolveCalc(c, fontSize: parent.fontSize, ctx: ctx)
                fontSize = max(0, l.resolve(parent.fontSize))
            default: break
            }
        case .fontFamily:
            if case .list(let items) = v {
                var names: [String] = []
                for i in items { if case .string(let s) = i { names.append(s) } }
                if !names.isEmpty { fontFamily = names }
            }
        case .fontWeight:
            switch v {
            case .ident(let s):
                switch s {
                case "normal": fontWeight = 400
                case "bold": fontWeight = 700
                case "bolder":
                    let w = parent.fontWeight
                    fontWeight = w < 350 ? 400 : (w < 550 ? 700 : 900)
                case "lighter":
                    let w = parent.fontWeight
                    fontWeight = w < 550 ? 100 : (w < 750 ? 400 : 700)
                default: break
                }
            case .number(let n, _): fontWeight = Int(max(1, min(1000, n)))
            default: break
            }
        case .fontStyle: fontStyle = CSSFontStyle(cssIndex: kw(v))
        case .lineHeight:
            switch v {
            case .number(let n, _):
                lineHeight.kind = .number; lineHeight.value = n
            case .dimension(let c):
                lineHeight.kind = .length
                lineHeight.value = max(0, cssResolveCalc(c, fontSize: fontSize, ctx: ctx).resolve(fontSize))
            default: lineHeight = CSSLineHeight()
            }
        case .display: display = CSSDisplay(cssIndex: kw(v))
        case .position: position = CSSPosition(cssIndex: kw(v))
        case .top: top = dimension(v, ctx)
        case .right: right = dimension(v, ctx)
        case .bottom: bottom = dimension(v, ctx)
        case .left: left = dimension(v, ctx)
        case .float: float = CSSFloat(cssIndex: kw(v))
        case .clear: clear = CSSClear(cssIndex: kw(v))
        case .zIndex:
            if case .number(let n, _) = v { zIndex = Int(max(-2e9, min(2e9, n))) } else { zIndex = nil }
        case .width: width = dimension(v, ctx)
        case .height: height = dimension(v, ctx)
        case .minWidth: minWidth = dimension(v, ctx)
        case .minHeight: minHeight = dimension(v, ctx)
        case .maxWidth: maxWidth = dimension(v, ctx)
        case .maxHeight: maxHeight = dimension(v, ctx)
        case .marginTop: marginTop = dimension(v, ctx)
        case .marginRight: marginRight = dimension(v, ctx)
        case .marginBottom: marginBottom = dimension(v, ctx)
        case .marginLeft: marginLeft = dimension(v, ctx)
        case .paddingTop: paddingTop = lengthPercentage(v, ctx)
        case .paddingRight: paddingRight = lengthPercentage(v, ctx)
        case .paddingBottom: paddingBottom = lengthPercentage(v, ctx)
        case .paddingLeft: paddingLeft = lengthPercentage(v, ctx)
        case .borderTopWidth: borderTopWidth = px(v, ctx)
        case .borderRightWidth: borderRightWidth = px(v, ctx)
        case .borderBottomWidth: borderBottomWidth = px(v, ctx)
        case .borderLeftWidth: borderLeftWidth = px(v, ctx)
        case .borderTopStyle: borderTopStyle = CSSBorderStyle(cssIndex: kw(v))
        case .borderRightStyle: borderRightStyle = CSSBorderStyle(cssIndex: kw(v))
        case .borderBottomStyle: borderBottomStyle = CSSBorderStyle(cssIndex: kw(v))
        case .borderLeftStyle: borderLeftStyle = CSSBorderStyle(cssIndex: kw(v))
        case .borderTopColor: borderTopColor = colorOf(v, current: color)
        case .borderRightColor: borderRightColor = colorOf(v, current: color)
        case .borderBottomColor: borderBottomColor = colorOf(v, current: color)
        case .borderLeftColor: borderLeftColor = colorOf(v, current: color)
        case .boxSizing: boxSizing = CSSBoxSizing(cssIndex: kw(v))
        case .backgroundColor: backgroundColor = colorOf(v, current: color)
        case .backgroundImage:
            if case .url(let u) = v { backgroundImage = u } else { backgroundImage = nil }
        case .backgroundRepeat: backgroundRepeat = CSSBackgroundRepeat(cssIndex: kw(v))
        case .textAlign: textAlign = CSSTextAlign(cssIndex: kw(v))
        case .textDecorationLine:
            if case .number(let n, _) = v { textDecoration = CSSTextDecoration(rawValue: UInt8(truncatingIfNeeded: Int(n))) }
        case .textIndent: textIndent = lengthPercentage(v, ctx)
        case .textTransform: textTransform = CSSTextTransform(cssIndex: kw(v))
        case .whiteSpace: whiteSpace = CSSWhiteSpace(cssIndex: kw(v))
        case .verticalAlign:
            var va = CSSVerticalAlign()
            switch v {
            case .keyword(let k): va.kind = CSSVerticalAlignKind(cssIndex: k)
            case .dimension(let c):
                let l = cssResolveCalc(c, fontSize: fontSize, ctx: ctx)
                va.kind = .length
                va.lengthPx = l.resolve(lineHeightPx)
            default: break
            }
            verticalAlign = va
        case .listStyleType: listStyleType = CSSListStyleType(cssIndex: kw(v))
        case .listStylePosition: listStylePosition = CSSListStylePosition(cssIndex: kw(v))
        case .visibility: visibility = CSSVisibility(cssIndex: kw(v))
        case .overflowX: overflowX = CSSOverflow(cssIndex: kw(v))
        case .overflowY: overflowY = CSSOverflow(cssIndex: kw(v))
        case .opacity: if case .number(let n, _) = v { opacity = n }
        case .flexDirection: flexDirection = CSSFlexDirection(cssIndex: kw(v))
        case .flexWrap: flexWrap = CSSFlexWrap(cssIndex: kw(v))
        case .flexGrow: if case .number(let n, _) = v { flexGrow = n }
        case .flexShrink: if case .number(let n, _) = v { flexShrink = n }
        case .flexBasis: flexBasis = dimension(v, ctx)
        case .justifyContent: justifyContent = CSSJustifyContent(cssIndex: kw(v))
        case .alignItems: alignItems = CSSAlign(cssIndex: kw(v))
        case .alignSelf: alignSelf = CSSAlign(cssIndex: kw(v))
        case .rowGap: rowGap = lengthPercentage(v, ctx)
        case .columnGap: columnGap = lengthPercentage(v, ctx)
        case .borderCollapse: borderCollapse = CSSBorderCollapse(cssIndex: kw(v))
        case .borderSpacingH: borderSpacingH = px(v, ctx)
        case .borderSpacingV: borderSpacingV = px(v, ctx)
        case .tableLayout: tableLayout = CSSTableLayout(cssIndex: kw(v))
        case .content:
            switch v {
            case .ident(let s): contentKind = s == "none" ? .none : .normal; contentItems = []
            case .list(let items):
                var out: [String] = []
                for i in items {
                    switch i {
                    case .string(let s): out.append(s)
                    case .ident(let s): out.append("\u{1}" + String(s.dropFirst(5)))   // attr(name), resolved later
                    default: break
                    }
                }
                contentKind = out.isEmpty ? .none : .items
                contentItems = out
            default: break
            }
        case .cursor: if case .ident(let s) = v { cursor = s }
        case .custom: break
        }
    }

    /// Final adjustments once every property is applied.
    mutating func finalize(explicit: [Bool], isRoot: Bool) {
        // Border colors default to currentColor.
        if !explicit[Int(CSSProp.borderTopColor.rawValue)] { borderTopColor = color }
        if !explicit[Int(CSSProp.borderRightColor.rawValue)] { borderRightColor = color }
        if !explicit[Int(CSSProp.borderBottomColor.rawValue)] { borderBottomColor = color }
        if !explicit[Int(CSSProp.borderLeftColor.rawValue)] { borderLeftColor = color }
        if !borderTopStyle.isVisible { borderTopWidth = 0 }
        if !borderRightStyle.isVisible { borderRightWidth = 0 }
        if !borderBottomStyle.isVisible { borderBottomWidth = 0 }
        if !borderLeftStyle.isVisible { borderLeftWidth = 0 }
        if position == .absolute || position == .fixed { float = .none }
        // Blockification of floats, absolutely positioned boxes and the root.
        if (float != .none || position == .absolute || position == .fixed || isRoot) && display != .none {
            switch display {
            case .inline, .inlineBlock, .tableRow, .tableRowGroup, .tableHeaderGroup, .tableFooterGroup,
                 .tableColumn, .tableColumnGroup, .tableCell, .tableCaption:
                display = .block
            case .inlineTable: display = .table
            case .inlineFlex: display = .flex
            default: break
            }
        }
    }
}
