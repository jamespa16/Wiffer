// JSValue: an ECMAScript value as one NaN-boxed UInt64 (ROADMAP Part 9,
// "Values, objects and memory"). A POD: no Swift references, so copying a
// value costs no retain/release.
//
// Encoding (bits 63...48 = "top"):
//   top < 0xFFF9        a Double, stored as-is. Every NaN is canonicalized
//                       to 0x7FF8_0000_0000_0000 on the way in, so no
//                       computed NaN can forge a tag.
//   0xFFF9_0000_xxxxxxxx  int32 (low 32 bits); the VM's fast path
//   0xFFFA_0000_0000_000n undefined (0), null (1), false (2), true (3),
//                         hole (4: internal "no value" for array holes and
//                         empty slots; never visible to scripts)
//   0xFFFB_0000_hhhhhhhh  string, h = JSHeap string handle
//   0xFFFC_0000_hhhhhhhh  symbol handle
//   0xFFFD_0000_hhhhhhhh  object handle
//   0xFFFE_0000_hhhhhhhh  bigint handle (placeholder for 9E's BigInt)
//
// API (the VM contract):
//   JSValue.undefined / .null / .true / .false / .hole
//   JSValue.bool(b), .int32(i), .number(d) (int32 when exactly integral and
//     not -0, else double), .double(d) (always the double form),
//     .string(h), .symbol(h), .object(h), .bigint(h)
//   isUndefined isNull isNullish isBool isNumber isInt32 isDouble isString
//   isSymbol isObject isBigInt isHole isHeapValue
//   asInt32 asDouble (raw, caller checked the form), numberValue (either
//   form as Double), boolValue, handle (heap handle of a heap value)
//   type -> JSType (undefined, null, boolean, number, string, symbol,
//     object, bigint)
//   `==` is bitwise identity, NOT a JS equality: use JSHeap.strictEquals /
//   sameValue / sameValueZero (strings compare by content).
//   jsSameValueNumber, jsStrictEqualsNumber: the number cases.

/// A handle into one of JSHeap's cell arrays (strings, symbols, objects,
/// bigints each have their own index space).
public typealias JSHandle = UInt32

public enum JSType: UInt8 {
    case undefined, null, boolean, number, string, symbol, object, bigint
}

public struct JSValue: Equatable, Hashable {
    public var bits: UInt64

    @inline(__always) public init(bits: UInt64) { self.bits = bits }

    // MARK: Tags

    static let tagInt32: UInt64 = 0xFFF9_0000_0000_0000
    static let tagMisc: UInt64 = 0xFFFA_0000_0000_0000
    static let tagString: UInt64 = 0xFFFB_0000_0000_0000
    static let tagSymbol: UInt64 = 0xFFFC_0000_0000_0000
    static let tagObject: UInt64 = 0xFFFD_0000_0000_0000
    static let tagBigInt: UInt64 = 0xFFFE_0000_0000_0000
    static let tagMask: UInt64 = 0xFFFF_0000_0000_0000
    static let canonicalNaN: UInt64 = 0x7FF8_0000_0000_0000

    public static let undefined = JSValue(bits: tagMisc | 0)
    public static let null = JSValue(bits: tagMisc | 1)
    public static let `false` = JSValue(bits: tagMisc | 2)
    public static let `true` = JSValue(bits: tagMisc | 3)
    /// Internal marker (array holes, "no value"); never given to scripts.
    public static let hole = JSValue(bits: tagMisc | 4)
    public static let nan = JSValue(bits: canonicalNaN)
    public static let zero = JSValue(bits: tagInt32)

    // MARK: Construction

