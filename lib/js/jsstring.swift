// JS strings, atoms and property keys (ROADMAP Part 9, "Strings").
//
// A string is a sequence of UTF-16 code units (lone surrogates allowed).
// A cell stores Latin-1 (one byte per unit) when every unit is < 0x100,
// else UTF-16. Every constructor narrows, so equal strings always have the
// same representation and equality is a plain array compare. Swift String
// (UTF-8) is converted only at the edges (DOM, console, tests).
//
// API (on JSHeap; string values are JSValue.string(handle)):
//   newString(_ s: String) / newString(latin1:) / newString(utf16:) /
//     newString(_ b: JSStringBuilder) / newString(ascii:)  -> JSValue
//     Strings over limits.maxStringLength are cut to it (the builders in
//     the VM/built-ins check `canMakeString(length:)` first and throw a
//     RangeError instead). The empty string is handle 0, never allocated.
//   stringLength(v) -> Int; charCode(v, i) -> UInt16 (0 out of range);
//   codePoint(v, i) -> UInt32 (surrogate pairs joined, lone ones as is)
//   stringUnits(v) -> [UInt16]; isLatin1(v); latin1Bytes(v) -> [UInt8]?
//   concat(a, b) -> JSValue? (nil: over maxStringLength -> RangeError)
//   substring(v, from, to) -> JSValue (clamped)
//   stringsEqual(a, b), compareStrings(a, b) -> -1/0/1 (code unit order)
//   swiftString(v) -> String (lone surrogates become U+FFFD)
//   stringToNumber(v) -> Double (StringToNumber); numberToString(d) -> JSValue
//   Atoms: atom(_ s: String) -> JSValue, intern(v) -> JSValue (the unique
//     string with that content; atoms die with the GC like other strings,
//     except `pinAtom` ones and JSHeap.names)
//   Property keys: JSPropertyKey (array index | atom string | symbol);
//     propertyKey(v) -> JSPropertyKey? (ToPropertyKey for primitives; nil
//     for objects, which need ToPrimitive in the VM first),
//     key(_ s: String), keyValue(k) -> JSValue (index keys become strings)
//   JSStringBuilder: append(unit:), append(codePoint:), append(_ String),
//     append(ascii:), append(contentsOf other: JSStringBuilder); count.

// MARK: Cells

struct JSStringCell {
    var latin1: [UInt8] = []
    var utf16: [UInt16] = []
    var isWide = false
    var isAtom = false
    var hash: UInt32 = 0            // 0: not computed yet
    /// Rope (9J): a concatenation not yet copied out. ropeLeft != 0 means
    /// the content is strings[ropeLeft] + strings[ropeRight] (ropeCount
    /// units; isWide if either side is wide) and latin1/utf16 are empty.
    /// `stringCell` flattens a rope in place before anyone reads units, so
    /// only the heap's length, concat and GC code ever see one.
    var ropeLeft: JSHandle = 0
    var ropeRight: JSHandle = 0
    var ropeCount = 0

    var count: Int { ropeLeft != 0 ? ropeCount : (isWide ? utf16.count : latin1.count) }
    @inline(__always) func unit(_ i: Int) -> UInt16 { isWide ? utf16[i] : UInt16(latin1[i]) }
}

struct JSSymbolCell {
    var description: JSValue = .undefined   // string or undefined
    var registryKey = false                  // created by Symbol.for
    var isPrivate = false                    // a private name (Phase 9E): never listed by ownKeys
}

/// Builds a JS string unit by unit, staying Latin-1 until a wide unit.
public struct JSStringBuilder {
    var latin1: [UInt8] = []
    var utf16: [UInt16] = []
    var isWide = false

    public init() {}
    public init(_ s: String) { append(s) }

    public var count: Int { isWide ? utf16.count : latin1.count }

    public mutating func append(unit u: UInt16) {
        if isWide { utf16.append(u); return }
        if u < 0x100 { latin1.append(UInt8(u)); return }
        widen()
        utf16.append(u)
    }

    mutating func widen() {
        if isWide { return }
        utf16.reserveCapacity(latin1.count + 16)
        for b in latin1 { utf16.append(UInt16(b)) }
        latin1 = []
        isWide = true
    }

    public mutating func append(codePoint c: UInt32) {
        if c < 0x10000 { append(unit: UInt16(truncatingIfNeeded: c)); return }
        if c > 0x10FFFF { append(unit: 0xFFFD); return }
        let v = c - 0x10000
        append(unit: UInt16(0xD800 | (v >> 10)))
        append(unit: UInt16(0xDC00 | (v & 0x3FF)))
    }

