// HTML tokenizer (WHATWG "Tokenization"), push style: tokens go straight
// to the tree builder. Works on Unicode scalars (decoded from UTF-8 once,
// with CR/LF normalised), so there is no per-character String work.
//
// Simplifications: the comment "less-than sign" states only matter
// for parse errors and are folded into the comment state, and parse errors
// are not reported.

let htmlEOF: UInt32 = 0xFFFF_FFFF

enum HTMLTokState {
    case data, rcdata, rawtext, scriptData, plaintext
    case tagOpen, endTagOpen, tagName
    case beforeAttrName, attrName, afterAttrName, beforeAttrValue
    case attrValueDQ, attrValueSQ, attrValueUQ, afterAttrValueQuoted, selfClosingStart
    case bogusComment, markupDeclOpen
    case commentStart, commentStartDash, comment, commentEndDash, commentEnd, commentEndBang
    case doctype, beforeDoctypeName, doctypeName, afterDoctypeName
    case afterDoctypePublicKw, beforeDoctypePublicID, doctypePublicIDDQ, doctypePublicIDSQ
    case afterDoctypePublicID, betweenDoctypePubSys
    case afterDoctypeSystemKw, beforeDoctypeSystemID, doctypeSystemIDDQ, doctypeSystemIDSQ
    case afterDoctypeSystemID, bogusDoctype
    case cdataSection, cdataBracket, cdataEnd
    case scriptLT, scriptEscapeStart, scriptEscapeStartDash
    case scriptEscaped, scriptEscapedDash, scriptEscapedDashDash, scriptEscapedLT
    case scriptDoubleEscapeStart, scriptDoubleEscaped, scriptDoubleEscapedDash
    case scriptDoubleEscapedDashDash, scriptDoubleEscapedLT, scriptDoubleEscapeEnd
}

/// Decode UTF-8 to scalars: invalid sequences become U+FFFD, CRLF and CR
/// become LF. Stops after `maxBytes` input bytes.
func htmlDecodeInput(_ bytes: [UInt8], maxBytes: Int) -> (scalars: [UInt32], truncated: Bool) {
    let n = min(bytes.count, maxBytes)
    var out: [UInt32] = []
    out.reserveCapacity(n)
    var i = 0
    while i < n {
        let b = bytes[i]
        if b < 0x80 {
            if b == 0x0d {
                out.append(0x0a)
                if i + 1 < n && bytes[i + 1] == 0x0a { i += 1 }
            } else { out.append(UInt32(b)) }
            i += 1
            continue
        }
        var need = 0
        var cp: UInt32 = 0
        var lo: UInt8 = 0x80, hi: UInt8 = 0xbf
        switch b {
        case 0xc2...0xdf: need = 1; cp = UInt32(b & 0x1f)
        case 0xe0: need = 2; cp = UInt32(b & 0x0f); lo = 0xa0
        case 0xe1...0xec, 0xee...0xef: need = 2; cp = UInt32(b & 0x0f)
        case 0xed: need = 2; cp = UInt32(b & 0x0f); hi = 0x9f
        case 0xf0: need = 3; cp = UInt32(b & 0x07); lo = 0x90
        case 0xf1...0xf3: need = 3; cp = UInt32(b & 0x07)
        case 0xf4: need = 3; cp = UInt32(b & 0x07); hi = 0x8f
        default: break
        }
        if need == 0 { out.append(0xfffd); i += 1; continue }
        var j = i + 1
        var ok = true
        var k = 0
        while k < need {
            if j >= n { ok = false; break }
            let c = bytes[j]
            if c < lo || c > hi { ok = false; break }
            lo = 0x80; hi = 0xbf
            cp = (cp << 6) | UInt32(c & 0x3f)
            j += 1; k += 1
        }
        out.append(ok ? cp : 0xfffd)
        i = j  // on failure this skips the valid prefix (maximal subpart)
    }
    return (out, n < bytes.count)
}

