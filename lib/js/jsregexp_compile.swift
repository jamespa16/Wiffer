// RegExp character sets, Unicode properties, case canonicalization and the
// bytecode compiler.
//
// Bytecode: [Int32], an opcode word then its operands. The low 8 bits are
// the opcode; bit 8 (JSReOp.back) marks a character op that reads
// backwards (inside a lookbehind). Registers: regs[2i], regs[2i+1] are the
// start/end of group i (-1 when unset), then loop counters and loop entry
// positions. Every register write pushes a restore entry on the backtrack
// stack, so a backtrack restores the exact state of its branch point.
//
//   match                         success
//   char c / charI c              one character (charI: c is canonical)
//   any / anyAll                  . without / with the s flag
//   set k                         character set at sets[k...] (see JSReSetLayout)
//   bol / eol / bolM / eolM       ^ $ (M: multiline)
//   wordB / notWordB              \b \B
//   jump L
//   splitNext L                   try the next instruction, then L
//   splitJump L                   try L, then the next instruction
//   save r                        regs[r] = pos
//   reset lo hi                   regs[lo..<hi] = -1
//   setZero r / savePos r         regs[r] = 0 / pos
//   emptyCheck r                  fail if pos == regs[r]
//   loop c min max greedy L       counted loop head (exit at L)
//   loopTail c min p L            empty check with regs[p] (p < 0: none),
//                                 count += 1, jump to the head at L
//   backref n / backrefI n
//   look kind L                   lookaround body follows; L is after it
//   lookEnd                       the body matched
//   starG / starL min max op arg  simple greedy / lazy loop of one
//                                 character op (forward only)
//   fail

enum JSReOp {
    static let match: Int32 = 0
    static let char: Int32 = 1
    static let charI: Int32 = 2
    static let any: Int32 = 3
    static let anyAll: Int32 = 4
    static let set: Int32 = 5
    static let bol: Int32 = 6
    static let eol: Int32 = 7
    static let bolM: Int32 = 8
    static let eolM: Int32 = 9
    static let wordB: Int32 = 10
    static let notWordB: Int32 = 11
    static let jump: Int32 = 12
    static let splitNext: Int32 = 13
    static let splitJump: Int32 = 14
    static let save: Int32 = 15
    static let reset: Int32 = 16
    static let setZero: Int32 = 17
    static let savePos: Int32 = 18
    static let emptyCheck: Int32 = 19
    static let loop: Int32 = 20
    static let loopTail: Int32 = 21
    static let backref: Int32 = 22
    static let backrefI: Int32 = 23
    static let look: Int32 = 24
    static let lookEnd: Int32 = 25
    static let starG: Int32 = 26
    static let starL: Int32 = 27
    static let fail: Int32 = 28
    static let back: Int32 = 0x100

    static let names = ["match", "char", "charI", "any", "anyAll", "set", "bol", "eol", "bolM", "eolM",
                        "wordB", "notWordB", "jump", "splitNext", "splitJump", "save", "reset", "setZero",
                        "savePos", "emptyCheck", "loop", "loopTail", "backref", "backrefI", "look", "lookEnd",
                        "starG", "starL", "fail"]

    /// Words per instruction (opcode included).
    static func length(_ op: Int32) -> Int {
        switch op & 0xFF {
        case match, bol, eol, bolM, eolM, wordB, notWordB, lookEnd, fail: return 1
        case char, charI, any, anyAll, set, jump, splitNext, splitJump, save, setZero, savePos, emptyCheck, backref, backrefI:
            return 2
        case reset, look: return 3
        case loopTail, starG, starL: return 5
        case loop: return 6
        default: return 1
        }
    }
}

// MARK: Character sets

/// A set of code points (or code units) as sorted, merged inclusive ranges
/// [lo0, hi0, lo1, hi1, ...] once normalized.
struct JSReCharSet {
    var r: [UInt32] = []

    mutating func add(_ lo: UInt32, _ hi: UInt32) { r.append(lo); r.append(hi) }
    mutating func add(_ o: JSReCharSet) { r.append(contentsOf: o.r) }