    public mutating func append(ascii bytes: [UInt8]) {
        if isWide { for b in bytes { utf16.append(UInt16(b)) } } else { latin1.append(contentsOf: bytes) }
    }

    /// Appends UTF-8 (invalid sequences become U+FFFD).
    public mutating func append(utf8 bytes: [UInt8]) {
        var i = 0
        let n = bytes.count
        while i < n {
            let b0 = UInt32(bytes[i])
            if b0 < 0x80 { append(unit: UInt16(b0)); i += 1; continue }
            var need = 0, cp: UInt32 = 0, min: UInt32 = 0
            if b0 & 0xE0 == 0xC0 { need = 1; cp = b0 & 0x1F; min = 0x80 }
            else if b0 & 0xF0 == 0xE0 { need = 2; cp = b0 & 0x0F; min = 0x800 }
            else if b0 & 0xF8 == 0xF0 { need = 3; cp = b0 & 0x07; min = 0x10000 }
            else { append(unit: 0xFFFD); i += 1; continue }
            var j = 1
            var ok = true
            while j <= need {
                if i + j >= n || bytes[i + j] & 0xC0 != 0x80 { ok = false; break }
                cp = (cp << 6) | UInt32(bytes[i + j] & 0x3F)
                j += 1
            }
            if !ok || cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
                append(unit: 0xFFFD)
                i += ok ? need + 1 : j
                continue
            }
            append(codePoint: cp)
            i += need + 1
        }
    }

    public mutating func append(_ s: String) { append(utf8: Array(s.utf8)) }

    public mutating func append(contentsOf o: JSStringBuilder) {
        if o.isWide { widen(); utf16.append(contentsOf: o.utf16) } else { append(ascii: o.latin1) }
    }

    /// The code units (for tests and the VM's own buffers).
    public var units: [UInt16] { isWide ? utf16 : latin1.map { UInt16($0) } }
}

/// FNV-1a over code unit values (independent of the storage width).
@inline(__always) func jsHashUnits<C: Sequence>(_ s: C) -> UInt32 where C.Element: FixedWidthInteger {
    var h: UInt32 = 2_166_136_261
    for u in s {
        let v = UInt16(truncatingIfNeeded: u)
        h = (h ^ UInt32(v & 0xFF)) &* 16_777_619
        h = (h ^ UInt32(v >> 8)) &* 16_777_619
    }
    return h == 0 ? 1 : h
}

// MARK: Property keys

/// A property key: an array index (0...2^32-2), an interned string (atom)
/// or a symbol. Canonical: a string that is an array index is always an
/// index key, so atoms are never array-index strings.
public struct JSPropertyKey: Hashable {
    public let bits: UInt64
    @inline(__always) init(bits: UInt64) { self.bits = bits }

    static let stringTag: UInt64 = 1 << 32
    static let symbolTag: UInt64 = 2 << 32
    /// Marks a deleted property slot (never equal to a real key).
    static let deleted = JSPropertyKey(bits: UInt64.max)

    @inline(__always) public static func index(_ i: UInt32) -> JSPropertyKey { JSPropertyKey(bits: UInt64(i)) }
    /// From an atom string handle (the caller has interned it).
    @inline(__always) public static func atom(_ h: JSHandle) -> JSPropertyKey { JSPropertyKey(bits: stringTag | UInt64(h)) }
    @inline(__always) public static func symbol(_ h: JSHandle) -> JSPropertyKey { JSPropertyKey(bits: symbolTag | UInt64(h)) }

    public var isIndex: Bool { bits >> 32 == 0 }
    public var isString: Bool { bits >> 32 == 1 }
    public var isSymbol: Bool { bits >> 32 == 2 }
    public var index: UInt32 { UInt32(truncatingIfNeeded: bits) }
    public var handle: JSHandle { JSHandle(truncatingIfNeeded: bits) }

    @inline(__always) var hashValue32: UInt32 {
        var x = bits &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        return UInt32(truncatingIfNeeded: x)
    }
}