func htmlAppendUTF8(_ out: inout [UInt8], _ c: UInt32) {
    if c < 0x80 { out.append(UInt8(truncatingIfNeeded: c)) }
    else if c < 0x800 {
        out.append(UInt8(truncatingIfNeeded: 0xc0 | (c >> 6)))
        out.append(UInt8(truncatingIfNeeded: 0x80 | (c & 0x3f)))
    } else if c < 0x10000 {
        out.append(UInt8(truncatingIfNeeded: 0xe0 | (c >> 12)))
        out.append(UInt8(truncatingIfNeeded: 0x80 | ((c >> 6) & 0x3f)))
        out.append(UInt8(truncatingIfNeeded: 0x80 | (c & 0x3f)))
    } else {
        out.append(UInt8(truncatingIfNeeded: 0xf0 | ((c >> 18) & 7)))
        out.append(UInt8(truncatingIfNeeded: 0x80 | ((c >> 12) & 0x3f)))
        out.append(UInt8(truncatingIfNeeded: 0x80 | ((c >> 6) & 0x3f)))
        out.append(UInt8(truncatingIfNeeded: 0x80 | (c & 0x3f)))
    }
}

@inline(__always) func htmlIsAlpha(_ c: UInt32) -> Bool {
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)
}
@inline(__always) func htmlIsAlnum(_ c: UInt32) -> Bool {
    htmlIsAlpha(c) || (c >= 0x30 && c <= 0x39)
}
@inline(__always) func htmlIsSpace(_ c: UInt32) -> Bool {
    c == 0x20 || c == 0x0a || c == 0x09 || c == 0x0c || c == 0x0d
}

final class HTMLTokenizer {
    let input: [UInt32]
    var pos = 0
    var state: HTMLTokState = .data
    unowned(unsafe) var tb: HTMLTreeBuilder?
    /// Name of the last start tag emitted (for "appropriate end tag").
    var lastStartTag: [UInt8] = []
    var scriptTemp: [UInt8] = []

    // Current tag token.
    var tagName: [UInt8] = []
    var tagIsEnd = false
    var tagSelfClosing = false
    var tagAttrs: [HTMLAttribute] = []
    var inAttr = false
    var attrName: [UInt8] = []
    var attrValue: [UInt8] = []
    // Current comment / doctype.
    var commentData: [UInt8] = []
    var dtName: [UInt8] = []
    var dtHasName = false
    var dtPublic: [UInt8] = []
    var dtHasPublic = false
    var dtSystem: [UInt8] = []
    var dtHasSystem = false
    var dtForceQuirks = false

    init(input: [UInt32]) {
        self.input = input
    }

    @inline(__always) private func next() -> UInt32 {
        if pos < input.count {
            let c = input[pos]
            pos += 1
            return c
        }
        pos += 1
        return htmlEOF
    }
    @inline(__always) private func reconsume() { pos -= 1 }

    // ------------------------------------------------------------ emitters

    private func startTagToken(isEnd: Bool) {
        tagName.removeAll(keepingCapacity: true)
        tagIsEnd = isEnd
        tagSelfClosing = false
        tagAttrs = []
        inAttr = false
    }

    private func flushAttr() {
        guard inAttr else { return }
        inAttr = false
        let name = String(decoding: attrName, as: UTF8.self)
        for a in tagAttrs where a.name == name { return }
        tagAttrs.append(HTMLAttribute(name: name, value: String(decoding: attrValue, as: UTF8.self)))
    }

    private func beginAttr() {
        flushAttr()
        inAttr = true
        attrName.removeAll(keepingCapacity: true)
        attrValue.removeAll(keepingCapacity: true)
    }

    private func emitTag(_ tb: HTMLTreeBuilder) {
        flushAttr()
        let name = String(decoding: tagName, as: UTF8.self)
        if tagIsEnd {
            tb.endTag(name: name)
        } else {
            lastStartTag = tagName
            let attrs = tagAttrs
            tagAttrs = []
            tb.startTag(name: name, attrs: attrs, selfClosing: tagSelfClosing)
        }
    }

    private func emitComment(_ tb: HTMLTreeBuilder) {
        tb.comment(commentData)
        commentData.removeAll(keepingCapacity: true)
    }

    private func emitDoctype(_ tb: HTMLTreeBuilder) {
        tb.doctype(name: dtHasName ? dtName : nil, publicID: dtHasPublic ? dtPublic : nil,
                   systemID: dtHasSystem ? dtSystem : nil, forceQuirks: dtForceQuirks)
    }

    private func newDoctype() {
        dtName = []; dtHasName = false
        dtPublic = []; dtHasPublic = false
        dtSystem = []; dtHasSystem = false
        dtForceQuirks = false
    }

    @inline(__always) private func lower(_ c: UInt32) -> UInt32 {
        (c >= 0x41 && c <= 0x5a) ? c + 0x20 : c
    }

