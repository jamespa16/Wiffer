// BigInt in the heap and in the operators (ROADMAP Phase 9E).
//
// Heap side (JSHeap): a bigint is a cell (JSBigIntCell: sign + UInt32 limbs,
// see jsheap.swift) behind a JSValue with the bigint tag; handle 0 is 0n.
//   newBigInt(JSBigInt) -> JSValue        allocates (may GC; returns 0n when
//                                         terminating)
//   bigintValue(v) -> JSBigInt            a copy of the contents
//   bigintsEqual(a, b)                    content equality (used by
//                                         strictEquals/sameValue)
//   bigintToString(v, radix:) -> JSValue  decimal etc. as a string value
// Realm side (JSRealm), all `throws(JSThrow)`:
//   toNumeric(v)           ToPrimitive(number) then a Number or a BigInt
//   toBigInt(v)            the spec's ToBigInt (TypeError/SyntaxError cases)
//   numericOp(op, a, b)    the slow path of - * / % ** << >> >>> & | ^ for
//                          anything that is not two numbers; mixing a BigInt
//                          with a Number is a TypeError
//   numericUnary(op, a)    neg, bitNot, inc, dec
//   addNumeric(pa, pb)     the non-string branch of `+` (primitives)
//   bigintCompare(a, b)    -1 / 0 / 1 / 2 (unordered) for primitives
//   makeBigInt(JSBigInt)   allocates, RangeError past limits.maxBigIntBits
// Sizes are checked against JSLimits.maxBigIntBits before the work is done
// (multiplication, exponentiation, left shifts), so `2n ** 10000000n` is a
// RangeError and nothing big is ever built.

extension JSHeap {
    static let bigintCellBytes = 32

    func bigintValue(_ v: JSValue) -> JSBigInt {
        let i = Int(v.handle)
        guard v.isBigInt, i < bigints.count else { return .zero }
        return JSBigInt(negative: bigints[i].negative, mag: bigints[i].limbs)
    }

    func newBigInt(_ b: JSBigInt) -> JSValue {
        if b.mag.isEmpty { return .bigint(0) }
        let bytes = JSHeap.bigintCellBytes + b.mag.count * 4
        guard beforeAllocation(bytes, .undefined, .undefined) else { return .bigint(0) }
        var c = JSBigIntCell()
        c.negative = b.negative
        c.limbs = b.mag
        return .bigint(allocBigIntSlot(c))
    }

    public func bigintsEqual(_ a: JSValue, _ b: JSValue) -> Bool {
        let i = Int(a.handle), j = Int(b.handle)
        guard i < bigints.count && j < bigints.count else { return false }
        return bigints[i].negative == bigints[j].negative && bigints[i].limbs == bigints[j].limbs
    }

    func bigintToString(_ v: JSValue, radix: Int = 10) -> JSValue {
        let b = bigintValue(v)
        var d = jsBNMagToDigits(b.mag, radix: radix)
        if b.negative { d.insert(0x2D, at: 0) }
        return newString(latin1: d)
    }

    /// A short hash of a bigint's contents (Map/Set keys).
    func bigintHash(_ v: JSValue) -> UInt64 {
        let i = Int(v.handle)
        guard v.isBigInt, i < bigints.count else { return 0 }
        var h: UInt64 = bigints[i].negative ? 0x9E37_79B9_7F4A_7C15 : 0xC2B2_AE3D_27D4_EB4F
        for l in bigints[i].limbs { h = (h ^ UInt64(l)) &* 0x1000_0000_01B3 }
        return h
    }
}

let jsMixBigIntMessage = "Cannot mix BigInt and other types, use explicit conversions"

extension JSRealm {
    func bigintTooBig() -> JSThrow { throwRangeError("Maximum BigInt size exceeded") }

    func makeBigInt(_ b: JSBigInt) throws(JSThrow) -> JSValue {
        if jsBNBitLength(b.mag) > limits.maxBigIntBits { throw bigintTooBig() }
        let v = heap.newBigInt(b)
        if heap.termination != nil { throw JSThrow() }
        return v
    }

    func toNumeric(_ v: JSValue) throws(JSThrow) -> JSValue {
        if v.isNumber || v.isBigInt { return v }
        let p = try toPrimitive(v, hint: .number)
        if p.isBigInt { return p }
        return .number(try toNumber(p))
    }

    /// StringToBigInt: nil when the text is not a BigInt literal.
    func stringToBigInt(_ s: JSValue) throws(JSThrow) -> JSValue? {
        var tooBig = false
        guard let b = jsBNParseString(heap.stringUnits(s), maxBits: limits.maxBigIntBits, tooBig: &tooBig) else {
            if tooBig { throw bigintTooBig() }
            return nil
        }
        return try makeBigInt(b)
    }