    mutating func normalize() {
        let n = r.count / 2
        if n == 0 { return }
        var keys: [UInt64] = []
        keys.reserveCapacity(n)
        for k in 0..<n { keys.append(UInt64(r[2 * k]) << 32 | UInt64(r[2 * k + 1])) }
        keys.sort()
        var out: [UInt32] = []
        out.reserveCapacity(r.count)
        for key in keys {
            let lo = UInt32(truncatingIfNeeded: key >> 32), hi = UInt32(truncatingIfNeeded: key)
            if let last = out.last, UInt64(lo) <= UInt64(last) + 1 {
                if hi > last { out[out.count - 1] = hi }
            } else {
                out.append(lo); out.append(hi)
            }
        }
        r = out
    }

    /// Complement within [0, max] (the set must be normalized).
    func inverted(max: UInt32) -> JSReCharSet {
        var o = JSReCharSet()
        var next: UInt32 = 0
        var k = 0
        while k < r.count {
            let lo = r[k], hi = r[k + 1]
            if lo > max { break }
            if lo > next { o.add(next, lo - 1) }
            if hi >= max { next = max &+ 1; break }
            next = hi + 1
            k += 2
        }
        if next <= max { o.add(next, max) }
        return o
    }

    func contains(_ c: UInt32) -> Bool {
        var lo = 0, hi = r.count / 2 - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if c < r[2 * mid] { hi = mid - 1 } else if c > r[2 * mid + 1] { lo = mid + 1 } else { return true }
        }
        return false
    }

    /// self minus o (both normalized).
    func subtracting(_ o: JSReCharSet) -> JSReCharSet {
        if o.r.isEmpty || r.isEmpty { return self }
        var out = JSReCharSet()
        var j = 0
        var k = 0
        while k < r.count {
            var lo = r[k]
            let hi = r[k + 1]
            k += 2
            while j < o.r.count && o.r[j + 1] < lo { j += 2 }
            var jj = j
            var alive = true
            while jj < o.r.count && o.r[jj] <= hi {
                if o.r[jj] > lo { out.add(lo, o.r[jj] - 1) }
                if o.r[jj + 1] >= hi { alive = false; break }
                lo = max(lo, o.r[jj + 1] + 1)
                jj += 2
            }
            if alive { out.add(lo, hi) }
        }
        return out
    }
}

// MARK: Generated tables

private func jsReB64(_ c: UInt8) -> UInt32 {
    if c >= 0x41 && c <= 0x5A { return UInt32(c - 0x41) }
    if c >= 0x61 && c <= 0x7A { return UInt32(c - 0x61 + 26) }
    if c >= 0x30 && c <= 0x39 { return UInt32(c - 0x30 + 52) }
    return c == 0x2B ? 62 : 63
}

/// Reads the base64 varints of a generated table.
struct JSReVarints {
    let p: UnsafePointer<UInt8>
    let n: Int
    var k: Int

    init(_ s: StaticString, at k: Int = 0) {
        p = s.utf8Start
        n = s.utf8CodeUnitCount
        self.k = k
    }

    var atEnd: Bool { k >= n }

    mutating func next() -> UInt32 {
        var v: UInt32 = 0
        var shift: UInt32 = 0
        while k < n {
            let d = jsReB64(p[k])
            k += 1
            v |= (d & 31) << shift
            shift += 5
            if d & 32 == 0 || shift > 25 { break }
        }
        return v
    }
}

/// Look a name up in a generated "alias,alias:number;..." table.
func jsReLookupName(_ table: StaticString, _ name: [UInt16]) -> Int? {
    let p = table.utf8Start
    let n = table.utf8CodeUnitCount
    var k = 0
    while k < n {
        // One entry: aliases then ':' number.
        var matched = false
        while k < n && p[k] != 0x3A {
            var j = 0
            var same = true
            while k < n && p[k] != 0x2C && p[k] != 0x3A {
                if j >= name.count || UInt16(p[k]) != name[j] { same = false }
                j += 1
                k += 1
            }
            if same && j == name.count { matched = true }
            if k < n && p[k] == 0x2C { k += 1 }
        }
        k += 1
        var v = 0
        while k < n && p[k] != 0x3B {
            v = v * 10 + Int(p[k]) - 0x30
            k += 1
        }
        k += 1
        if matched { return v }
    }
    return nil
}