    /// Does the input at `pos` match `s` (ASCII, case-insensitively if asked)?
    private func lookahead(_ s: StaticString, ignoreCase: Bool) -> Bool {
        let n = s.utf8CodeUnitCount
        if pos + n > input.count { return false }
        let p = s.utf8Start
        var i = 0
        while i < n {
            var c = input[pos + i]
            if ignoreCase { c = lower(c) }
            if c != UInt32(p[i]) { return false }
            i += 1
        }
        return true
    }

    /// In RCDATA/RAWTEXT/script data, after '<': is this "/name" followed by
    /// whitespace, '/' or '>'? If so, set up the end tag token and consume
    /// the name (the next state continues as "before attribute name").
    private func tryAppropriateEndTag() -> Bool {
        guard pos < input.count, input[pos] == 0x2f else { return false }
        let n = lastStartTag.count
        if n == 0 || pos + 1 + n >= input.count { return false }
        var i = 0
        while i < n {
            if lower(input[pos + 1 + i]) != UInt32(lastStartTag[i]) { return false }
            i += 1
        }
        let after = input[pos + 1 + n]
        guard htmlIsSpace(after) || after == 0x2f || after == 0x3e else { return false }
        pos += 1 + n
        startTagToken(isEnd: true)
        tagName = lastStartTag
        state = .beforeAttrName
        return true
    }

    // ----------------------------------------------------- character refs

    /// After '&' (pos just past it). On a match, consumes the reference and
    /// returns its code point(s); otherwise leaves pos and returns nil (the
    /// caller then emits '&' itself).
    private func consumeCharRef(inAttribute: Bool) -> (UInt32, UInt32)? {
        guard pos < input.count else { return nil }
        let c = input[pos]
        if c == 0x23 { return consumeNumericRef() }
        guard htmlIsAlnum(c) else { return nil }
        var run: [UInt8] = []
        var i = pos
        while i < input.count && run.count < 32 && htmlIsAlnum(input[i]) {
            run.append(UInt8(truncatingIfNeeded: input[i]))
            i += 1
        }
        if i < input.count && run.count < 32 && input[i] == 0x3b { run.append(0x3b) }
        var len = run.count
        while len >= 2 {
            if let v = htmlEntityFind(run, len) {
                let semi = run[len - 1] == 0x3b
                if inAttribute && !semi {
                    let nx: UInt32 = pos + len < input.count ? input[pos + len] : htmlEOF
                    if nx == 0x3d || htmlIsAlnum(nx) { return nil }
                }
                pos += len
                return v
            }
            len -= 1
        }
        return nil
    }

    private func consumeNumericRef() -> (UInt32, UInt32)? {
        var i = pos + 1  // past '#'
        var hex = false
        if i < input.count && (input[i] == 0x78 || input[i] == 0x58) { hex = true; i += 1 }
        var value: UInt32 = 0
        var digits = 0
        while i < input.count {
            let c = input[i]
            var d: UInt32
            if c >= 0x30 && c <= 0x39 { d = c - 0x30 }
            else if hex && c >= 0x61 && c <= 0x66 { d = c - 0x61 + 10 }
            else if hex && c >= 0x41 && c <= 0x46 { d = c - 0x41 + 10 }
            else { break }
            if value < 0x110000 { value = value * (hex ? 16 : 10) + d }
            digits += 1
            i += 1
        }
        if digits == 0 { return nil }
        if i < input.count && input[i] == 0x3b { i += 1 }
        pos = i
        return (htmlNumericRefValue(value), 0)
    }

    @inline(__always) private func emitRef(_ tb: HTMLTreeBuilder, _ v: (UInt32, UInt32)) {
        tb.char(v.0)
        if v.1 != 0 { tb.char(v.1) }
    }
    private func appendRef(_ v: (UInt32, UInt32)) {
        htmlAppendUTF8(&attrValue, v.0)
        if v.1 != 0 { htmlAppendUTF8(&attrValue, v.1) }
    }

    // ----------------------------------------------------------------- run

