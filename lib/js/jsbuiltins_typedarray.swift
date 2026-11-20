// ArrayBuffer, DataView and the typed arrays (ROADMAP Phase 9E).
//
// Layout:
//   ArrayBuffer  kind .arrayBuffer; internalInt = byte store id + 1 (the
//                bytes live in JSHeap.byteStores, freed when the buffer is
//                swept); slots [maxByteLength (number) | undefined];
//                flag user1 = detached (store released).
//   TypedArray   kind .typedArray; slots [buffer, element type (int32),
//                byteOffset, length or -1 (length-tracking view of a
//                resizable buffer)]. Integer-indexed exotic behavior is in
//                the heap (jsobject.swift calls the typedArray* helpers
//                below), so every property path sees it with no JS call;
//                only storing an object (ToNumber) goes through the realm.
//   DataView     kind .dataView; slots [buffer, byteOffset, byteLength or
//                -1 (tracking)].
// Element types: Int8 Uint8 Uint8Clamped Int16 Uint16 Int32 Uint32 Float32
// Float64 Float16. BigInt64Array / BigUint64Array (and DataView
// get/setBig*) are not provided: BigInt is still a placeholder (9E stretch).
// SharedArrayBuffer is not provided (no threads).
//
// Embedding: realm.newArrayBuffer(bytes:), realm.arrayBufferBytes(buf),
// realm.detachArrayBuffer(buf) (the test262 $262.detachArrayBuffer),
// realm.newTypedArray(type:length:).

public enum JSTypedArrayType: Int {
    case int8, uint8, uint8Clamped, int16, uint16, int32, uint32, float32, float64, float16

    public var size: Int {
        switch self {
        case .int8, .uint8, .uint8Clamped: return 1
        case .int16, .uint16, .float16: return 2
        case .int32, .uint32, .float32: return 4
        case .float64: return 8
        }
    }
    var name: String {
        switch self {
        case .int8: return "Int8Array"
        case .uint8: return "Uint8Array"
        case .uint8Clamped: return "Uint8ClampedArray"
        case .int16: return "Int16Array"
        case .uint16: return "Uint16Array"
        case .int32: return "Int32Array"
        case .uint32: return "Uint32Array"
        case .float32: return "Float32Array"
        case .float64: return "Float64Array"
        case .float16: return "Float16Array"
        }
    }
    var protoIntrinsic: JSIntrinsic {
        JSIntrinsic(rawValue: JSIntrinsic.int8ArrayPrototype.rawValue + rawValue) ?? .typedArrayPrototype
    }
    var ctorIntrinsic: JSIntrinsic {
        JSIntrinsic(rawValue: JSIntrinsic.int8ArrayConstructor.rawValue + rawValue) ?? .typedArrayConstructor
    }
    static let all: [JSTypedArrayType] = [.int8, .uint8, .uint8Clamped, .int16, .uint16, .int32, .uint32, .float32, .float64, .float16]
}

// MARK: Number conversions (no libm)

func jsRoundHalfEven(_ x: Double) -> Double {
    let f = jsFloor(x)
    let d = x - f
    if d > 0.5 { return f + 1 }
    if d < 0.5 { return f }
    return jsFmod(f, 2) == 0 ? f : f + 1
}

/// ToUint8Clamp.
func jsToUint8Clamp(_ d: Double) -> UInt8 {
    if d.isNaN || d <= 0 { return 0 }
    if d >= 255 { return 255 }
    return UInt8(jsRoundHalfEven(d))
}

/// Double to IEEE binary16 bits, round to nearest even.
func jsDoubleToHalf(_ d: Double) -> UInt16 {
    if d.isNaN { return 0x7E00 }
    let sign: UInt16 = d.sign == .minus ? 0x8000 : 0
    let a = d.magnitude
    if a >= 65520 { return sign | 0x7C00 }
    if a < 6.103515625e-05 {
        let n = jsRoundHalfEven(a * 16_777_216)   // a / 2^-24
        return sign | UInt16(n)
    }
    var e = Int((a.bitPattern >> 52) & 0x7FF) - 1023
    let m = Double(bitPattern: (a.bitPattern & 0x000F_FFFF_FFFF_FFFF) | 0x3FF0_0000_0000_0000)
    var r = jsRoundHalfEven((m - 1) * 1024)
    if r >= 1024 { r = 0; e += 1 }
    if e + 15 >= 31 { return sign | 0x7C00 }
    return sign | UInt16((e + 15) << 10) | UInt16(r)
}

func jsHalfToDouble(_ h: UInt16) -> Double {
    let s: Double = h & 0x8000 != 0 ? -1 : 1
    let e = Int((h >> 10) & 0x1F), f = Double(h & 0x3FF)
    if e == 0 { return s * f * (1.0 / 16_777_216) }
    if e == 31 { return f == 0 ? s * .infinity : .nan }
    var p = 1.0
    var k = e - 15
    while k > 0 { p *= 2; k -= 1 }
    while k < 0 { p /= 2; k += 1 }
    return s * (1 + f / 1024) * p
}

/// Raw element bits for a number (little-endian order of `size` bytes).
func jsElementBits(_ t: JSTypedArrayType, _ d: Double) -> UInt64 {
    switch t {
    case .int8, .uint8, .int16, .uint16, .int32, .uint32: return UInt64(jsToUint32(d))
    case .uint8Clamped: return UInt64(jsToUint8Clamp(d))
    case .float32: return UInt64(Float(d).bitPattern)
    case .float64: return d.bitPattern
    case .float16: return UInt64(jsDoubleToHalf(d))
    }
}

func jsElementValue(_ t: JSTypedArrayType, _ b: UInt64) -> JSValue {
    switch t {
    case .int8: return .int32(Int32(Int8(truncatingIfNeeded: b)))
    case .uint8, .uint8Clamped: return .int32(Int32(UInt8(truncatingIfNeeded: b)))
    case .int16: return .int32(Int32(Int16(truncatingIfNeeded: b)))
    case .uint16: return .int32(Int32(UInt16(truncatingIfNeeded: b)))
    case .int32: return .int32(Int32(truncatingIfNeeded: b))
    case .uint32: return .number(Int(UInt32(truncatingIfNeeded: b)))
    case .float32: return .number(Double(Float(bitPattern: UInt32(truncatingIfNeeded: b))))
    case .float64: return .number(Double(bitPattern: b))
    case .float16: return .number(jsHalfToDouble(UInt16(truncatingIfNeeded: b)))
    }
}

// MARK: Heap level (no JS, no allocation)

extension JSHeap {
    func byteStoreSize(_ ii: Int64) -> Int {
        let id = Int(ii) - 1
        return id >= 0 && id < byteStores.count ? byteStores[id].count : 0
    }
    func releaseByteStore(_ ii: Int64) {
        let id = Int(ii) - 1
        guard id >= 0 && id < byteStores.count else { return }
        byteStores[id] = []
        byteStoreFree.append(id)
    }
    /// A zeroed store of n bytes: its id + 1, or 0 if refused (termination).
    func newByteStore(_ n: Int) -> Int64 {
        guard beforeAllocation(n + 32, .undefined, .undefined) else { return 0 }
        let bytes = [UInt8](repeating: 0, count: n)
        if let f = byteStoreFree.popLast() { byteStores[f] = bytes; return Int64(f + 1) }
        byteStores.append(bytes)
        return Int64(byteStores.count)
    }

    /// The store index of a live (not detached) buffer, else nil.
    @inline(__always) func bufferStore(_ buf: JSValue) -> Int? {
        guard let b = objectIndex(buf), objects[b].kind == .arrayBuffer else { return nil }
        let id = Int(objects[b].internalInt) - 1
        return id >= 0 && id < byteStores.count ? id : nil
    }
    public func isDetachedBuffer(_ buf: JSValue) -> Bool { bufferStore(buf) == nil }
    public func bufferByteLength(_ buf: JSValue) -> Int {
        guard let s = bufferStore(buf) else { return 0 }
        return byteStores[s].count
    }

    func typedArrayType(_ i: Int) -> JSTypedArrayType {
        let tv = slot(.object(JSHandle(i)), 1)
        guard tv.isInt32 else { return .uint8 }
        return JSTypedArrayType(rawValue: Int(tv.asInt32)) ?? .uint8
    }