    func toBigInt(_ v: JSValue) throws(JSThrow) -> JSValue {
        let p = try toPrimitive(v, hint: .number)
        if p.isBigInt { return p }
        if p.isBool {
            if p.boolValue { return try makeBigInt(JSBigInt(negative: false, mag: [1])) }
            return .bigint(0)
        }
        if p.isString {
            let r = heap.root(p)
            defer { heap.popRoots(to: r.slot) }
            if let b = try stringToBigInt(p) { return b }
            throw throwSyntaxError("Cannot convert " + heap.swiftString(p) + " to a BigInt")
        }
        if p.isUndefined || p.isNull { throw throwTypeError("Cannot convert " + (p.isNull ? "null" : "undefined") + " to a BigInt") }
        if p.isNumber { throw throwTypeError("Cannot convert a Number to a BigInt") }
        throw throwTypeError("Cannot convert a Symbol to a BigInt")
    }

    /// A BigInt from an integral Number (RangeError when not an integer).
    func numberToBigInt(_ d: Double) throws(JSThrow) -> JSValue {
        if !d.isFinite || d != d.rounded(.towardZero) {
            throw throwRangeError("The number " + heap.swiftString(heap.numberToString(d)) + " cannot be converted to a BigInt because it is not an integer")
        }
        return try makeBigInt(jsBNFromDouble(d))
    }

    // MARK: Binary operators

    /// Both operands are BigInts.
    func bigintBinary(_ op: JSOp, _ a: JSValue, _ b: JSValue) throws(JSThrow) -> JSValue {
        let x = heap.bigintValue(a), y = heap.bigintValue(b)
        switch op {
        case .add: return try makeBigInt(jsBNAddSigned(x, y))
        case .sub: return try makeBigInt(jsBNSubSigned(x, y))
        case .mul:
            if jsBNBitLength(x.mag) + jsBNBitLength(y.mag) > limits.maxBigIntBits + 1 { throw bigintTooBig() }
            return try makeBigInt(jsBNMulSigned(x, y))
        case .div, .mod:
            if y.isZero { throw throwRangeError("Division by zero") }
            let (q, r) = jsBNDivRemSigned(x, y)
            return try makeBigInt(op == .div ? q : r)
        case .exp:
            if y.negative { throw throwRangeError("Exponent must be non-negative") }
            if y.isZero { return try makeBigInt(JSBigInt(negative: false, mag: [1])) }
            if x.isZero { return .bigint(0) }
            if x.mag.count == 1 && x.mag[0] == 1 {
                // 1 or -1
                if x.negative && y.mag[0] & 1 == 1 { return a }
                return try makeBigInt(JSBigInt(negative: false, mag: [1]))
            }
            guard let e = jsBNToInt(y), e <= limits.maxBigIntBits else { throw bigintTooBig() }
            if (jsBNBitLength(x.mag) - 1) * e > limits.maxBigIntBits { throw bigintTooBig() }
            var result = JSBigInt(negative: false, mag: [1])
            var base = x
            var n = e
            while n > 0 {
                if n & 1 == 1 { result = jsBNMulSigned(result, base) }
                n >>= 1
                if n > 0 { base = jsBNMulSigned(base, base) }
                if jsBNBitLength(result.mag) > limits.maxBigIntBits { throw bigintTooBig() }
            }
            return try makeBigInt(result)
        case .shl, .sar:
            // a << b, a >> b (a negative shift count goes the other way).
            let left = (op == .shl) != y.negative
            guard let k = jsBNToInt(JSBigInt(negative: false, mag: y.mag)) else {
                if left {
                    if x.isZero { return .bigint(0) }
                    throw bigintTooBig()
                }
                if x.negative { return try makeBigInt(JSBigInt(negative: true, mag: [1])) }
                return .bigint(0)
            }
            if left {
                if x.isZero { return .bigint(0) }
                if k > limits.maxBigIntBits || jsBNBitLength(x.mag) + k > limits.maxBigIntBits { throw bigintTooBig() }
                return try makeBigInt(jsBNShiftLeft(x, k))
            }
            return try makeBigInt(jsBNShiftRight(x, k))
        case .shr:
            throw throwTypeError("BigInts have no unsigned right shift, use >> instead")
        case .bitAnd: return try makeBigInt(jsBNBitwise(0, x, y))
        case .bitOr: return try makeBigInt(jsBNBitwise(1, x, y))
        case .bitXor: return try makeBigInt(jsBNBitwise(2, x, y))
        default: throw throwTypeError("bad BigInt operator")
        }
    }