    func run() {
        guard let tb = tb else { return }
        while true {
            if tb.stopped { return }
            switch state {
            case .data:
                let c = next()
                switch c {
                case 0x26:
                    if let v = consumeCharRef(inAttribute: false) { emitRef(tb, v) } else { tb.char(0x26) }
                case 0x3c: state = .tagOpen
                case htmlEOF: tb.eof(); return
                default: tb.char(c)
                }
            case .rcdata:
                let c = next()
                switch c {
                case 0x26:
                    if let v = consumeCharRef(inAttribute: false) { emitRef(tb, v) } else { tb.char(0x26) }
                case 0x3c:
                    if !tryAppropriateEndTag() { tb.char(0x3c) }
                case 0: tb.char(0xfffd)
                case htmlEOF: tb.eof(); return
                default: tb.char(c)
                }
            case .rawtext:
                let c = next()
                switch c {
                case 0x3c:
                    if !tryAppropriateEndTag() { tb.char(0x3c) }
                case 0: tb.char(0xfffd)
                case htmlEOF: tb.eof(); return
                default: tb.char(c)
                }
            case .scriptData:
                let c = next()
                if c == 0x3c { state = .scriptLT }
                else if c == 0 { tb.char(0xfffd) }
                else if c == htmlEOF { tb.eof(); return }
                else { tb.char(c) }
            case .scriptLT:
                if tryAppropriateEndTag() { continue }
                let c = next()
                if c == 0x21 { tb.char(0x3c); tb.char(0x21); state = .scriptEscapeStart }
                else { tb.char(0x3c); reconsume(); state = .scriptData }
            case .scriptEscapeStart:
                let c = next()
                if c == 0x2d { tb.char(0x2d); state = .scriptEscapeStartDash }
                else { reconsume(); state = .scriptData }
            case .scriptEscapeStartDash:
                let c = next()
                if c == 0x2d { tb.char(0x2d); state = .scriptEscapedDashDash }
                else { reconsume(); state = .scriptData }
            case .scriptEscaped:
                let c = next()
                if c == 0x2d { tb.char(0x2d); state = .scriptEscapedDash }
                else if c == 0x3c { state = .scriptEscapedLT }
                else if c == 0 { tb.char(0xfffd) }
                else if c == htmlEOF { tb.eof(); return }
                else { tb.char(c) }
            case .scriptEscapedDash:
                let c = next()
                if c == 0x2d { tb.char(0x2d); state = .scriptEscapedDashDash }
                else if c == 0x3c { state = .scriptEscapedLT }
                else if c == htmlEOF { tb.eof(); return }
                else { tb.char(c == 0 ? 0xfffd : c); state = .scriptEscaped }
            case .scriptEscapedDashDash:
                let c = next()
                if c == 0x2d { tb.char(0x2d) }
                else if c == 0x3c { state = .scriptEscapedLT }
                else if c == 0x3e { tb.char(0x3e); state = .scriptData }
                else if c == htmlEOF { tb.eof(); return }
                else { tb.char(c == 0 ? 0xfffd : c); state = .scriptEscaped }
            case .scriptEscapedLT:
                if tryAppropriateEndTag() { continue }
                let c = next()
                if htmlIsAlpha(c) { scriptTemp.removeAll(keepingCapacity: true); tb.char(0x3c); reconsume(); state = .scriptDoubleEscapeStart }
                else { tb.char(0x3c); reconsume(); state = .scriptEscaped }
            case .scriptDoubleEscapeStart:
                let c = next()
                if htmlIsSpace(c) || c == 0x2f || c == 0x3e {
                    state = scriptTemp == [0x73, 0x63, 0x72, 0x69, 0x70, 0x74] ? .scriptDoubleEscaped : .scriptEscaped
                    tb.char(c)
                } else if htmlIsAlpha(c) { scriptTemp.append(UInt8(truncatingIfNeeded: lower(c))); tb.char(c) }
                else { reconsume(); state = .scriptEscaped }
            case .scriptDoubleEscaped:
                let c = next()
                if c == 0x2d { tb.char(0x2d); state = .scriptDoubleEscapedDash }
                else if c == 0x3c { tb.char(0x3c); state = .scriptDoubleEscapedLT }
                else if c == 0 { tb.char(0xfffd) }
                else if c == htmlEOF { tb.eof(); return }
                else { tb.char(c) }
            case .scriptDoubleEscapedDash:
                let c = next()
                if c == 0x2d { tb.char(0x2d); state = .scriptDoubleEscapedDashDash }
                else if c == 0x3c { tb.char(0x3c); state = .scriptDoubleEscapedLT }
                else if c == htmlEOF { tb.eof(); return }
                else { tb.char(c == 0 ? 0xfffd : c); state = .scriptDoubleEscaped }
            case .scriptDoubleEscapedDashDash:
                let c = next()
                if c == 0x2d { tb.char(0x2d) }
                else if c == 0x3c { tb.char(0x3c); state = .scriptDoubleEscapedLT }
                else if c == 0x3e { tb.char(0x3e); state = .scriptData }
                else if c == htmlEOF { tb.eof(); return }
                else { tb.char(c == 0 ? 0xfffd : c); state = .scriptDoubleEscaped }
            case .scriptDoubleEscapedLT:
                let c = next()
                if c == 0x2f { scriptTemp.removeAll(keepingCapacity: true); tb.char(0x2f); state = .scriptDoubleEscapeEnd }
                else { reconsume(); state = .scriptDoubleEscaped }
            case .scriptDoubleEscapeEnd:
                let c = next()
                if htmlIsSpace(c) || c == 0x2f || c == 0x3e {
                    state = scriptTemp == [0x73, 0x63, 0x72, 0x69, 0x70, 0x74] ? .scriptEscaped : .scriptDoubleEscaped
                    tb.char(c)
                } else if htmlIsAlpha(c) { scriptTemp.append(UInt8(truncatingIfNeeded: lower(c))); tb.char(c) }
                else { reconsume(); state = .scriptDoubleEscaped }
            case .plaintext:
                let c = next()
                if c == htmlEOF { tb.eof(); return }
                tb.char(c == 0 ? 0xfffd : c)
            case .tagOpen:
                let c = next()
                if c == 0x21 { state = .markupDeclOpen }
                else if c == 0x2f { state = .endTagOpen }
                else if htmlIsAlpha(c) { startTagToken(isEnd: false); reconsume(); state = .tagName }
                else if c == 0x3f { commentData.removeAll(keepingCapacity: true); reconsume(); state = .bogusComment }
                else if c == htmlEOF { tb.char(0x3c); tb.eof(); return }
                else { tb.char(0x3c); reconsume(); state = .data }
            case .endTagOpen:
                let c = next()
                if htmlIsAlpha(c) { startTagToken(isEnd: true); reconsume(); state = .tagName }
                else if c == 0x3e { state = .data }
                else if c == htmlEOF { tb.char(0x3c); tb.char(0x2f); tb.eof(); return }
                else { commentData.removeAll(keepingCapacity: true); reconsume(); state = .bogusComment }
            case .tagName:
                let c = next()
                if htmlIsSpace(c) { state = .beforeAttrName }
                else if c == 0x2f { state = .selfClosingStart }
                else if c == 0x3e { state = .data; emitTag(tb) }
                else if c == htmlEOF { tb.eof(); return }
                else if c == 0 { htmlAppendUTF8(&tagName, 0xfffd) }
                else { htmlAppendUTF8(&tagName, lower(c)) }
            case .beforeAttrName:
                let c = next()
                if htmlIsSpace(c) { continue }
                if c == 0x2f || c == 0x3e || c == htmlEOF { reconsume(); state = .afterAttrName }
                else if c == 0x3d { beginAttr(); attrName.append(0x3d); state = .attrName }
                else { beginAttr(); reconsume(); state = .attrName }
            case .attrName:
                let c = next()
                if htmlIsSpace(c) || c == 0x2f || c == 0x3e || c == htmlEOF { reconsume(); state = .afterAttrName }
                else if c == 0x3d { state = .beforeAttrValue }
                else if c == 0 { htmlAppendUTF8(&attrName, 0xfffd) }
                else { htmlAppendUTF8(&attrName, lower(c)) }
            case .afterAttrName:
                let c = next()
                if htmlIsSpace(c) { continue }
                if c == 0x2f { state = .selfClosingStart }
                else if c == 0x3d { state = .beforeAttrValue }
                else if c == 0x3e { state = .data; emitTag(tb) }
                else if c == htmlEOF { tb.eof(); return }
                else { beginAttr(); reconsume(); state = .attrName }
            case .beforeAttrValue:
                let c = next()
                if htmlIsSpace(c) { continue }
                if c == 0x22 { state = .attrValueDQ }
                else if c == 0x27 { state = .attrValueSQ }
                else if c == 0x3e { state = .data; emitTag(tb) }
                else { reconsume(); state = .attrValueUQ }
            case .attrValueDQ, .attrValueSQ:
                let q: UInt32 = state == .attrValueDQ ? 0x22 : 0x27
                let c = next()
                if c == q { state = .afterAttrValueQuoted }
                else if c == 0x26 {
                    if let v = consumeCharRef(inAttribute: true) { appendRef(v) } else { attrValue.append(0x26) }
                }
                else if c == 0 { htmlAppendUTF8(&attrValue, 0xfffd) }
                else if c == htmlEOF { tb.eof(); return }
                else { htmlAppendUTF8(&attrValue, c) }
            case .attrValueUQ:
                let c = next()
                if htmlIsSpace(c) { state = .beforeAttrName }
                else if c == 0x26 {
                    if let v = consumeCharRef(inAttribute: true) { appendRef(v) } else { attrValue.append(0x26) }
                }
                else if c == 0x3e { state = .data; emitTag(tb) }
                else if c == 0 { htmlAppendUTF8(&attrValue, 0xfffd) }
                else if c == htmlEOF { tb.eof(); return }
                else { htmlAppendUTF8(&attrValue, c) }
            case .afterAttrValueQuoted:
                let c = next()
                if htmlIsSpace(c) { state = .beforeAttrName }
                else if c == 0x2f { state = .selfClosingStart }
                else if c == 0x3e { state = .data; emitTag(tb) }
                else if c == htmlEOF { tb.eof(); return }
                else { reconsume(); state = .beforeAttrName }
            case .selfClosingStart:
                let c = next()
                if c == 0x3e { tagSelfClosing = true; state = .data; emitTag(tb) }
                else if c == htmlEOF { tb.eof(); return }
                else { reconsume(); state = .beforeAttrName }
            case .bogusComment:
                let c = next()
                if c == 0x3e { state = .data; emitComment(tb) }
                else if c == htmlEOF { emitComment(tb); tb.eof(); return }
                else if c == 0 { htmlAppendUTF8(&commentData, 0xfffd) }
                else { htmlAppendUTF8(&commentData, c) }
            case .markupDeclOpen:
                commentData.removeAll(keepingCapacity: true)
                if lookahead("--", ignoreCase: false) { pos += 2; state = .commentStart }
                else if lookahead("doctype", ignoreCase: true) { pos += 7; state = .doctype }
                else if tb.inForeignContent && lookahead("[CDATA[", ignoreCase: false) { pos += 7; state = .cdataSection }
                else { state = .bogusComment }
            case .commentStart:
                let c = next()
                if c == 0x2d { state = .commentStartDash }
                else if c == 0x3e { state = .data; emitComment(tb) }
                else { reconsume(); state = .comment }
            case .commentStartDash:
                let c = next()
                if c == 0x2d { state = .commentEnd }
                else if c == 0x3e { state = .data; emitComment(tb) }
                else if c == htmlEOF { emitComment(tb); tb.eof(); return }
                else { commentData.append(0x2d); reconsume(); state = .comment }
            case .comment:
                let c = next()
                if c == 0x2d { state = .commentEndDash }
                else if c == 0 { htmlAppendUTF8(&commentData, 0xfffd) }
                else if c == htmlEOF { emitComment(tb); tb.eof(); return }
                else { htmlAppendUTF8(&commentData, c) }
            case .commentEndDash:
                let c = next()
                if c == 0x2d { state = .commentEnd }
                else if c == htmlEOF { emitComment(tb); tb.eof(); return }
                else { commentData.append(0x2d); reconsume(); state = .comment }
            case .commentEnd:
                let c = next()
                if c == 0x3e { state = .data; emitComment(tb) }
                else if c == 0x21 { state = .commentEndBang }
                else if c == 0x2d { commentData.append(0x2d) }
                else if c == htmlEOF { emitComment(tb); tb.eof(); return }
                else { commentData.append(0x2d); commentData.append(0x2d); reconsume(); state = .comment }
            case .commentEndBang:
                let c = next()
                if c == 0x2d { commentData.append(contentsOf: [0x2d, 0x2d, 0x21]); state = .commentEndDash }
                else if c == 0x3e { state = .data; emitComment(tb) }
                else if c == htmlEOF { emitComment(tb); tb.eof(); return }
                else { commentData.append(contentsOf: [0x2d, 0x2d, 0x21]); reconsume(); state = .comment }
            case .doctype:
                let c = next()
                if htmlIsSpace(c) { state = .beforeDoctypeName }
                else if c == htmlEOF {
                    newDoctype(); dtForceQuirks = true; emitDoctype(tb); tb.eof(); return
                }
                else { reconsume(); state = .beforeDoctypeName }
            case .beforeDoctypeName:
                let c = next()
                if htmlIsSpace(c) { continue }
                newDoctype()
                if c == 0x3e { dtForceQuirks = true; state = .data; emitDoctype(tb) }
                else if c == htmlEOF { dtForceQuirks = true; emitDoctype(tb); tb.eof(); return }
                else {
                    dtHasName = true
                    htmlAppendUTF8(&dtName, c == 0 ? 0xfffd : lower(c))
                    state = .doctypeName
                }
            case .doctypeName:
                let c = next()
                if htmlIsSpace(c) { state = .afterDoctypeName }
                else if c == 0x3e { state = .data; emitDoctype(tb) }
                else if c == htmlEOF { dtForceQuirks = true; emitDoctype(tb); tb.eof(); return }
                else { htmlAppendUTF8(&dtName, c == 0 ? 0xfffd : lower(c)) }
            case .afterDoctypeName:
                let c = next()
                if htmlIsSpace(c) { continue }
                if c == 0x3e { state = .data; emitDoctype(tb) }
                else if c == htmlEOF { dtForceQuirks = true; emitDoctype(tb); tb.eof(); return }
                else {
                    reconsume()
                    if lookahead("public", ignoreCase: true) { pos += 6; state = .afterDoctypePublicKw }
                    else if lookahead("system", ignoreCase: true) { pos += 6; state = .afterDoctypeSystemKw }
                    else { pos += 1; dtForceQuirks = true; state = .bogusDoctype }
                }
            case .afterDoctypePublicKw:
                let c = next()
                if htmlIsSpace(c) { state = .beforeDoctypePublicID }
                else if c == 0x22 { dtHasPublic = true; state = .doctypePublicIDDQ }
                else if c == 0x27 { dtHasPublic = true; state = .doctypePublicIDSQ }
                else { doctypeFail(tb, c) ; if c == htmlEOF { return } }
            case .beforeDoctypePublicID:
                let c = next()
                if htmlIsSpace(c) { continue }
                if c == 0x22 { dtHasPublic = true; state = .doctypePublicIDDQ }
                else if c == 0x27 { dtHasPublic = true; state = .doctypePublicIDSQ }
                else { doctypeFail(tb, c); if c == htmlEOF { return } }
            case .doctypePublicIDDQ, .doctypePublicIDSQ:
                let q: UInt32 = state == .doctypePublicIDDQ ? 0x22 : 0x27
                let c = next()
                if c == q { state = .afterDoctypePublicID }
                else if c == 0x3e { dtForceQuirks = true; state = .data; emitDoctype(tb) }
                else if c == htmlEOF { dtForceQuirks = true; emitDoctype(tb); tb.eof(); return }
                else { htmlAppendUTF8(&dtPublic, c == 0 ? 0xfffd : c) }
            case .afterDoctypePublicID:
                let c = next()
                if htmlIsSpace(c) { state = .betweenDoctypePubSys }
                else if c == 0x3e { state = .data; emitDoctype(tb) }
                else if c == 0x22 { dtHasSystem = true; state = .doctypeSystemIDDQ }
                else if c == 0x27 { dtHasSystem = true; state = .doctypeSystemIDSQ }
                else { doctypeFail(tb, c); if c == htmlEOF { return } }
            case .betweenDoctypePubSys:
                let c = next()
                if htmlIsSpace(c) { continue }
                if c == 0x3e { state = .data; emitDoctype(tb) }
                else if c == 0x22 { dtHasSystem = true; state = .doctypeSystemIDDQ }
                else if c == 0x27 { dtHasSystem = true; state = .doctypeSystemIDSQ }
                else { doctypeFail(tb, c); if c == htmlEOF { return } }
            case .afterDoctypeSystemKw:
                let c = next()
                if htmlIsSpace(c) { state = .beforeDoctypeSystemID }
                else if c == 0x22 { dtHasSystem = true; state = .doctypeSystemIDDQ }
                else if c == 0x27 { dtHasSystem = true; state = .doctypeSystemIDSQ }
                else { doctypeFail(tb, c); if c == htmlEOF { return } }
            case .beforeDoctypeSystemID:
                let c = next()
                if htmlIsSpace(c) { continue }
                if c == 0x22 { dtHasSystem = true; state = .doctypeSystemIDDQ }
                else if c == 0x27 { dtHasSystem = true; state = .doctypeSystemIDSQ }
                else { doctypeFail(tb, c); if c == htmlEOF { return } }
            case .doctypeSystemIDDQ, .doctypeSystemIDSQ:
                let q: UInt32 = state == .doctypeSystemIDDQ ? 0x22 : 0x27
                let c = next()
                if c == q { state = .afterDoctypeSystemID }
                else if c == 0x3e { dtForceQuirks = true; state = .data; emitDoctype(tb) }
                else if c == htmlEOF { dtForceQuirks = true; emitDoctype(tb); tb.eof(); return }
                else { htmlAppendUTF8(&dtSystem, c == 0 ? 0xfffd : c) }
            case .afterDoctypeSystemID:
                let c = next()
                if htmlIsSpace(c) { continue }
                if c == 0x3e { state = .data; emitDoctype(tb) }
                else if c == htmlEOF { dtForceQuirks = true; emitDoctype(tb); tb.eof(); return }
                else { reconsume(); state = .bogusDoctype }
            case .bogusDoctype:
                let c = next()
                if c == 0x3e { state = .data; emitDoctype(tb) }
                else if c == htmlEOF { emitDoctype(tb); tb.eof(); return }
            case .cdataSection:
                let c = next()
                if c == 0x5d { state = .cdataBracket }
                else if c == htmlEOF { tb.eof(); return }
                else { tb.char(c) }
            case .cdataBracket:
                let c = next()
                if c == 0x5d { state = .cdataEnd } else { tb.char(0x5d); reconsume(); state = .cdataSection }
            case .cdataEnd:
                let c = next()
                if c == 0x5d { tb.char(0x5d) }
                else if c == 0x3e { state = .data }
                else { tb.char(0x5d); tb.char(0x5d); reconsume(); state = .cdataSection }
            }
        }
    }