    /// (store, byteOffset, length) of a typed array in bounds, else nil
    /// (detached or out of bounds).
    func typedArrayView(_ i: Int) -> (store: Int, offset: Int, length: Int, type: JSTypedArrayType)? {
        let o = JSValue.object(JSHandle(i))
        let tv = slot(o, 1)
        guard tv.isInt32, let st = bufferStore(slot(o, 0)) else { return nil }
        let t = JSTypedArrayType(rawValue: Int(tv.asInt32)) ?? .uint8
        let bl = byteStores[st].count
        let off = Int(slot(o, 2).numberValue)
        let len = slot(o, 3).numberValue
        if off > bl { return nil }
        if len < 0 { return (st, off, (bl - off) / t.size, t) }
        let n = Int(len)
        if off + n * t.size > bl { return nil }
        return (st, off, n, t)
    }

    func typedArrayLength(_ i: Int) -> Int { typedArrayView(i)?.length ?? 0 }

    public func typedArrayIsLengthTracking(_ o: JSValue) -> Bool {
        guard let i = objectIndex(o), objects[i].kind == .typedArray, objects[i].slots.count >= 4 else { return false }
        return objects[i].slots[3].numberValue < 0
    }

    /// CanonicalNumericIndexString for typed arrays: an index key's value;
    /// -1 for a numeric string that is never a valid index ("-0", "1.5",
    /// "-1", "NaN", "Infinity", "4294967295"...); nil when not numeric.
    func typedArrayNumericIndex(_ k: JSPropertyKey) -> Int? {
        if k.isIndex { return Int(k.index) }
        guard k.isString else { return nil }
        let h = Int(k.handle)
        guard h < strings.count, !strings[h].isWide else { return nil }
        let b = strings[h].latin1
        guard let c = b.first, b.count <= 400 else { return nil }
        if !(c == 0x2D || (c >= 0x30 && c <= 0x39) || c == 0x49 || c == 0x4E) { return nil }
        if b == [0x2D, 0x30] { return -1 }
        let d = jsStringToNumber(b)
        return jsNumberToString(d) == b ? -1 : nil
    }

    func typedArrayValidIndex(_ i: Int, _ x: Int) -> Bool {
        x >= 0 && x < typedArrayLength(i)
    }

    @inline(__always) func readBits(_ st: Int, _ off: Int, _ size: Int, littleEndian: Bool = true) -> UInt64 {
        byteStores[st].withUnsafeBufferPointer { p -> UInt64 in
            guard off >= 0 && off + size <= p.count else { return 0 }
            var v: UInt64 = 0
            if littleEndian {
                var j = size - 1
                while j >= 0 { v = (v << 8) | UInt64(p[off + j]); j -= 1 }
            } else {
                for j in 0..<size { v = (v << 8) | UInt64(p[off + j]) }
            }
            return v
        }
    }

    @inline(__always) func writeBits(_ st: Int, _ off: Int, _ size: Int, _ bits: UInt64, littleEndian: Bool = true) {
        byteStores[st].withUnsafeMutableBufferPointer { p in
            guard off >= 0 && off + size <= p.count else { return }
            var v = bits
            if littleEndian {
                for j in 0..<size { p[off + j] = UInt8(truncatingIfNeeded: v); v >>= 8 }
            } else {
                var j = size - 1
                while j >= 0 { p[off + j] = UInt8(truncatingIfNeeded: v); v >>= 8; j -= 1 }
            }
        }
    }

    /// Element x, or nil when x is not a valid integer index.
    func typedArrayElement(_ i: Int, _ x: Int) -> JSValue? {
        guard x >= 0, let v = typedArrayView(i), x < v.length else { return nil }
        return jsElementValue(v.type, readBits(v.store, v.offset + x * v.type.size, v.type.size))
    }

    /// TypedArraySetElement with the number already converted.
    func typedArraySetElement(_ i: Int, _ x: Int, _ d: Double) {
        guard x >= 0, let v = typedArrayView(i), x < v.length else { return }
        writeBits(v.store, v.offset + x * v.type.size, v.type.size, jsElementBits(v.type, d))
    }

    /// TypedArray [[DefineOwnProperty]] for a numeric key (a value that
    /// needs ToNumber of an object fails here: JSRealm.objDefineOwnProperty
    /// converts it first).
    func typedArrayDefine(_ i: Int, _ x: Int, _ d: JSPropertyDescriptor) -> Bool {
        guard typedArrayValidIndex(i, x) else { return false }
        if d.configurable == false || d.enumerable == false || d.isAccessorDescriptor || d.writable == false { return false }
        if let v = d.value {
            guard let n = toPrimitiveNumber(v) else { return false }
            typedArraySetElement(i, x, n)
        }
        return true
    }
}

// MARK: Realm level

extension JSRealm {
    /// TypedArraySetElement: ToNumber (may run JS), then store if valid.
    func typedArraySetElementJS(_ o: JSValue, _ x: Int, _ v: JSValue) throws(JSThrow) {
        let d = try toNumber(v)
        guard let i = heap.objectIndex(o) else { return }
        heap.typedArraySetElement(i, x, d)
    }

    /// ToIndex.
    func toIndex(_ v: JSValue, _ what: String = "index") throws(JSThrow) -> Int {
        if v.isUndefined { return 0 }
        let d = jsToIntegerOrInfinity(try toNumber(v))
        if d < 0 || d > 9007199254740991 { throw throwRangeError("Invalid " + what) }
        return Int(d)
    }

    var maxArrayBufferBytes: Int { min(limits.heapBytes, 1 << 31) }

    /// AllocateArrayBuffer.
    func allocateArrayBuffer(proto: JSValue, length n: Int, max: Int? = nil) throws(JSThrow) -> JSValue {
        let cap = maxArrayBufferBytes
        if n > cap || (max ?? 0) > cap { throw throwRangeError("Array buffer allocation failed") }
        if heap.liveBytes + n > limits.heapBytes {
            heap.collectGarbage()
            if heap.liveBytes + n > limits.heapBytes { throw throwRangeError("Array buffer allocation failed") }
        }
        let r = heap.root(proto)
        defer { heap.popRoots(to: r.slot) }
        let o = heap.newObject(proto: proto, kind: .arrayBuffer)
        guard heap.kind(o) == .arrayBuffer else { throw JSThrow() }
        _ = heap.root(o)
        let st = heap.newByteStore(n)
        if st == 0 { throw JSThrow() }
        heap.setInternalInt(o, st)
        heap.setSlots(o, [max.map { JSValue.number($0) } ?? .undefined])
        return o
    }

    public func newArrayBuffer(bytes: [UInt8]) throws(JSThrow) -> JSValue {
        let o = try allocateArrayBuffer(proto: intrinsic(.arrayBufferPrototype), length: bytes.count)
        if let st = heap.bufferStore(o) { heap.byteStores[st] = bytes }
        return o
    }

    /// The bytes of a buffer (nil if detached or not a buffer).
    public func arrayBufferBytes(_ buf: JSValue) -> [UInt8]? {
        guard let st = heap.bufferStore(buf) else { return nil }
        return heap.byteStores[st]
    }

    /// DetachArrayBuffer. False if not an ArrayBuffer.
    @discardableResult
    public func detachArrayBuffer(_ buf: JSValue) -> Bool {
        guard heap.kind(buf) == .arrayBuffer else { return false }
        heap.releaseByteStore(heap.internalInt(buf))
        heap.setInternalInt(buf, 0)
        heap.setFlags(buf, heap.flags(buf).union(.user1))
        return true
    }

    func isResizableBuffer(_ buf: JSValue) -> Bool { heap.slot(buf, 0).isNumber }

    /// A typed array over buf (offset/length checked by the caller).
    func makeTypedArray(proto: JSValue, type: JSTypedArrayType, buffer: JSValue, offset: Int, length: Int) -> JSValue {
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        _ = heap.root(proto)
        _ = heap.root(buffer)
        let o = heap.newObject(proto: proto, kind: .typedArray)
        heap.setSlots(o, [buffer, .int32(Int32(type.rawValue)), .number(offset), .number(length)])
        return o
    }