func jsReRunsSet(_ table: StaticString, _ keep: (UInt32) -> Bool) -> JSReCharSet {
    var s = JSReCharSet()
    var v = JSReVarints(table)
    var pos: UInt32 = 0
    while !v.atEnd && pos <= 0x10FFFF {
        let len = v.next() + 1
        let val = v.next()
        if keep(val) { s.add(pos, pos + len - 1) }
        pos += len
    }
    s.normalize()
    return s
}

func jsReGCSet(_ mask: UInt32) -> JSReCharSet {
    jsReRunsSet(jsReGCRuns) { mask & (1 << $0) != 0 }
}

func jsReScriptSet(_ script: Int, extensions: Bool) -> JSReCharSet {
    let base = jsReRunsSet(jsReScriptRuns) { Int($0) == script }
    if !extensions { return base }
    var sets: [[UInt32]] = []
    var sv = JSReVarints(jsReScxSets)
    while !sv.atEnd {
        let n = Int(sv.next())
        var one: [UInt32] = []
        for _ in 0..<n { one.append(sv.next()) }
        sets.append(one)
    }
    var listed = JSReCharSet(), with = JSReCharSet()
    var v = JSReVarints(jsReScxRuns)
    var prev: Int64 = -1
    for _ in 0..<jsReScxRunCount {
        let lo = UInt32(prev + 1) + v.next()
        let hi = lo + v.next()
        let si = Int(v.next())
        prev = Int64(hi)
        listed.add(lo, hi)
        if si < sets.count && sets[si].contains(UInt32(script)) { with.add(lo, hi) }
    }
    listed.normalize()
    var out = base.subtracting(listed)
    out.add(with)
    out.normalize()
    return out
}

func jsReBinarySet(_ id: Int) -> JSReCharSet {
    var s = JSReCharSet()
    switch id {
    case 1000: s.add(0, 0x10FFFF); return s
    case 1001: s.add(0, 0x7F); return s
    case 1002: return jsReGCSet(1).inverted(max: 0x10FFFF)   // Assigned: not Cn
    default: break
    }
    guard id >= 0 && id < jsReBinaryOffsets.count else { return s }
    var v = JSReVarints(jsReBinaryRanges, at: jsReBinaryOffsets[id])
    let count = Int(v.next())
    var prev: Int64 = -1
    for _ in 0..<count {
        let lo = UInt32(prev + 1) + v.next()
        let hi = lo + v.next()
        s.add(lo, hi)
        prev = Int64(hi)
    }
    return s
}

private func jsReIs(_ name: [UInt16], _ s: StaticString) -> Bool {
    let p = s.utf8Start
    guard name.count == s.utf8CodeUnitCount else { return false }
    for k in 0..<name.count where UInt16(p[k]) != name[k] { return false }
    return true
}

/// \p{name=value}: General_Category, Script or Script_Extensions.
func jsRePropertySet(name: [UInt16], value: [UInt16]) -> JSReCharSet? {
    if jsReIs(name, "General_Category") || jsReIs(name, "gc") {
        guard let m = jsReLookupName(jsReGCNames, value) else { return nil }
        return jsReGCSet(UInt32(m))
    }
    let scx = jsReIs(name, "Script_Extensions") || jsReIs(name, "scx")
    if scx || jsReIs(name, "Script") || jsReIs(name, "sc") {
        guard let s = jsReLookupName(jsReScriptNames, value) else { return nil }
        return jsReScriptSet(s, extensions: scx)
    }
    return nil
}

/// \p{value}: a General_Category value or a binary property.
func jsRePropertySet(lone: [UInt16]) -> JSReCharSet? {
    if let m = jsReLookupName(jsReGCNames, lone) { return jsReGCSet(UInt32(m)) }
    if let b = jsReLookupName(jsReBinaryNames, lone) { return jsReBinarySet(b) }
    return nil
}

// MARK: Case canonicalization