    /// Shared "anything else" arm of the DOCTYPE keyword/identifier states:
    /// EOF emits and ends; '>' emits with force-quirks; otherwise bogus doctype.
    private func doctypeFail(_ tb: HTMLTreeBuilder, _ c: UInt32) {
        dtForceQuirks = true
        if c == htmlEOF { emitDoctype(tb); tb.eof() }
        else if c == 0x3e { state = .data; emitDoctype(tb) }
        else { reconsume(); state = .bogusDoctype }
    }
}

/// Spec replacement table for numeric character references.
func htmlNumericRefValue(_ v: UInt32) -> UInt32 {
    if v == 0 || v > 0x10ffff || (v >= 0xd800 && v <= 0xdfff) { return 0xfffd }
    if v >= 0x80 && v <= 0x9f {
        let t: [UInt32] = [
            0x20ac, 0x81, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
            0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8d, 0x017d, 0x8f,
            0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
            0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x9d, 0x017e, 0x0178,
        ]
        return t[Int(v - 0x80)]
    }
    return v
}

/// Look up `run[0..<len]` (name without '&', with ';' if present) in the
/// generated entity table. Returns the code point(s); second is 0 if none.
func htmlEntityFind(_ run: [UInt8], _ len: Int) -> (UInt32, UInt32)? {
    let recs = htmlEntityRecords.utf8Start
    let offs = htmlEntityOffsets.utf8Start
    var lo = 0, hi = htmlEntityCount - 1
    while lo <= hi {
        let mid = (lo + hi) >> 1
        let o = htmlB64(offs + mid * 3, 3)
        let nlen = Int(recs[o]) - 0x30
        let name = recs + (o + 1)
        // compare run[0..<len] with name[0..<nlen]
        var cmp = 0
        var i = 0
        let m = min(len, nlen)
        while i < m {
            if run[i] != name[i] { cmp = run[i] < name[i] ? -1 : 1; break }
            i += 1
        }
        if cmp == 0 { cmp = len == nlen ? 0 : (len < nlen ? -1 : 1) }
        if cmp == 0 {
            let v = htmlB64(name + nlen, 4)
            let second = Int(v >> 17)
            return (UInt32(v & 0x1ffff), second == 0 ? 0 : htmlEntitySeconds[second])
        }
        if cmp < 0 { hi = mid - 1 } else { lo = mid + 1 }
    }
    return nil
}

private func htmlB64(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
    var v = 0
    var i = 0
    while i < n {
        let c = Int(p[i])
        var d: Int
        if c >= 0x41 && c <= 0x5a { d = c - 0x41 }
        else if c >= 0x61 && c <= 0x7a { d = c - 0x61 + 26 }
        else if c >= 0x30 && c <= 0x39 { d = c - 0x30 + 52 }
        else if c == 0x2b { d = 62 }
        else { d = 63 }
        v = (v << 6) | d
        i += 1
    }
    return v
}