    /// AllocateTypedArray with a new buffer of length elements.
    func allocateTypedArray(proto: JSValue, type: JSTypedArrayType, length: Int) throws(JSThrow) -> JSValue {
        let (bytes, ovf) = length.multipliedReportingOverflow(by: type.size)
        if ovf || bytes > maxArrayBufferBytes { throw throwRangeError("Invalid typed array length: " + String(length)) }
        let r = heap.root(proto)
        defer { heap.popRoots(to: r.slot) }
        let buf = try allocateArrayBuffer(proto: intrinsic(.arrayBufferPrototype), length: bytes)
        return makeTypedArray(proto: proto, type: type, buffer: buf, offset: 0, length: length)
    }

    public func newTypedArray(type: JSTypedArrayType, length: Int) throws(JSThrow) -> JSValue {
        try allocateTypedArray(proto: intrinsic(type.protoIntrinsic), type: type, length: length)
    }

    /// ValidateTypedArray: (cell index, length, type); TypeError if not a
    /// typed array or detached / out of bounds.
    func validateTypedArray(_ v: JSValue, _ fn: String) throws(JSThrow) -> (Int, Int, JSTypedArrayType) {
        guard let i = heap.objectIndex(v), heap.objects[i].kind == .typedArray else {
            throw throwTypeError("%TypedArray%.prototype." + fn + " called on incompatible receiver " + describeForError(v))
        }
        guard let view = heap.typedArrayView(i) else {
            throw throwTypeError("Cannot perform %TypedArray%.prototype." + fn + " on a detached ArrayBuffer")
        }
        return (i, view.length, view.type)
    }

    func taLength(_ o: JSValue) -> Int {
        guard let i = heap.objectIndex(o), heap.objects[i].kind == .typedArray else { return 0 }
        return heap.typedArrayLength(i)
    }
    func taGet(_ o: JSValue, _ x: Int) -> JSValue {
        guard let i = heap.objectIndex(o) else { return .undefined }
        return heap.typedArrayElement(i, x) ?? .undefined
    }

    /// TypedArrayCreateFromConstructor (with the length check).
    func typedArrayCreate(_ c: JSValue, _ args: [JSValue], _ fn: String) throws(JSThrow) -> JSValue {
        let o = try construct(c, args: args)
        let r = heap.root(o)
        defer { heap.popRoots(to: r.slot) }
        let (_, len, _) = try validateTypedArray(o, fn)
        if args.count == 1 && args[0].isNumber && Double(len) < args[0].numberValue {
            throw throwTypeError("Derived TypedArray constructor created an array which was too small")
        }
        return o
    }

    /// TypedArraySpeciesCreate.
    func typedArraySpeciesCreate(_ exemplar: JSValue, _ args: [JSValue], _ fn: String) throws(JSThrow) -> JSValue {
        guard let i = heap.objectIndex(exemplar) else { throw throwTypeError("not a typed array") }
        let t = heap.typedArrayType(i)
        let c = try speciesConstructor(exemplar, default: intrinsic(t.ctorIntrinsic))
        let r = heap.root(c)
        defer { heap.popRoots(to: r.slot) }
        return try typedArrayCreate(c, args, fn)
    }

    /// Copy elements src[srcStart..<srcStart+n] into dst at dstStart
    /// (byte copy for the same type, through numbers otherwise; handles
    /// overlap within one buffer).
    func taCopy(_ src: JSValue, _ srcStart: Int, _ dst: JSValue, _ dstStart: Int, _ n: Int) {
        guard n > 0, let si = heap.objectIndex(src), let di = heap.objectIndex(dst),
              let sv = heap.typedArrayView(si), let dv = heap.typedArrayView(di) else { return }
        let cnt = min(n, sv.length - srcStart, dv.length - dstStart)
        guard cnt > 0, srcStart >= 0, dstStart >= 0 else { return }
        if sv.type == dv.type {
            let sz = sv.type.size
            let bytes = Array(heap.byteStores[sv.store][(sv.offset + srcStart * sz)..<(sv.offset + (srcStart + cnt) * sz)])
            let at = dv.offset + dstStart * sz
            heap.byteStores[dv.store].withUnsafeMutableBufferPointer { p in
                for j in 0..<bytes.count where at + j < p.count { p[at + j] = bytes[j] }
            }
            return
        }
        var vals: [Double] = []
        vals.reserveCapacity(cnt)
        for x in 0..<cnt { vals.append(jsElementValue(sv.type, heap.readBits(sv.store, sv.offset + (srcStart + x) * sv.type.size, sv.type.size)).numberValue) }
        for x in 0..<cnt { heap.typedArraySetElement(di, dstStart + x, vals[x]) }
    }

    /// ArrayBuffer `this` check.
    func thisBuffer(_ v: JSValue, _ fn: String) throws(JSThrow) -> JSValue {
        guard heap.kind(v) == .arrayBuffer else {
            throw throwTypeError("Method ArrayBuffer.prototype." + fn + " called on incompatible receiver " + describeForError(v))
        }
        return v
    }

    /// The typed array constructor behavior for one element type.
    func constructTypedArray(_ type: JSTypedArrayType, _ args: JSArgs) throws(JSThrow) -> JSValue {
        if !args.isConstruct { throw throwTypeError("Constructor " + type.name + " requires 'new'") }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let first = args[0]
        if !first.isObject {
            let n = try toIndex(first, "typed array length")
            let proto = try prototype(forNewTarget: args.newTarget, default: type.protoIntrinsic)
            return try allocateTypedArray(proto: proto, type: type, length: n)
        }
        let k = heap.kind(first)
        if k == .arrayBuffer {
            let offset = try toIndex(args[1], "typed array offset")
            if offset % type.size != 0 { throw throwRangeError("start offset of " + type.name + " should be a multiple of " + String(type.size)) }
            var newLength = -1
            if !args[2].isUndefined { newLength = try toIndex(args[2], "typed array length") }
            let proto = try prototype(forNewTarget: args.newTarget, default: type.protoIntrinsic)
            _ = heap.root(proto)
            if heap.isDetachedBuffer(first) { throw throwTypeError("Cannot construct a typed array on a detached ArrayBuffer") }
            let bl = heap.bufferByteLength(first)
            if newLength < 0 {
                if isResizableBuffer(first) {
                    if offset > bl { throw throwRangeError("Start offset " + String(offset) + " is outside the bounds of the buffer") }
                    return makeTypedArray(proto: proto, type: type, buffer: first, offset: offset, length: -1)
                }
                if bl % type.size != 0 { throw throwRangeError("byte length of " + type.name + " should be a multiple of " + String(type.size)) }
                if bl - offset < 0 { throw throwRangeError("Start offset " + String(offset) + " is outside the bounds of the buffer") }
                return makeTypedArray(proto: proto, type: type, buffer: first, offset: offset, length: (bl - offset) / type.size)
            }
            let (nb, ovf) = newLength.multipliedReportingOverflow(by: type.size)
            if ovf || offset + nb > bl { throw throwRangeError("Invalid typed array length: " + String(newLength)) }
            return makeTypedArray(proto: proto, type: type, buffer: first, offset: offset, length: newLength)
        }
        let proto = try prototype(forNewTarget: args.newTarget, default: type.protoIntrinsic)
        _ = heap.root(proto)
        if k == .typedArray {
            guard let si = heap.objectIndex(first), let sv = heap.typedArrayView(si) else {
                throw throwTypeError("Cannot construct a typed array from a detached ArrayBuffer")
            }
            let o = try allocateTypedArray(proto: proto, type: type, length: sv.length)
            _ = heap.root(o)
            taCopy(first, 0, o, 0, sv.length)
            return o
        }
        // An iterable or an array-like.
        let iterKey = JSPropertyKey.symbol(heap.symbolsWellKnown.iterator.handle)
        let usingIterator = try getMethodOrNil(first, iterKey)
        var values: [JSValue] = []
        if let m = usingIterator {
            _ = heap.root(m)
            if m == intrinsic(.arrayValues) && heap.kind(first) == .array {
                let n = Int(heap.arrayLength(first))
                for x in 0..<n { let v = try getV(first, .index(UInt32(x))); _ = heap.root(v); values.append(v) }
            } else {
                let it = try call(m, this: first, args: [])
                guard it.isObject else { throw throwTypeError("Result of the Symbol.iterator method is not an object") }
                let ri = heap.root(it)
                let next = try getV(it, heap.names.next)
                let rn = heap.root(next)
                while true {
                    let (done, v) = try iteratorStep(heap[ri], heap[rn])
                    if done { break }
                    _ = heap.root(v)
                    values.append(v)
                    if values.count > limits.maxDenseArrayLength { throw throwRangeError("Invalid typed array length") }
                }
            }
            let o = try allocateTypedArray(proto: proto, type: type, length: values.count)
            _ = heap.root(o)
            for (x, v) in values.enumerated() { try objSetOrThrow(o, .index(UInt32(x)), v) }
            return o
        }
        let n = try toLength(try getV(first, heap.names.length))
        let o = try allocateTypedArray(proto: proto, type: type, length: n)
        _ = heap.root(o)
        for x in 0..<n {
            let key = try toPropertyKey(.number(x))
            let v = try getV(first, key)
            try objSetOrThrow(o, .index(UInt32(truncatingIfNeeded: x)), v)
        }
        return o
    }