func jsReDecodeCaseTable(unicode: Bool) -> [UInt64] {
    let s: StaticString = unicode ? jsReCaseFold : jsReCaseUpper
    let count = unicode ? jsReCaseFoldCount : jsReCaseUpperCount
    let p = s.utf8Start
    var out: [UInt64] = []
    out.reserveCapacity(count)
    for i in 0..<count {
        var v: UInt64 = 0
        for k in 0..<10 { v = v << 6 | UInt64(jsReB64(p[i * 10 + k])) }
        out.append(v)
    }
    return out
}

/// Canonicalize(rer, ch): simple case folding in unicode mode, else the
/// single-unit toUppercase rule. `runs` is jsReDecodeCaseTable(unicode:).
@inline(__always) func jsReCanonicalize(_ c: UInt32, _ runs: [UInt64], unicode: Bool) -> UInt32 {
    if c < 0x80 {
        if unicode { return c >= 0x41 && c <= 0x5A ? c + 32 : c }
        return c >= 0x61 && c <= 0x7A ? c - 32 : c
    }
    return jsReCanonicalizeSlow(c, runs)
}

func jsReCanonicalizeSlow(_ c: UInt32, _ runs: [UInt64]) -> UInt32 {
    var lo = 0, hi = runs.count - 1
    var found = -1
    while lo <= hi {
        let mid = (lo + hi) >> 1
        if UInt32(runs[mid] & 0x1FFFFF) <= c { found = mid; lo = mid + 1 } else { hi = mid - 1 }
    }
    if found < 0 { return c }
    let r = runs[found]
    let start = UInt32(r & 0x1FFFFF)
    let count = UInt32((r >> 21) & 0x7FF)
    let step: UInt32 = (r >> 32) & 1 != 0 ? 2 : 1
    let off = c - start
    if off % step != 0 || off / step >= count { return c }
    let delta = Int64((r >> 33) & 0x7FFFFF) - (1 << 22)
    return UInt32(truncatingIfNeeded: Int64(c) + delta)
}

/// { Canonicalize(c) : c in s } (s normalized).
func jsReCanonicalImage(_ s: JSReCharSet, _ runs: [UInt64]) -> JSReCharSet {
    var moved = JSReCharSet(), images = JSReCharSet()
    for r in runs {
        let start = UInt32(r & 0x1FFFFF)
        let count = UInt32((r >> 21) & 0x7FF)
        let step: UInt32 = (r >> 32) & 1 != 0 ? 2 : 1
        let delta = Int64((r >> 33) & 0x7FFFFF) - (1 << 22)
        if step == 1 { moved.add(start, start + count - 1) }
        var k: UInt32 = 0
        while k < count {
            let c = start + k * step
            if step == 2 { moved.add(c, c) }
            if s.contains(c) {
                let m = UInt32(truncatingIfNeeded: Int64(c) + delta)
                images.add(m, m)
            }
            k += 1
        }
    }
    moved.normalize()
    var out = s.subtracting(moved)
    out.add(images)
    out.normalize()
    return out
}

// MARK: Compiler

/// A compiled set inside JSRegExpProgram.sets, at offset k:
///   [k..k+3] answer bitmap for ASCII input (invert and case already applied)
///   [k+4]    bit 0: invert, bit 1: canonicalize input before the lookup
///   [k+5]    number of ranges, then lo, hi pairs (the canonical image
///            when ignoring case)
enum JSReSetLayout {
    static let header = 6
}

struct JSReCompiler {
    let ast: JSReAST
    let flags: JSRegExpFlags
    let unicode: Bool
    let ignoreCase: Bool
    var code: [Int32] = []
    var sets: [UInt32] = []
    var setOffsets: [Int32]
    var regCount: Int
    var caseRuns: [UInt64] = []
    var firstChar: Int32 = -1
    var anchoredStart = false
    var depth = 0

    static let maxCode = 1 << 22
    static let maxSetWords = 1 << 23

    init(ast: JSReAST, flags: JSRegExpFlags) {
        self.ast = ast
        self.flags = flags
        unicode = flags.unicodeMode
        ignoreCase = flags.ignoreCase
        regCount = 2 * (ast.captureCount + 1)
        setOffsets = [Int32](repeating: -1, count: ast.sets.count * 2)
        if ignoreCase { caseRuns = jsReDecodeCaseTable(unicode: unicode) }
    }