/// Atoms the engine uses everywhere, created (and pinned) with the heap.
public struct JSCommonNames {
    public var length, prototype, constructor, name, message, toString, valueOf, value,
               writable, enumerable, configurable, get, set, callee, caller, arguments,
               undefined, null, true_, false_, number, string, boolean, symbol, object,
               function, bigint, NaN, Infinity, negativeInfinity, empty, lastIndex, index,
               input, done, next, then, stack, cause, errors, raw, default_: JSPropertyKey
    init() {
        let z = JSPropertyKey.deleted
        length = z; prototype = z; constructor = z; name = z; message = z; toString = z
        valueOf = z; value = z; writable = z; enumerable = z; configurable = z; get = z; set = z
        callee = z; caller = z; arguments = z; undefined = z; null = z; true_ = z; false_ = z
        number = z; string = z; boolean = z; symbol = z; object = z; function = z; bigint = z
        NaN = z; Infinity = z; negativeInfinity = z; empty = z; lastIndex = z; index = z
        input = z; done = z; next = z; then = z; stack = z; cause = z; errors = z; raw = z
        default_ = z
    }
}

/// The well-known symbols, created (and pinned) with the heap.
public struct JSWellKnownSymbols {
    public var asyncIterator, hasInstance, isConcatSpreadable, iterator, match, matchAll, replace,
               search, species, split, toPrimitive, toStringTag, unscopables: JSValue
    init() {
        let u = JSValue.undefined
        asyncIterator = u; hasInstance = u; isConcatSpreadable = u; iterator = u; match = u
        matchAll = u; replace = u; search = u; species = u; split = u; toPrimitive = u
        toStringTag = u; unscopables = u
    }
}

// MARK: Strings on the heap

extension JSHeap {
    static let stringCellBytes = 48

    /// The cell of string v, flattened (ropes are copied out first, so the
    /// caller may read latin1/utf16 directly).
    @inline(__always) func stringCell(_ v: JSValue) -> Int? {
        let i = Int(v.handle)
        guard v.isString && i < strings.count else { return nil }
        if strings[i].ropeLeft != 0 { flattenRope(i) }
        return i
    }

    /// The cell of string v, possibly a rope (only count/isWide are valid).
    @inline(__always) func rawStringCell(_ v: JSValue) -> Int? {
        let i = Int(v.handle)
        return v.isString && i < strings.count ? i : nil
    }

    /// Concatenations at least this long become ropes.
    static let ropeMinLength = 256

    /// Copies rope i's leaves out in order (an explicit stack: a 100 000-deep
    /// left or right chain costs no Swift stack) and makes it flat. Inner
    /// ropes stay ropes; no allocation happens on the JS heap, so no GC.
    func flattenRope(_ i: Int) {
        let n = strings[i].ropeCount
        let wide = strings[i].isWide
        var lat: [UInt8] = []
        var u16: [UInt16] = []
        if wide { u16.reserveCapacity(n) } else { lat.reserveCapacity(n) }
        var stack: [JSHandle] = [strings[i].ropeRight, strings[i].ropeLeft]
        while let h = stack.popLast() {
            let j = Int(h)
            guard j > 0 && j < strings.count else { continue }
            if strings[j].ropeLeft != 0 {
                stack.append(strings[j].ropeRight)
                stack.append(strings[j].ropeLeft)
                continue
            }
            if wide {
                if strings[j].isWide { u16.append(contentsOf: strings[j].utf16) }
                else { for b in strings[j].latin1 { u16.append(UInt16(b)) } }
            } else {
                lat.append(contentsOf: strings[j].latin1)
            }
        }
        strings[i].ropeLeft = 0
        strings[i].ropeRight = 0
        strings[i].ropeCount = 0
        if wide { strings[i].utf16 = u16 } else { strings[i].latin1 = lat }
        // The units now exist twice (the leaves may still be live).
        _ = noteGrowth(n * (wide ? 2 : 1))
    }

    /// Whether a string of this many units may be made.
    public func canMakeString(length: Int) -> Bool { length <= limits.maxStringLength }

    func allocString(_ cellIn: JSStringCell) -> JSValue {
        if cellIn.count == 0 { return .string(0) }
        var cell = cellIn
        if cell.count > limits.maxStringLength {
            if cell.isWide { cell.utf16.removeSubrange(limits.maxStringLength...) }
            else { cell.latin1.removeSubrange(limits.maxStringLength...) }
        }
        let bytes = JSHeap.stringCellBytes + cell.count * (cell.isWide ? 2 : 1)
        guard beforeAllocation(bytes, .undefined, .undefined) else { return .string(0) }
        let h = allocStringSlot(cell)
        return .string(h)
    }