    // MARK: DataView

    /// (store, absolute byte offset) for a get/set of `size` at request
    /// index, after the spec's checks.
    func viewAccess(_ view: JSValue, _ requestIndex: JSValue, size: Int, fn: String, value: JSValue?, littleEndian: JSValue)
        throws(JSThrow) -> (Int, Int, Bool, Double) {
        guard heap.kind(view) == .dataView else {
            throw throwTypeError("Method DataView.prototype." + fn + " called on incompatible receiver " + describeForError(view))
        }
        let idx = try toIndex(requestIndex, "DataView index")
        var num = 0.0
        if let v = value { num = try toNumber(v) }
        let le = heap.toBoolean(littleEndian)
        let buf = heap.slot(view, 0)
        guard let st = heap.bufferStore(buf) else { throw throwTypeError("Cannot perform DataView.prototype." + fn + " on a detached ArrayBuffer") }
        guard let (off, len) = dataViewBounds(view) else { throw throwTypeError("DataView is out of bounds") }
        _ = st
        if idx + size > len { throw throwRangeError("Offset is outside the bounds of the DataView") }
        return (st, off + idx, le, num)
    }

    /// (byteOffset, byteLength) of an in-bounds view, else nil.
    func dataViewBounds(_ view: JSValue) -> (Int, Int)? {
        let buf = heap.slot(view, 0)
        guard heap.bufferStore(buf) != nil else { return nil }
        let bl = heap.bufferByteLength(buf)
        let off = Int(heap.slot(view, 1).numberValue)
        let l = heap.slot(view, 2).numberValue
        if off > bl { return nil }
        if l < 0 { return (off, bl - off) }
        if off + Int(l) > bl { return nil }
        return (off, Int(l))
    }
}