    mutating func compile() throws(JSRegExpError) {
        try emit(ast.root, backward: false)
        code.append(JSReOp.match)
        if code.count > JSReCompiler.maxCode { throw JSRegExpError("regular expression too large") }
        if code.count >= 2 && code[0] == JSReOp.char {
            let c = UInt32(code[1])
            firstChar = c >= 0x10000 ? Int32(0xD800 + ((c - 0x10000) >> 10)) : Int32(c)
            // In unicode mode a trail surrogate may sit inside a pair.
            if unicode && jsReIsTrail(UInt32(firstChar)) { firstChar = -1 }
        }
        anchoredStart = code[0] == JSReOp.bol
    }

    @inline(__always) mutating func op(_ o: Int32, _ args: Int32...) {
        code.append(o)
        code.append(contentsOf: args)
    }

    mutating func allocReg() -> Int32 {
        regCount += 1
        return Int32(regCount - 1)
    }

    func canBeEmpty(_ n: Int32) -> Bool {
        let nd = ast.nodes[Int(n)]
        switch nd.kind {
        case .char, .dot, .set: return false
        case .seq:
            for k in 0..<Int(nd.count) where !canBeEmpty(ast.lists[Int(nd.child) + k]) { return false }
            return true
        case .alt:
            for k in 0..<Int(nd.count) where canBeEmpty(ast.lists[Int(nd.child) + k]) { return true }
            return false
        case .group: return canBeEmpty(nd.child)
        case .quant: return nd.a == 0 || canBeEmpty(nd.child)
        default: return true
        }
    }

    /// The set at ast.sets[i], compiled (cached per set and inversion).
    mutating func compileSet(_ i: Int, inverted: Bool) throws(JSRegExpError) -> Int32 {
        let key = 2 * i + (inverted ? 1 : 0)
        if setOffsets[key] >= 0 { return setOffsets[key] }
        var s = ast.sets[i]
        if ignoreCase { s = jsReCanonicalImage(s, caseRuns) }
        let at = sets.count
        if at + JSReSetLayout.header + s.r.count > JSReCompiler.maxSetWords {
            throw JSRegExpError("regular expression too large")
        }
        var bm: [UInt32] = [0, 0, 0, 0]
        for c in UInt32(0)..<128 {
            let x = ignoreCase ? jsReCanonicalize(c, caseRuns, unicode: unicode) : c
            if s.contains(x) != inverted { bm[Int(c >> 5)] |= 1 << (c & 31) }
        }
        sets.append(contentsOf: bm)
        sets.append((inverted ? 1 : 0) | (ignoreCase ? 2 : 0))
        sets.append(UInt32(s.r.count / 2))
        sets.append(contentsOf: s.r)
        setOffsets[key] = Int32(at)
        return Int32(at)
    }

    /// The single-character op for a char/dot/set node: (op, arg).
    mutating func charOp(_ n: Int32) throws(JSRegExpError) -> (Int32, Int32) {
        let nd = ast.nodes[Int(n)]
        switch nd.kind {
        case .char:
            if ignoreCase {
                let c = jsReCanonicalize(UInt32(nd.a), caseRuns, unicode: unicode)
                return (JSReOp.charI, Int32(c))
            }
            return (JSReOp.char, nd.a)
        case .dot:
            return (flags.dotAll ? JSReOp.anyAll : JSReOp.any, 0)
        default:
            return (JSReOp.set, try compileSet(Int(nd.a), inverted: nd.flag == 1))
        }
    }