    public func newString(latin1 bytes: [UInt8]) -> JSValue {
        var c = JSStringCell(); c.latin1 = bytes
        return allocString(c)
    }

    @inline(__always) public func newString(ascii bytes: [UInt8]) -> JSValue { newString(latin1: bytes) }

    /// From UTF-16 code units (narrowed to Latin-1 when possible).
    public func newString(utf16 units: [UInt16]) -> JSValue {
        var c = JSStringCell()
        var wide = false
        for u in units where u >= 0x100 { wide = true; break }
        if wide { c.utf16 = units; c.isWide = true } else { c.latin1 = units.map { UInt8(truncatingIfNeeded: $0) } }
        return allocString(c)
    }

    public func newString(_ b: JSStringBuilder) -> JSValue {
        var c = JSStringCell()
        if b.isWide {
            var wide = false
            for u in b.utf16 where u >= 0x100 { wide = true; break }
            if wide { c.utf16 = b.utf16; c.isWide = true } else { c.latin1 = b.utf16.map { UInt8(truncatingIfNeeded: $0) } }
        } else { c.latin1 = b.latin1 }
        return allocString(c)
    }

    /// From a Swift String (UTF-8).
    public func newString(_ s: String) -> JSValue {
        var ascii = true
        for b in s.utf8 where b >= 0x80 { ascii = false; break }
        if ascii { return newString(latin1: Array(s.utf8)) }
        return newString(JSStringBuilder(s))
    }

    public func stringLength(_ v: JSValue) -> Int {
        guard let i = rawStringCell(v) else { return 0 }
        return strings[i].count
    }

    public func isLatin1(_ v: JSValue) -> Bool {
        guard let i = rawStringCell(v) else { return true }
        return !strings[i].isWide
    }

    /// The bytes of a Latin-1 string (nil if it is stored as UTF-16).
    public func latin1Bytes(_ v: JSValue) -> [UInt8]? {
        guard let i = stringCell(v) else { return [] }
        return strings[i].isWide ? nil : strings[i].latin1
    }

    /// Code unit at i, or 0 when i is out of range (callers check length).
    public func charCode(_ v: JSValue, _ i: Int) -> UInt16 {
        guard let c = stringCell(v), i >= 0, i < strings[c].count else { return 0 }
        return strings[c].unit(i)
    }

    /// CodePointAt: a surrogate pair joined, a lone surrogate as itself.
    public func codePoint(_ v: JSValue, _ i: Int) -> UInt32 {
        let n = stringLength(v)
        guard i >= 0, i < n else { return 0 }
        let a = charCode(v, i)
        if a >= 0xD800 && a <= 0xDBFF && i + 1 < n {
            let b = charCode(v, i + 1)
            if b >= 0xDC00 && b <= 0xDFFF {
                return 0x10000 + ((UInt32(a) - 0xD800) << 10) + (UInt32(b) - 0xDC00)
            }
        }
        return UInt32(a)
    }

    public func stringUnits(_ v: JSValue) -> [UInt16] {
        guard let i = stringCell(v) else { return [] }
        return strings[i].isWide ? strings[i].utf16 : strings[i].latin1.map { UInt16($0) }
    }

    /// a + b, or nil when the result would exceed limits.maxStringLength.
    public func concat(_ a: JSValue, _ b: JSValue) -> JSValue? {
        guard let ia = rawStringCell(a), let ib = rawStringCell(b) else { return nil }
        let na = strings[ia].count, nb = strings[ib].count
        if na == 0 { return b }
        if nb == 0 { return a }
        guard canMakeString(length: na + nb) else { return nil }
        if na + nb >= JSHeap.ropeMinLength {
            // A rope: O(1) now, copied once when someone reads the units
            // (`s += x` in a loop was quadratic).
            guard beforeAllocation(JSHeap.stringCellBytes, a, b) else { return .string(0) }
            var r = JSStringCell()
            r.ropeLeft = JSHandle(ia)
            r.ropeRight = JSHandle(ib)
            r.ropeCount = na + nb
            r.isWide = strings[ia].isWide || strings[ib].isWide
            return .string(allocStringSlot(r))
        }
        // Short: both sides are flat (a rope is never this short).
        var c = JSStringCell()
        if strings[ia].isWide || strings[ib].isWide {
            c.isWide = true
            c.utf16.reserveCapacity(na + nb)
            if strings[ia].isWide { c.utf16.append(contentsOf: strings[ia].utf16) }
            else { for x in strings[ia].latin1 { c.utf16.append(UInt16(x)) } }
            if strings[ib].isWide { c.utf16.append(contentsOf: strings[ib].utf16) }
            else { for x in strings[ib].latin1 { c.utf16.append(UInt16(x)) } }
        } else {
            c.latin1.reserveCapacity(na + nb)
            c.latin1.append(contentsOf: strings[ia].latin1)
            c.latin1.append(contentsOf: strings[ib].latin1)
        }
        // a and b are not referenced by the new cell, so no protection needed.
        return allocString(c)
    }