func jsInstallTypedArrays(_ realm: JSRealm) {
    let heap = realm.heap
    let op = realm.objectPrototype
    let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)
    let speciesKey = JSPropertyKey.symbol(heap.symbolsWellKnown.species.handle)
    let iterKey = JSPropertyKey.symbol(heap.symbolsWellKnown.iterator.handle)
    let depth = heap.rootDepth
    defer { heap.popRoots(to: depth) }
    let speciesGetter: JSNativeFunction = { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in args.this }

    // -------------------------------------------------------- ArrayBuffer
    let abp = heap.newObject(proto: op)
    _ = heap.root(abp)
    realm.setIntrinsic(.arrayBufferPrototype, abp)
    let abCtor = realm.defineConstructor("ArrayBuffer", length: 1, prototype: abp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor ArrayBuffer requires 'new'") }
        let n = try realm.toIndex(args[0], "array buffer length")
        var max: Int? = nil
        if args[1].isObject {
            let m = try realm.getV(args[1], realm.heap.key("maxByteLength"))
            if !m.isUndefined { max = try realm.toIndex(m, "array buffer max length") }
        }
        if let mx = max, n > mx { throw realm.throwRangeError("Invalid array buffer max length") }
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .arrayBufferPrototype)
        return try realm.allocateArrayBuffer(proto: proto, length: n, max: max)
    }
    _ = heap.root(abCtor)
    realm.setIntrinsic(.arrayBufferConstructor, abCtor)
    realm.defineGetter(abCtor, "[Symbol.species]", key: speciesKey, speciesGetter)
    realm.defineMethod(abCtor, "isView", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let k = realm.heap.kind(args[0])
        return .bool(args[0].isObject && (k == .typedArray || k == .dataView))
    }
    realm.defineGetter(abp, "byteLength") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .number(realm.heap.bufferByteLength(try realm.thisBuffer(args.this, "byteLength")))
    }
    realm.defineGetter(abp, "maxByteLength") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let b = try realm.thisBuffer(args.this, "maxByteLength")
        if realm.heap.isDetachedBuffer(b) { return .int32(0) }
        let m = realm.heap.slot(b, 0)
        return m.isNumber ? m : .number(realm.heap.bufferByteLength(b))
    }
    realm.defineGetter(abp, "resizable") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(realm.isResizableBuffer(try realm.thisBuffer(args.this, "resizable")))
    }
    realm.defineGetter(abp, "detached") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(realm.heap.isDetachedBuffer(try realm.thisBuffer(args.this, "detached")))
    }
    realm.defineMethod(abp, "slice", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let o = try realm.thisBuffer(args.this, "slice")
        if h.isDetachedBuffer(o) { throw realm.throwTypeError("Cannot perform ArrayBuffer.prototype.slice on a detached ArrayBuffer") }
        let len = Double(h.bufferByteLength(o))
        let rs = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
        let first = rs < 0 ? max(len + rs, 0) : min(rs, len)
        let re = args[1].isUndefined ? len : jsToIntegerOrInfinity(try realm.toNumber(args[1]))
        let fin = re < 0 ? max(len + re, 0) : min(re, len)
        let newLen = Int(max(fin - first, 0))
        let c = try realm.speciesConstructor(o, default: realm.intrinsic(.arrayBufferConstructor))
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        _ = h.root(c)
        let n = try realm.construct(c, args: [.number(newLen)])
        _ = h.root(n)
        guard h.kind(n) == .arrayBuffer else { throw realm.throwTypeError("ArrayBuffer subclass returned this from species constructor") }
        if h.isDetachedBuffer(n) { throw realm.throwTypeError("species constructor returned a detached ArrayBuffer") }
        if n == o { throw realm.throwTypeError("ArrayBuffer subclass returned this from species constructor") }
        if h.bufferByteLength(n) < newLen { throw realm.throwTypeError("Species constructor returned a too small buffer") }
        guard let ss = h.bufferStore(o) else { throw realm.throwTypeError("Cannot perform ArrayBuffer.prototype.slice on a detached ArrayBuffer") }
        guard let ds = h.bufferStore(n) else { return n }
        let f = Int(first)
        let cur = h.byteStores[ss].count
        if f < cur {
            let cnt = min(newLen, cur - f)
            let bytes = Array(h.byteStores[ss][f..<(f + cnt)])
            for j in 0..<cnt { h.byteStores[ds][j] = bytes[j] }
        }
        return n
    }
    realm.defineMethod(abp, "resize", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let o = try realm.thisBuffer(args.this, "resize")
        guard realm.isResizableBuffer(o) else { throw realm.throwTypeError("Method ArrayBuffer.prototype.resize called on incompatible receiver") }
        let n = try realm.toIndex(args[0], "length")
        guard let st = h.bufferStore(o) else { throw realm.throwTypeError("Cannot perform ArrayBuffer.prototype.resize on a detached ArrayBuffer") }
        if n > Int(h.slot(o, 0).numberValue) { throw realm.throwRangeError("ArrayBuffer.prototype.resize: Invalid length parameter") }
        let cur = h.byteStores[st].count
        if n > cur {
            if !h.noteGrowth(n - cur) { throw JSThrow() }
            h.byteStores[st].append(contentsOf: [UInt8](repeating: 0, count: n - cur))
        } else if n < cur {
            h.byteStores[st].removeSubrange(n...)
        }
        return .undefined
    }
    let transfer: (JSRealm, JSArgs, Bool) throws(JSThrow) -> JSValue = { (realm: JSRealm, args: JSArgs, preserve: Bool) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let o = try realm.thisBuffer(args.this, preserve ? "transfer" : "transferToFixedLength")
        let n = args[0].isUndefined ? h.bufferByteLength(o) : try realm.toIndex(args[0], "length")
        guard let st = h.bufferStore(o) else { throw realm.throwTypeError("Cannot transfer a detached ArrayBuffer") }
        var max: Int? = nil
        if preserve && realm.isResizableBuffer(o) {
            max = Int(h.slot(o, 0).numberValue)
            if n > max! { throw realm.throwRangeError("Invalid array buffer length") }
        }
        if n > realm.maxArrayBufferBytes { throw realm.throwRangeError("Array buffer allocation failed") }
        let nb = h.newObject(proto: realm.intrinsic(.arrayBufferPrototype), kind: .arrayBuffer)
        guard h.kind(nb) == .arrayBuffer else { throw JSThrow() }
        // Move the store (no copy), then fix its length.
        var bytes = h.byteStores[st]
        h.byteStores[st] = []
        if n > bytes.count {
            if !h.noteGrowth(n - bytes.count) { throw JSThrow() }
            bytes.append(contentsOf: [UInt8](repeating: 0, count: n - bytes.count))
        } else if n < bytes.count { bytes.removeSubrange(n...) }
        h.byteStores[st] = bytes
        h.setInternalInt(nb, Int64(st + 1))
        h.setSlots(nb, [max.map { JSValue.number($0) } ?? .undefined])
        h.setInternalInt(o, 0)
        h.setFlags(o, h.flags(o).union(.user1))
        return nb
    }
    realm.defineMethod(abp, "transfer", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try transfer(realm, args, true)
    }
    realm.defineMethod(abp, "transferToFixedLength", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try transfer(realm, args, false)
    }
    _ = heap.defineOwnProperty(abp, tagKey, .data(realm.string("ArrayBuffer"), [.configurable]))

    // ----------------------------------------------------------- DataView
    let dvp = heap.newObject(proto: op)
    _ = heap.root(dvp)
    realm.setIntrinsic(.dataViewPrototype, dvp)
    _ = realm.defineConstructor("DataView", length: 1, prototype: dvp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        if !args.isConstruct { throw realm.throwTypeError("Constructor DataView requires 'new'") }
        let buf = args[0]
        guard h.kind(buf) == .arrayBuffer else { throw realm.throwTypeError("First argument to DataView constructor must be an ArrayBuffer") }
        let off = try realm.toIndex(args[1], "DataView offset")
        if h.isDetachedBuffer(buf) { throw realm.throwTypeError("Cannot construct a DataView on a detached ArrayBuffer") }
        var bl = h.bufferByteLength(buf)
        if off > bl { throw realm.throwRangeError("Start offset " + String(off) + " is outside the bounds of the buffer") }
        let tracking = args[2].isUndefined && realm.isResizableBuffer(buf)
        var viewLen = 0
        if !tracking {
            if args[2].isUndefined { viewLen = bl - off } else {
                viewLen = try realm.toIndex(args[2], "DataView length")
                if off + viewLen > bl { throw realm.throwRangeError("Invalid DataView length " + String(viewLen)) }
            }
        }
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .dataViewPrototype)
        if h.isDetachedBuffer(buf) { throw realm.throwTypeError("Cannot construct a DataView on a detached ArrayBuffer") }
        bl = h.bufferByteLength(buf)
        if off > bl { throw realm.throwRangeError("Start offset is outside the bounds of the buffer") }
        if !args[2].isUndefined && off + viewLen > bl { throw realm.throwRangeError("Invalid DataView length") }
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        _ = h.root(proto)
        let o = h.newObject(proto: proto, kind: .dataView)
        h.setSlots(o, [buf, .number(off), tracking ? .int32(-1) : .number(viewLen)])
        return o
    }
    func thisView(_ realm: JSRealm, _ v: JSValue, _ fn: String) throws(JSThrow) -> JSValue {
        guard realm.heap.kind(v) == .dataView else { throw realm.throwTypeError("Method DataView.prototype." + fn + " called on incompatible receiver " + realm.describeForError(v)) }
        return v
    }
    realm.defineGetter(dvp, "buffer") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.heap.slot(try thisView(realm, args.this, "buffer"), 0)
    }
    realm.defineGetter(dvp, "byteLength") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let v = try thisView(realm, args.this, "byteLength")
        guard let (_, l) = realm.dataViewBounds(v) else { return .int32(0) }
        return .number(l)
    }
    realm.defineGetter(dvp, "byteOffset") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let v = try thisView(realm, args.this, "byteOffset")
        guard let (o, _) = realm.dataViewBounds(v) else { return .int32(0) }
        return .number(o)
    }
    _ = heap.defineOwnProperty(dvp, tagKey, .data(realm.string("DataView"), [.configurable]))
    let viewTypes: [(String, JSTypedArrayType)] = [("Int8", .int8), ("Uint8", .uint8), ("Int16", .int16), ("Uint16", .uint16),
        ("Int32", .int32), ("Uint32", .uint32), ("Float16", .float16), ("Float32", .float32), ("Float64", .float64)]
    for (name, t) in viewTypes {
        realm.defineMethod(dvp, "get" + name, length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let (st, at, le, _) = try realm.viewAccess(args.this, args[0], size: t.size, fn: "get" + name, value: nil, littleEndian: args[1])
            return jsElementValue(t, realm.heap.readBits(st, at, t.size, littleEndian: le))
        }
        realm.defineMethod(dvp, "set" + name, length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let (st, at, le, num) = try realm.viewAccess(args.this, args[0], size: t.size, fn: "set" + name, value: args[1], littleEndian: args[2])
            realm.heap.writeBits(st, at, t.size, jsElementBits(t, num), littleEndian: le)
            return .undefined
        }
    }

    // --------------------------------------------------------- %TypedArray%
    let tap = heap.newObject(proto: op)
    _ = heap.root(tap)
    realm.setIntrinsic(.typedArrayPrototype, tap)
    let taCtor = realm.newNativeFunction(realm.registerNative("TypedArray", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        throw realm.throwTypeError("Abstract class TypedArray not directly constructable")
    }, constructor: true)
    _ = heap.root(taCtor)
    realm.setIntrinsic(.typedArrayConstructor, taCtor)
    _ = heap.defineOwnProperty(taCtor, heap.names.prototype, .data(tap, []))
    _ = heap.defineOwnProperty(tap, heap.names.constructor, .data(taCtor, [.writable, .configurable]))
    realm.defineGetter(taCtor, "[Symbol.species]", key: speciesKey, speciesGetter)
    jsInstallTypedArrayStatics(realm, taCtor)
    jsInstallTypedArrayPrototype(realm, tap)
    _ = iterKey

    for t in JSTypedArrayType.all {
        let p = heap.newObject(proto: tap)
        _ = heap.root(p)
        realm.setIntrinsic(t.protoIntrinsic, p)
        let c = realm.defineConstructor(t.name, length: 3, prototype: p) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            try realm.constructTypedArray(t, args)
        }
        _ = heap.root(c)
        realm.setIntrinsic(t.ctorIntrinsic, c)
        _ = heap.setPrototypeOf(c, taCtor)
        _ = heap.defineOwnProperty(c, heap.key("BYTES_PER_ELEMENT"), .data(.int32(Int32(t.size)), []))
        _ = heap.defineOwnProperty(p, heap.key("BYTES_PER_ELEMENT"), .data(.int32(Int32(t.size)), []))
    }
}