    /// Slow path of the arithmetic and bitwise operators (not `+`).
    func numericOp(_ op: JSOp, _ a: JSValue, _ b: JSValue) throws(JSThrow) -> JSValue {
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let na = try toNumeric(a)
        _ = heap.root(na)
        let nb = try toNumeric(b)
        _ = heap.root(nb)
        if na.isBigInt || nb.isBigInt {
            guard na.isBigInt && nb.isBigInt else { throw throwTypeError(jsMixBigIntMessage) }
            return try bigintBinary(op, na, nb)
        }
        let x = na.numberValue, y = nb.numberValue
        switch op {
        case .sub: return .number(x - y)
        case .mul: return .number(x * y)
        case .div: return .number(x / y)
        case .mod: return .number(jsFmod(x, y))
        case .exp: return .number(jsPowNumber(x, y))
        default: break
        }
        let i = jsToInt32(x), j = jsToInt32(y)
        switch op {
        case .shl: return .int32(i << (j & 31))
        case .sar: return .int32(i >> (j & 31))
        case .shr: return .number(Double(UInt32(bitPattern: i) >> UInt32(j & 31)))
        case .bitAnd: return .int32(i & j)
        case .bitOr: return .int32(i | j)
        default: return .int32(i ^ j)
        }
    }

    /// `+` on two primitives, neither a string.
    func addNumeric(_ pa: JSValue, _ pb: JSValue) throws(JSThrow) -> JSValue {
        if pa.isBigInt || pb.isBigInt {
            guard pa.isBigInt && pb.isBigInt else {
                // The other side must still convert (a Symbol throws its own error).
                if !pa.isBigInt { _ = try toNumber(pa) } else { _ = try toNumber(pb) }
                throw throwTypeError(jsMixBigIntMessage)
            }
            return try bigintBinary(.add, pa, pb)
        }
        return .number(try toNumber(pa) + toNumber(pb))
    }

    func numericUnary(_ op: JSOp, _ a: JSValue) throws(JSThrow) -> JSValue {
        let n = try toNumeric(a)
        if n.isBigInt {
            let x = heap.bigintValue(n)
            switch op {
            case .neg: return try makeBigInt(jsBNNegate(x))
            case .bitNot: return try makeBigInt(jsBNNot(x))
            case .inc: return try makeBigInt(jsBNAddSigned(x, JSBigInt(negative: false, mag: [1])))
            default: return try makeBigInt(jsBNSubSigned(x, JSBigInt(negative: false, mag: [1])))
            }
        }
        let d = n.numberValue
        switch op {
        case .neg: return .number(-d)
        case .bitNot: return .int32(~jsToInt32(d))
        case .inc: return .number(d + 1)
        default: return .number(d - 1)
        }
    }

    /// Order of two primitives where at least one is a BigInt and neither
    /// is an object: -1, 0, 1, or 2 (unordered, `undefined` in the spec).
    func bigintCompare(_ a: JSValue, _ b: JSValue) throws(JSThrow) -> Int {
        var x = a, y = b
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        if x.isString {
            guard let c = try stringToBigIntOrNil(x) else { return 2 }
            x = c; _ = heap.root(x)
        }
        if y.isString {
            guard let c = try stringToBigIntOrNil(y) else { return 2 }
            y = c; _ = heap.root(y)
        }
        if x.isBigInt && y.isBigInt { return jsBNCmpSigned(heap.bigintValue(x), heap.bigintValue(y)) }
        if x.isBigInt { return jsBNCompareDouble(heap.bigintValue(x), try toNumber(y)) }
        let c = jsBNCompareDouble(heap.bigintValue(y), try toNumber(x))
        return c == 2 ? 2 : -c
    }

    /// StringToBigInt, but over-long input is just "not a number".
    private func stringToBigIntOrNil(_ s: JSValue) throws(JSThrow) -> JSValue? {
        var tooBig = false
        guard let b = jsBNParseString(heap.stringUnits(s), maxBits: limits.maxBigIntBits, tooBig: &tooBig) else { return nil }
        return try makeBigInt(b)
    }

    /// BigInt == Number / String (loose equality), either order.
    func bigintLooseEquals(_ a: JSValue, _ b: JSValue) throws(JSThrow) -> Bool {
        if a.isBigInt && b.isBigInt { return heap.bigintsEqual(a, b) }
        return try bigintCompare(a, b) == 0
    }
}