    mutating func emit(_ n: Int32, backward: Bool) throws(JSRegExpError) {
        depth += 1
        defer { depth -= 1 }
        if depth > 2 * JSReParser.maxNesting + 16 { throw JSRegExpError("regular expression too deeply nested") }
        if code.count > JSReCompiler.maxCode { throw JSRegExpError("regular expression too large") }
        let nd = ast.nodes[Int(n)]
        let bw: Int32 = backward ? JSReOp.back : 0
        switch nd.kind {
        case .empty:
            break
        case .char, .dot, .set:
            let (o, a) = try charOp(n)
            op(o | bw, a)
        case .seq:
            let cnt = Int(nd.count)
            for k in 0..<cnt {
                let idx = backward ? cnt - 1 - k : k
                try emit(ast.lists[Int(nd.child) + idx], backward: backward)
            }
        case .alt:
            var jumps: [Int] = []
            let cnt = Int(nd.count)
            for k in 0..<cnt {
                var split = -1
                if k < cnt - 1 {
                    split = code.count
                    op(JSReOp.splitNext, 0)
                }
                try emit(ast.lists[Int(nd.child) + k], backward: backward)
                if k < cnt - 1 {
                    jumps.append(code.count + 1)
                    op(JSReOp.jump, 0)
                    code[split + 1] = Int32(code.count)
                }
            }
            for j in jumps { code[j] = Int32(code.count) }
        case .group:
            let r = 2 * nd.a
            op(JSReOp.save, backward ? r + 1 : r)
            try emit(nd.child, backward: backward)
            op(JSReOp.save, backward ? r : r + 1)
        case .look:
            let at = code.count
            op(JSReOp.look, Int32(nd.flag), 0)
            try emit(nd.child, backward: nd.flag >= 2)
            op(JSReOp.lookEnd)
            code[at + 2] = Int32(code.count)
        case .backref:
            op((ignoreCase ? JSReOp.backrefI : JSReOp.backref) | bw, nd.a)
        case .bol: op(flags.multiline ? JSReOp.bolM : JSReOp.bol)
        case .eol: op(flags.multiline ? JSReOp.eolM : JSReOp.eol)
        case .wordB: op(JSReOp.wordB)
        case .notWordB: op(JSReOp.notWordB)
        case .quant:
            try emitQuant(nd, backward: backward)
        }
    }

    mutating func emitQuant(_ nd: JSReNode, backward: Bool) throws(JSRegExpError) {
        let mn = nd.a, mx = nd.b
        let greedy = nd.flag == 1
        if mx == 0 { return }
        if mn == 1 && mx == 1 { try emit(nd.child, backward: backward); return }
        let ck = ast.nodes[Int(nd.child)].kind
        if !backward && (ck == .char || ck == .dot || ck == .set) {
            let (o, a) = try charOp(nd.child)
            op(greedy ? JSReOp.starG : JSReOp.starL, mn, mx, o, a)
            return
        }
        let mayEmpty = canBeEmpty(nd.child)
        let hasCaps = nd.d > nd.c
        if mn == 0 && (mx == -1 || mx == 1) {
            let posReg: Int32 = mayEmpty ? allocReg() : -1
            let head = code.count
            op(greedy ? JSReOp.splitNext : JSReOp.splitJump, 0)
            if posReg >= 0 { op(JSReOp.savePos, posReg) }
            if hasCaps { op(JSReOp.reset, 2 * (nd.c + 1), 2 * (nd.d + 1)) }
            try emit(nd.child, backward: backward)
            if posReg >= 0 { op(JSReOp.emptyCheck, posReg) }
            if mx == -1 { op(JSReOp.jump, Int32(head)) }
            code[head + 1] = Int32(code.count)
            return
        }
        let cReg = allocReg()
        let pReg: Int32 = mayEmpty ? allocReg() : -1
        op(JSReOp.setZero, cReg)
        let head = code.count
        op(JSReOp.loop, cReg, mn, mx, greedy ? 1 : 0, 0)
        if pReg >= 0 { op(JSReOp.savePos, pReg) }
        if hasCaps { op(JSReOp.reset, 2 * (nd.c + 1), 2 * (nd.d + 1)) }
        try emit(nd.child, backward: backward)
        op(JSReOp.loopTail, cReg, mn, pReg, Int32(head))
        code[head + 5] = Int32(code.count)
    }
}

func jsReDisassemble(_ code: [Int32]) -> String {
    var s = ""
    var pc = 0
    while pc < code.count {
        let o = code[pc]
        let len = JSReOp.length(o)
        let k = Int(o & 0xFF)
        s += "\(pc): " + (k < JSReOp.names.count ? JSReOp.names[k] : "?") + (o & JSReOp.back != 0 ? "<" : "")
        var j = 1
        while j < len && pc + j < code.count {
            s += " \(code[pc + j])"
            j += 1
        }
        s += "\n"
        pc += len
    }
    return s
}