func jsInstallTypedArrayStatics(_ realm: JSRealm, _ taCtor: JSValue) {
    realm.defineMethod(taCtor, "from", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = args.this
        guard realm.isConstructor(c) else { throw realm.throwTypeError(realm.describeForError(c) + " is not a constructor") }
        let mapfn = args[1]
        let mapping = !mapfn.isUndefined
        if mapping && !h.isCallable(mapfn) { throw realm.throwTypeError(realm.describeForError(mapfn) + " is not a function") }
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let src = args[0]
        let usingIterator = try realm.getMethodOrNil(src, .symbol(h.symbolsWellKnown.iterator.handle))
        var values: [JSValue] = []
        var arrayLike: JSValue = .undefined
        var len = 0
        if let m = usingIterator {
            _ = h.root(m)
            let it = try realm.call(m, this: src, args: [])
            guard it.isObject else { throw realm.throwTypeError("Result of the Symbol.iterator method is not an object") }
            let ri = h.root(it)
            let next = try realm.getV(it, h.names.next)
            let rn = h.root(next)
            while true {
                let (done, v) = try realm.iteratorStep(h[ri], h[rn])
                if done { break }
                _ = h.root(v)
                values.append(v)
                if values.count > realm.limits.maxDenseArrayLength { throw realm.throwRangeError("Invalid typed array length") }
            }
            len = values.count
        } else {
            arrayLike = try realm.toObject(src)
            _ = h.root(arrayLike)
            len = try realm.toLength(try realm.getV(arrayLike, h.names.length))
        }
        let target = try realm.typedArrayCreate(c, [.number(len)], "from")
        _ = h.root(target)
        for k in 0..<len {
            var v = usingIterator != nil ? values[k] : try realm.getV(arrayLike, try realm.toPropertyKey(.number(k)))
            if mapping {
                _ = h.root(v)
                v = try realm.call(mapfn, this: args[2], args: [v, .number(k)])
            }
            try realm.objSetOrThrow(target, .index(UInt32(truncatingIfNeeded: k)), v)
        }
        return target
    }
    realm.defineMethod(taCtor, "of", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let c = args.this
        guard realm.isConstructor(c) else { throw realm.throwTypeError(realm.describeForError(c) + " is not a constructor") }
        let o = try realm.typedArrayCreate(c, [.number(args.count)], "of")
        let r = realm.heap.root(o)
        defer { realm.heap.popRoots(to: r.slot) }
        for k in 0..<args.count { try realm.objSetOrThrow(o, .index(UInt32(k)), args[k]) }
        return o
    }
}

/// Relative index helper (ToIntegerOrInfinity, then clamp to 0...len).
func jsRelIndex(_ d: Double, _ len: Int) -> Int {
    let l = Double(len)
    if d < 0 { return Int(max(l + d, 0)) }
    return Int(min(d, l))
}