    @inline(__always) public static func bool(_ b: Bool) -> JSValue { b ? .true : .false }
    @inline(__always) public static func int32(_ i: Int32) -> JSValue {
        JSValue(bits: tagInt32 | UInt64(UInt32(bitPattern: i)))
    }
    /// The double form, whatever the value (NaN canonicalized).
    @inline(__always) public static func double(_ d: Double) -> JSValue {
        d.isNaN ? JSValue(bits: canonicalNaN) : JSValue(bits: d.bitPattern)
    }
    /// A number: int32 form when `d` is an integer in int32 range and not
    /// -0, else the double form. Every number the VM makes should come
    /// through here (or .int32) so SameValue on numbers can compare forms.
    @inline(__always) public static func number(_ d: Double) -> JSValue {
        if d >= -2147483648.0 && d <= 2147483647.0 {
            let i = Int32(d)
            if Double(i) == d && !(i == 0 && d.sign == .minus) { return .int32(i) }
        }
        return .double(d)
    }
    @inline(__always) public static func number(_ i: Int) -> JSValue {
        if i >= -2147483648 && i <= 2147483647 { return .int32(Int32(i)) }
        return .double(Double(i))
    }
    @inline(__always) public static func string(_ h: JSHandle) -> JSValue { JSValue(bits: tagString | UInt64(h)) }
    @inline(__always) public static func symbol(_ h: JSHandle) -> JSValue { JSValue(bits: tagSymbol | UInt64(h)) }
    @inline(__always) public static func object(_ h: JSHandle) -> JSValue { JSValue(bits: tagObject | UInt64(h)) }
    @inline(__always) public static func bigint(_ h: JSHandle) -> JSValue { JSValue(bits: tagBigInt | UInt64(h)) }

    // MARK: Tests

    @inline(__always) var top: UInt64 { bits & JSValue.tagMask }
    public var isUndefined: Bool { bits == JSValue.undefined.bits }
    public var isNull: Bool { bits == JSValue.null.bits }
    public var isNullish: Bool { bits == JSValue.undefined.bits || bits == JSValue.null.bits }
    public var isBool: Bool { bits == JSValue.true.bits || bits == JSValue.false.bits }
    public var isHole: Bool { bits == JSValue.hole.bits }
    public var isInt32: Bool { top == JSValue.tagInt32 }
    public var isDouble: Bool { bits < JSValue.tagInt32 }
    public var isNumber: Bool { bits < JSValue.tagMisc }
    public var isString: Bool { top == JSValue.tagString }
    public var isSymbol: Bool { top == JSValue.tagSymbol }
    public var isObject: Bool { top == JSValue.tagObject }
    public var isBigInt: Bool { top == JSValue.tagBigInt }
    /// String, symbol, object or bigint: something the GC traces.
    public var isHeapValue: Bool { bits >= JSValue.tagString }

    // MARK: Payloads

    @inline(__always) public var asInt32: Int32 { Int32(bitPattern: UInt32(truncatingIfNeeded: bits)) }
    @inline(__always) public var asDouble: Double { Double(bitPattern: bits) }
    /// Either number form as a Double (NaN for non-numbers).
    @inline(__always) public var numberValue: Double {
        if isInt32 { return Double(asInt32) }
        if isDouble { return asDouble }
        return .nan
    }
    public var boolValue: Bool { bits == JSValue.true.bits }
    @inline(__always) public var handle: JSHandle { JSHandle(truncatingIfNeeded: bits) }

    public var type: JSType {
        if isNumber { return .number }
        switch top {
        case JSValue.tagString: return .string
        case JSValue.tagSymbol: return .symbol
        case JSValue.tagObject: return .object
        case JSValue.tagBigInt: return .bigint
        default:
            if isNull { return .null }
            if isBool { return .boolean }
            return .undefined
        }
    }

    @inline(__always) public static func == (a: JSValue, b: JSValue) -> Bool { a.bits == b.bits }
    public func hash(into h: inout Hasher) { h.combine(bits) }
}

/// SameValue on two numbers (NaN equals NaN, +0 differs from -0).
public func jsSameValueNumber(_ a: Double, _ b: Double) -> Bool {
    if a.isNaN { return b.isNaN }
    return a.bitPattern == b.bitPattern
}

/// Strict equality on numbers (NaN never equal, +0 == -0).
@inline(__always) public func jsStrictEqualsNumber(_ a: Double, _ b: Double) -> Bool { a == b }