    /// Units [from, to), clamped to the string.
    public func substring(_ v: JSValue, _ fromIn: Int, _ toIn: Int) -> JSValue {
        guard let i = stringCell(v) else { return .string(0) }
        let n = strings[i].count
        let from = max(0, min(fromIn, n)), to = max(from, min(toIn, n))
        if from == 0 && to == n { return v }
        if from == to { return .string(0) }
        if strings[i].isWide {
            let part = Array(strings[i].utf16[from..<to])
            return newString(utf16: part)
        }
        return newString(latin1: Array(strings[i].latin1[from..<to]))
    }

    public func stringsEqual(_ a: JSValue, _ b: JSValue) -> Bool {
        if a.bits == b.bits { return true }
        guard let ia = stringCell(a), let ib = stringCell(b) else { return false }
        let ca = strings[ia], cb = strings[ib]
        if ca.isAtom && cb.isAtom { return false }      // distinct atoms differ
        if ca.isWide != cb.isWide { return false }
        return ca.isWide ? ca.utf16 == cb.utf16 : ca.latin1 == cb.latin1
    }

    /// Code-unit lexicographic order (IsLessThan on strings): -1, 0, 1.
    public func compareStrings(_ a: JSValue, _ b: JSValue) -> Int {
        guard let ia = stringCell(a), let ib = stringCell(b) else { return 0 }
        let na = strings[ia].count, nb = strings[ib].count
        let n = min(na, nb)
        var k = 0
        while k < n {
            let x = strings[ia].unit(k), y = strings[ib].unit(k)
            if x != y { return x < y ? -1 : 1 }
            k += 1
        }
        return na == nb ? 0 : (na < nb ? -1 : 1)
    }

    /// UTF-8 Swift String; lone surrogates become U+FFFD.
    public func swiftString(_ v: JSValue) -> String {
        guard let i = stringCell(v) else { return "" }
        var out: [UInt8] = []
        let c = strings[i]
        out.reserveCapacity(c.count)
        var k = 0
        let n = c.count
        while k < n {
            var cp = UInt32(c.unit(k))
            k += 1
            if cp >= 0xD800 && cp <= 0xDBFF {
                let lo: UInt32 = k < n ? UInt32(c.unit(k)) : 0
                if lo >= 0xDC00 && lo <= 0xDFFF {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    k += 1
                } else { cp = 0xFFFD }
            } else if cp >= 0xDC00 && cp <= 0xDFFF { cp = 0xFFFD }
            jsAppendUTF8(&out, cp)
        }
        return String(decoding: out, as: UTF8.self)
    }

    public func stringToNumber(_ v: JSValue) -> Double {
        guard let i = stringCell(v) else { return .nan }
        return strings[i].isWide ? jsStringToNumber(strings[i].utf16) : jsStringToNumber(strings[i].latin1)
    }

    /// Number::toString as a string value (small integers are atoms).
    public func numberToString(_ d: Double) -> JSValue {
        newString(latin1: jsNumberToString(d))
    }

    func stringHash(_ i: Int) -> UInt32 {
        if strings[i].hash != 0 { return strings[i].hash }
        let h = strings[i].isWide ? jsHashUnits(strings[i].utf16) : jsHashUnits(strings[i].latin1)
        strings[i].hash = h
        return h
    }

    // MARK: Atoms

    /// The atom with this content (made if missing).
    public func atom(_ s: String) -> JSValue { intern(newString(s)) }

    /// The unique (interned) string with v's content. v must be a string.
    public func intern(_ v: JSValue) -> JSValue {
        guard let i = stringCell(v) else { return .string(0) }
        if strings[i].isAtom || i == 0 { return v }
        let h = stringHash(i)
        if atomTable.isEmpty { rebuildAtomTable(minimum: 64) }
        let mask = atomTable.count - 1
        var p = Int(h) & mask
        while true {
            let e = atomTable[p]
            if e == 0 { break }
            let ei = Int(e)
            if strings[ei].hash == h && stringsEqual(.string(e), v) { return .string(e) }
            p = (p + 1) & mask
        }
        strings[i].isAtom = true
        atomTable[p] = JSHandle(i)
        atomCount += 1
        if atomCount * 2 > atomTable.count { rebuildAtomTable(minimum: atomTable.count * 2) }
        return v
    }