func jsInstallTypedArrayPrototype(_ realm: JSRealm, _ tap: JSValue) {
    let heap = realm.heap
    let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)
    let iterKey = JSPropertyKey.symbol(heap.symbolsWellKnown.iterator.handle)

    realm.defineGetter(tap, "buffer") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard realm.heap.kind(args.this) == .typedArray else { throw realm.throwTypeError("not a typed array") }
        return realm.heap.slot(args.this, 0)
    }
    realm.defineGetter(tap, "byteLength") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard let i = realm.heap.objectIndex(args.this), realm.heap.objects[i].kind == .typedArray else { throw realm.throwTypeError("not a typed array") }
        guard let v = realm.heap.typedArrayView(i) else { return .int32(0) }
        return .number(v.length * v.type.size)
    }
    realm.defineGetter(tap, "byteOffset") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard let i = realm.heap.objectIndex(args.this), realm.heap.objects[i].kind == .typedArray else { throw realm.throwTypeError("not a typed array") }
        guard let v = realm.heap.typedArrayView(i) else { return .int32(0) }
        return .number(v.offset)
    }
    realm.defineGetter(tap, "length") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard let i = realm.heap.objectIndex(args.this), realm.heap.objects[i].kind == .typedArray else { throw realm.throwTypeError("not a typed array") }
        return .number(realm.heap.typedArrayLength(i))
    }
    realm.defineGetter(tap, "[Symbol.toStringTag]", key: tagKey) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard let i = realm.heap.objectIndex(args.this), realm.heap.objects[i].kind == .typedArray else { return .undefined }
        return realm.string(realm.heap.typedArrayType(i).name)
    }

    // Iterators: %ArrayIteratorPrototype% objects (kind .iterator, slots
    // [source], flags user1 = keys, user2 = entries).
    func makeIter(_ realm: JSRealm, _ o: JSValue, _ f: JSObjectFlags, _ fn: String) throws(JSThrow) -> JSValue {
        _ = try realm.validateTypedArray(o, fn)
        let it = realm.heap.newObject(proto: realm.intrinsic(.arrayIteratorPrototype), kind: .iterator, flags: f.union(.extensible))
        realm.heap.setSlots(it, [o])
        return it
    }
    let values = realm.defineMethod(tap, "values", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try makeIter(realm, args.this, [], "values")
    }
    realm.setIntrinsic(.typedArrayValues, values)
    _ = heap.defineOwnProperty(tap, iterKey, .data(values, [.writable, .configurable]))
    realm.defineMethod(tap, "keys", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try makeIter(realm, args.this, [.user1], "keys")
    }
    realm.defineMethod(tap, "entries", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try makeIter(realm, args.this, [.user2], "entries")
    }
    jsInstallArrayIteratorKinds(realm)

    // Callback methods.
    func callbackArg(_ realm: JSRealm, _ f: JSValue) throws(JSThrow) -> JSValue {
        guard realm.heap.isCallable(f) else { throw realm.throwTypeError(realm.describeForError(f) + " is not a function") }
        return f
    }
    realm.defineMethod(tap, "forEach", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, _) = try realm.validateTypedArray(args.this, "forEach")
        let f = try callbackArg(realm, args[0])
        for k in 0..<len { _ = try realm.call(f, this: args[1], args: [realm.taGet(args.this, k), .number(k), args.this]) }
        return .undefined
    }
    for (name, wantTrue, retIndex, fromEnd) in [("every", false, false, false), ("some", true, false, false),
                                                 ("find", true, false, false), ("findIndex", true, true, false),
                                                 ("findLast", true, false, true), ("findLastIndex", true, true, true)] {
        realm.defineMethod(tap, name, length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let (_, len, _) = try realm.validateTypedArray(args.this, name)
            let f = try callbackArg(realm, args[0])
            var k = fromEnd ? len - 1 : 0
            while fromEnd ? k >= 0 : k < len {
                let v = realm.taGet(args.this, k)
                let r = realm.heap.root(v)
                let t = realm.heap.toBoolean(try realm.call(f, this: args[1], args: [v, .number(k), args.this]))
                realm.heap.popRoots(to: r.slot)
                if name == "every" { if !t { return .false } } else if t {
                    if name == "some" { return .true }
                    return retIndex ? .number(k) : v
                }
                k += fromEnd ? -1 : 1
            }
            if name == "every" { return .true }
            if name == "some" { return .false }
            return retIndex ? .int32(-1) : .undefined
        }
        _ = wantTrue
    }
    for right in [false, true] {
        realm.defineMethod(tap, right ? "reduceRight" : "reduce", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let (_, len, _) = try realm.validateTypedArray(args.this, right ? "reduceRight" : "reduce")
            let f = try callbackArg(realm, args[0])
            var k = right ? len - 1 : 0
            var acc: JSValue
            if args.count >= 2 { acc = args[1] } else {
                if len == 0 { throw realm.throwTypeError("Reduce of empty array with no initial value") }
                acc = realm.taGet(args.this, k)
                k += right ? -1 : 1
            }
            let r = realm.heap.root(acc)
            defer { realm.heap.popRoots(to: r.slot) }
            while right ? k >= 0 : k < len {
                acc = try realm.call(f, this: .undefined, args: [acc, realm.taGet(args.this, k), .number(k), args.this])
                realm.heap[r] = acc
                k += right ? -1 : 1
            }
            return acc
        }
    }
    realm.defineMethod(tap, "map", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, _) = try realm.validateTypedArray(args.this, "map")
        let f = try callbackArg(realm, args[0])
        let a = try realm.typedArraySpeciesCreate(args.this, [.number(len)], "map")
        let r = realm.heap.root(a)
        defer { realm.heap.popRoots(to: r.slot) }
        for k in 0..<len {
            let v = try realm.call(f, this: args[1], args: [realm.taGet(args.this, k), .number(k), args.this])
            try realm.objSetOrThrow(a, .index(UInt32(k)), v)
        }
        return a
    }
    realm.defineMethod(tap, "filter", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, _) = try realm.validateTypedArray(args.this, "filter")
        let f = try callbackArg(realm, args[0])
        var kept: [JSValue] = []
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        for k in 0..<len {
            let v = realm.taGet(args.this, k)
            if realm.heap.toBoolean(try realm.call(f, this: args[1], args: [v, .number(k), args.this])) { kept.append(v) }
        }
        let a = try realm.typedArraySpeciesCreate(args.this, [.number(kept.count)], "filter")
        _ = realm.heap.root(a)
        for (k, v) in kept.enumerated() { try realm.objSetOrThrow(a, .index(UInt32(k)), v) }
        return a
    }

    // Search.
    realm.defineMethod(tap, "at", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, _) = try realm.validateTypedArray(args.this, "at")
        let rel = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
        let k = rel >= 0 ? rel : Double(len) + rel
        if k < 0 || k >= Double(len) { return .undefined }
        return realm.taGet(args.this, Int(k))
    }
    for (name, mode) in [("includes", 0), ("indexOf", 1), ("lastIndexOf", 2)] {
        realm.defineMethod(tap, name, length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let (_, len, _) = try realm.validateTypedArray(args.this, name)
            if len == 0 { return mode == 0 ? .false : .int32(-1) }
            var k: Int
            if mode == 2 {
                var n = Double(len - 1)
                if args.count > 1 { n = jsToIntegerOrInfinity(try realm.toNumber(args[1])) }
                if n == -.infinity { return .int32(-1) }
                let kk = n >= 0 ? min(n, Double(len - 1)) : Double(len) + n
                if kk < 0 { return .int32(-1) }
                k = Int(kk)
                let x = args[0]
                while k >= 0 {
                    if let i = realm.heap.objectIndex(args.this), let v = realm.heap.typedArrayElement(i, k), realm.heap.strictEquals(v, x) { return .number(k) }
                    k -= 1
                }
                return .int32(-1)
            }
            let n = jsToIntegerOrInfinity(try realm.toNumber(args[1]))
            if n == .infinity { return mode == 0 ? .false : .int32(-1) }
            k = n >= 0 ? Int(min(n, Double(len))) : Int(max(Double(len) + n, 0))
            let x = args[0]
            while k < len {
                if mode == 0 {
                    if realm.heap.sameValueZero(realm.taGet(args.this, k), x) { return .true }
                } else if let i = realm.heap.objectIndex(args.this), let v = realm.heap.typedArrayElement(i, k), realm.heap.strictEquals(v, x) {
                    return .number(k)
                }
                k += 1
            }
            return mode == 0 ? .false : .int32(-1)
        }
    }
    realm.defineMethod(tap, "join", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, _) = try realm.validateTypedArray(args.this, "join")
        let sepV: JSValue = args[0].isUndefined ? realm.string(",") : try realm.toStringValue(args[0])
        let r = realm.heap.root(sepV)
        defer { realm.heap.popRoots(to: r.slot) }
        let sep = realm.heap.stringUnits(sepV)
        var sb = JSStringBuilder()
        for k in 0..<len {
            if k > 0 { for u in sep { sb.append(unit: u) } }
            let v = realm.taGet(args.this, k)
            if !v.isUndefined { sb.append(ascii: jsNumberToString(v.numberValue)) }
            if !realm.heap.canMakeString(length: sb.count) { throw realm.throwRangeError("Invalid string length") }
        }
        return realm.heap.newString(sb)
    }
    realm.defineMethod(tap, "toLocaleString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, _) = try realm.validateTypedArray(args.this, "toLocaleString")
        var sb = JSStringBuilder()
        let key = realm.heap.key("toLocaleString")
        for k in 0..<len {
            if k > 0 { sb.append(unit: 0x2C) }
            let v = realm.taGet(args.this, k)
            if v.isUndefined { continue }
            let f = try realm.getV(v, key)
            let s = try realm.toStringValue(try realm.call(f, this: v, args: []))
            for u in realm.heap.stringUnits(s) { sb.append(unit: u) }
        }
        return realm.heap.newString(sb)
    }
    // Array.prototype.toString when it exists (the spec shares it), else join.
    if case .value(let ats) = heap.getProperty(realm.arrayPrototype, heap.names.toString), heap.isCallable(ats),
       heap.getOwnProperty(realm.arrayPrototype, heap.names.toString) != nil {
        _ = heap.defineOwnProperty(tap, heap.names.toString, .data(ats, [.writable, .configurable]))
    } else {
        realm.defineMethod(tap, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let o = try realm.toObject(args.this)
            let r = realm.heap.root(o)
            defer { realm.heap.popRoots(to: r.slot) }
            let j = try realm.getV(o, realm.heap.key("join"))
            if realm.heap.isCallable(j) { return try realm.call(j, this: o, args: []) }
            return realm.string("[object Object]")
        }
    }

    // Mutation.
    realm.defineMethod(tap, "fill", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, _) = try realm.validateTypedArray(args.this, "fill")
        let num = try realm.toNumber(args[0])
        let s = jsRelIndex(jsToIntegerOrInfinity(try realm.toNumber(args[1])), len)
        let e = args[2].isUndefined ? len : jsRelIndex(jsToIntegerOrInfinity(try realm.toNumber(args[2])), len)
        let (i, len2, _) = try realm.validateTypedArray(args.this, "fill")
        let end = min(e, len2)
        if s < end { for k in s..<end { realm.heap.typedArraySetElement(i, k, num) } }
        return args.this
    }
    realm.defineMethod(tap, "reverse", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (i, len, _) = try realm.validateTypedArray(args.this, "reverse")
        var lo = 0, hi = len - 1
        while lo < hi {
            let a = realm.heap.typedArrayElement(i, lo)?.numberValue ?? 0
            let b = realm.heap.typedArrayElement(i, hi)?.numberValue ?? 0
            realm.heap.typedArraySetElement(i, lo, b)
            realm.heap.typedArraySetElement(i, hi, a)
            lo += 1; hi -= 1
        }
        return args.this
    }
    realm.defineMethod(tap, "copyWithin", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, _) = try realm.validateTypedArray(args.this, "copyWithin")
        let to = jsRelIndex(jsToIntegerOrInfinity(try realm.toNumber(args[0])), len)
        let from = jsRelIndex(jsToIntegerOrInfinity(try realm.toNumber(args[1])), len)
        let fin = args[2].isUndefined ? len : jsRelIndex(jsToIntegerOrInfinity(try realm.toNumber(args[2])), len)
        let count = min(fin - from, len - to)
        if count > 0 {
            let (_, len2, _) = try realm.validateTypedArray(args.this, "copyWithin")
            let c = min(count, len2 - from, len2 - to)
            if c > 0 { realm.taCopy(args.this, from, args.this, to, c) }
        }
        return args.this
    }
    realm.defineMethod(tap, "set", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        guard h.kind(args.this) == .typedArray else { throw realm.throwTypeError("%TypedArray%.prototype.set called on incompatible receiver") }
        let off = jsToIntegerOrInfinity(try realm.toNumber(args[1]))
        if off < 0 { throw realm.throwRangeError("offset is out of bounds") }
        let (_, tlen, _) = try realm.validateTypedArray(args.this, "set")
        let src = args[0]
        if h.kind(src) == .typedArray {
            let (_, slen, _) = try realm.validateTypedArray(src, "set")
            if off == .infinity || Double(slen) + off > Double(tlen) { throw realm.throwRangeError("offset is out of bounds") }
            realm.taCopy(src, 0, args.this, Int(off), slen)
            return .undefined
        }
        let o = try realm.toObject(src)
        let r = h.root(o)
        defer { h.popRoots(to: r.slot) }
        let slen = try realm.toLength(try realm.getV(o, h.names.length))
        if off == .infinity || Double(slen) + off > Double(tlen) { throw realm.throwRangeError("offset is out of bounds") }
        let base = Int(off)
        for k in 0..<slen {
            let v = try realm.getV(o, try realm.toPropertyKey(.number(k)))
            try realm.typedArraySetElementJS(args.this, base + k, v)
        }
        return .undefined
    }
    realm.defineMethod(tap, "slice", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, _) = try realm.validateTypedArray(args.this, "slice")
        let s = jsRelIndex(jsToIntegerOrInfinity(try realm.toNumber(args[0])), len)
        let e = args[1].isUndefined ? len : jsRelIndex(jsToIntegerOrInfinity(try realm.toNumber(args[1])), len)
        let count = max(e - s, 0)
        let a = try realm.typedArraySpeciesCreate(args.this, [.number(count)], "slice")
        let r = realm.heap.root(a)
        defer { realm.heap.popRoots(to: r.slot) }
        if count > 0 {
            let (_, len2, _) = try realm.validateTypedArray(args.this, "slice")
            let end = min(e, len2)
            if end > s { realm.taCopy(args.this, s, a, 0, end - s) }
        }
        return a
    }
    realm.defineMethod(tap, "subarray", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        guard let i = h.objectIndex(args.this), h.objects[i].kind == .typedArray else {
            throw realm.throwTypeError("%TypedArray%.prototype.subarray called on incompatible receiver")
        }
        let buf = h.slot(args.this, 0)
        let t = h.typedArrayType(i)
        let srcLen = h.typedArrayLength(i)
        let tracking = h.typedArrayIsLengthTracking(args.this)
        let srcOff = Int(h.slot(args.this, 2).numberValue)
        let s = jsRelIndex(jsToIntegerOrInfinity(try realm.toNumber(args[0])), srcLen)
        var a: [JSValue] = [buf, .number(srcOff + s * t.size)]
        if !(tracking && args[1].isUndefined) {
            let e = args[1].isUndefined ? srcLen : jsRelIndex(jsToIntegerOrInfinity(try realm.toNumber(args[1])), srcLen)
            a.append(.number(max(e - s, 0)))
        }
        let c = try realm.speciesConstructor(args.this, default: realm.intrinsic(t.ctorIntrinsic))
        let r = h.root(c)
        defer { h.popRoots(to: r.slot) }
        return try realm.typedArrayCreate(c, a, "subarray")
    }

    // Sorting.
    func sortValues(_ realm: JSRealm, _ vals: [JSValue], _ cmp: JSValue) throws(JSThrow) -> [JSValue] {
        var a = vals
        var tmp = vals
        var width = 1
        let n = a.count
        func less(_ x: JSValue, _ y: JSValue) throws(JSThrow) -> Bool {   // y < x ?
            if cmp.isUndefined {
                let p = x.numberValue, q = y.numberValue
                if q.isNaN { return false }
                if p.isNaN { return true }
                if q < p { return true }
                if q == 0 && p == 0 { return q.sign == .minus && p.sign == .plus }
                return false
            }
            let v = try realm.toNumber(try realm.call(cmp, this: .undefined, args: [y, x]))
            return v < 0
        }
        while width < n {
            var lo = 0
            while lo < n {
                let mid = min(lo + width, n), hi = min(lo + 2 * width, n)
                var i = lo, j = mid, k = lo
                while i < mid && j < hi {
                    if try less(a[i], a[j]) { tmp[k] = a[j]; j += 1 } else { tmp[k] = a[i]; i += 1 }
                    k += 1
                }
                while i < mid { tmp[k] = a[i]; i += 1; k += 1 }
                while j < hi { tmp[k] = a[j]; j += 1; k += 1 }
                lo += 2 * width
            }
            swap(&a, &tmp)
            width *= 2
        }
        return a
    }
    func snapshot(_ realm: JSRealm, _ o: JSValue, _ len: Int) -> [JSValue] {
        var v: [JSValue] = []
        v.reserveCapacity(len)
        for k in 0..<len { v.append(realm.taGet(o, k)) }
        return v
    }
    realm.defineMethod(tap, "sort", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let cmp = args[0]
        if !cmp.isUndefined && !realm.heap.isCallable(cmp) { throw realm.throwTypeError("The comparison function must be either a function or undefined") }
        let (_, len, _) = try realm.validateTypedArray(args.this, "sort")
        let sorted = try sortValues(realm, snapshot(realm, args.this, len), cmp)
        if let i = realm.heap.objectIndex(args.this) {
            for (k, v) in sorted.enumerated() { realm.heap.typedArraySetElement(i, k, v.numberValue) }
        }
        return args.this
    }
    realm.defineMethod(tap, "toSorted", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let cmp = args[0]
        if !cmp.isUndefined && !realm.heap.isCallable(cmp) { throw realm.throwTypeError("The comparison function must be either a function or undefined") }
        let (i, len, t) = try realm.validateTypedArray(args.this, "toSorted")
        _ = i
        let a = try realm.newTypedArray(type: t, length: len)
        let r = realm.heap.root(a)
        defer { realm.heap.popRoots(to: r.slot) }
        let sorted = try sortValues(realm, snapshot(realm, args.this, len), cmp)
        if let ai = realm.heap.objectIndex(a) { for (k, v) in sorted.enumerated() { realm.heap.typedArraySetElement(ai, k, v.numberValue) } }
        return a
    }
    realm.defineMethod(tap, "toReversed", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, t) = try realm.validateTypedArray(args.this, "toReversed")
        let a = try realm.newTypedArray(type: t, length: len)
        if let ai = realm.heap.objectIndex(a) {
            for k in 0..<len { realm.heap.typedArraySetElement(ai, k, realm.taGet(args.this, len - 1 - k).numberValue) }
        }
        return a
    }
    realm.defineMethod(tap, "with", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let (_, len, t) = try realm.validateTypedArray(args.this, "with")
        let rel = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
        let actual = rel >= 0 ? rel : Double(len) + rel
        let num = try realm.toNumber(args[1])
        guard let i = realm.heap.objectIndex(args.this), actual >= 0, actual < Double(realm.heap.typedArrayLength(i)) else {
            throw realm.throwRangeError("Invalid typed array index")
        }
        let ai = Int(actual)
        let a = try realm.newTypedArray(type: t, length: len)
        if let x = realm.heap.objectIndex(a) {
            for k in 0..<len { realm.heap.typedArraySetElement(x, k, k == ai ? num : realm.taGet(args.this, k).numberValue) }
        }
        return a
    }
}

/// %ArrayIteratorPrototype%.next with the iteration kinds (flags user1 =
/// keys, user2 = entries (jsbuiltins_array.swift's convention), neither = values) and typed array sources (a
/// detached or out-of-bounds one is a TypeError). String iterators
/// (user3) keep their own prototype.
func jsInstallArrayIteratorKinds(_ realm: JSRealm) {
    let aitp = realm.intrinsic(.arrayIteratorPrototype)
    guard aitp.isObject else { return }
    realm.defineMethod(aitp, "next", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let it = args.this
        guard h.kind(it) == .iterator, !h.flags(it).contains(.user3) else {
            throw realm.throwTypeError("next method called on an incompatible receiver " + realm.describeForError(it))
        }
        let src = h.slot(it, 0)
        if src.isUndefined { return try realm.iterResult(.undefined, done: true) }
        let f = h.flags(it)
        let i = Int(h.internalInt(it))
        var len: Int
        if h.kind(src) == .typedArray {
            guard let si = h.objectIndex(src), h.typedArrayView(si) != nil else {
                throw realm.throwTypeError("Cannot perform %ArrayIteratorPrototype%.next on a detached ArrayBuffer")
            }
            len = h.typedArrayLength(si)
        } else if h.kind(src) == .array {
            len = Int(h.arrayLength(src))
        } else {
            len = try realm.toLength(try realm.getV(src, h.names.length))
        }
        if i >= len {
            h.setSlot(it, 0, .undefined)
            return try realm.iterResult(.undefined, done: true)
        }
        h.setInternalInt(it, Int64(i + 1))
        if f.contains(.user1) { return try realm.iterResult(.number(i), done: false) }
        let k: JSPropertyKey = i < 0xFFFF_FFFF ? .index(UInt32(i)) : try realm.toPropertyKey(.number(i))
        let v = try realm.getV(src, k)
        if f.contains(.user2) {
            let depth = h.rootDepth
            defer { h.popRoots(to: depth) }
            _ = h.root(v)
            return try realm.iterResult(realm.makeEntryPair(.number(i), v), done: false)
        }
        return try realm.iterResult(v, done: false)
    }
}