    /// Rebuilds the atom hash table from the live atom cells.
    func rebuildAtomTable(minimum: Int) {
        var live: [JSHandle] = []
        for (i, c) in strings.enumerated() where c.isAtom && i != 0 { live.append(JSHandle(i)) }
        var size = 64
        while size < minimum || size < live.count * 2 + 2 { size *= 2 }
        atomTable = [JSHandle](repeating: 0, count: size)
        let mask = size - 1
        for h in live {
            var p = Int(stringHash(Int(h))) & mask
            while atomTable[p] != 0 { p = (p + 1) & mask }
            atomTable[p] = h
        }
        atomCount = live.count
    }

    /// Keep an atom alive forever (engine names, built-in property names).
    public func pinAtom(_ v: JSValue) -> JSValue {
        let a = intern(v)
        if a.handle != 0 { pinned.append(a) }
        return a
    }

    // MARK: Property keys

    /// ToPropertyKey for primitives. nil for objects (ToPrimitive first)
    /// and bigints (ToString first, 9E).
    public func propertyKey(_ v: JSValue) -> JSPropertyKey? {
        if v.isString {
            guard let i = stringCell(v) else { return nil }
            if strings[i].isAtom {
                // Atoms made from literals may be index-like ("0"): keep keys canonical.
                if !strings[i].isWide, strings[i].count <= 10, let f = strings[i].latin1.first, f >= 0x30, f <= 0x39,
                   let idx = jsArrayIndex(strings[i].latin1) { return .index(idx) }
                return .atom(v.handle)
            }
            if !strings[i].isWide, strings[i].count <= 10, let idx = jsArrayIndex(strings[i].latin1) {
                return .index(idx)
            }
            return .atom(intern(v).handle)
        }
        if v.isSymbol { return .symbol(v.handle) }
        if v.isInt32 && v.asInt32 >= 0 { return .index(UInt32(v.asInt32)) }
        if v.isNumber {
            let d = v.numberValue
            if d >= 0 && d <= 4_294_967_294 && d == jsTrunc(d) { return .index(UInt32(d)) }
            return .atom(intern(numberToString(d)).handle)
        }
        if v.isUndefined { return names.undefined }
        if v.isNull { return names.null }
        if v.isBool { return v.boolValue ? names.true_ : names.false_ }
        return nil
    }

    /// The key for a Swift string (an index key if it is one).
    public func key(_ s: String) -> JSPropertyKey {
        let bytes = Array(s.utf8)
        if let idx = jsArrayIndex(bytes) { return .index(idx) }
        return .atom(atom(s).handle)
    }

    /// The key as a value: the atom string, the symbol, or the index as a
    /// new string (allocates).
    public func keyValue(_ k: JSPropertyKey) -> JSValue {
        if k.isString { return .string(k.handle) }
        if k.isSymbol { return .symbol(k.handle) }
        return newString(latin1: jsNumberToString(Double(k.index)))
    }

    // MARK: Symbols

    /// A new unique symbol; description is a string or undefined.
    public func newSymbol(description: JSValue) -> JSValue {
        guard beforeAllocation(32, description, .undefined) else { return .symbol(0) }
        var c = JSSymbolCell()
        c.description = description.isString ? description : .undefined
        return .symbol(allocSymbolSlot(c))
    }

    public func symbolDescription(_ v: JSValue) -> JSValue {
        let i = Int(v.handle)
        guard v.isSymbol, i < symbols.count else { return .undefined }
        return symbols[i].description
    }
}

func jsAppendUTF8(_ out: inout [UInt8], _ cp: UInt32) {
    if cp < 0x80 { out.append(UInt8(cp)) }
    else if cp < 0x800 {
        out.append(UInt8(0xC0 | (cp >> 6))); out.append(UInt8(0x80 | (cp & 0x3F)))
    } else if cp < 0x10000 {
        out.append(UInt8(0xE0 | (cp >> 12))); out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    } else {
        out.append(UInt8(0xF0 | (cp >> 18))); out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F))); out.append(UInt8(0x80 | (cp & 0x3F)))
    }
}
