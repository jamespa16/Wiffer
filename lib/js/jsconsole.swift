// console and a util.inspect-like value formatter (ROADMAP Phase 9F).
//
//     let console = jsInstallConsole(realm, now: { ms }) { level, text in ... }
//         // defines the global `console`: log info debug warn error trace
//         // table assert time timeEnd timeLog count countReset group
//         // groupCollapsed groupEnd dir clear. Every line of output goes
//         // to the sink with its level; group indentation is already in
//         // `text` (multi-line messages are indented line by line).
//
//     jsInspect(realm, value, JSInspectOptions()) -> String   (REPL results)
//     jsFormat(realm, args)  -> String       console.log's argument handling:
//         a leading string is a format string (%s %d %i %f %j %o %O %c %%),
//         the rest are appended, strings as they are and other values
//         inspected.
//
// Formatting follows Node's util.inspect (which also reads like browser
// consoles): `{ a: 1, b: 'x' }`, `[ 1, 2, 3 ]`, `[Function: f]`, `[class A]`,
// `<ref *1>` and `[Circular *1]`, `<1 empty item>`, errors as their stack,
// `[Getter]`; lines break at 80 columns, long number arrays go in columns.
// Inspecting never runs script: getters aren't called, and only own data
// is read. (Date and RegExp print through their built-in methods.)

public struct JSInspectOptions {
    /// Nesting levels shown in full (deeper objects print as [Object]).
    public var depth = 2
    public var breakLength = 80
    public var maxArrayLength = 100
    public var maxStringLength = 10_000
    /// Top-level strings print as is (console.log), not quoted.
    public var rawStrings = false
    public init() {}
}

public enum JSConsoleLevel: UInt8 {
    case log, info, debug, warn, error
}

public func jsInspect(_ realm: JSRealm, _ v: JSValue, _ options: JSInspectOptions = JSInspectOptions()) -> String {
    let ins = JSInspector(realm, options)
    return ins.inspect(v)
}

/// util.format: console.log's argument handling.
public func jsFormat(_ realm: JSRealm, _ args: [JSValue]) -> String {
    let ins = JSInspector(realm, JSInspectOptions())
    return ins.format(args)
}

// MARK: Inspector

final class JSInspector {
    unowned(unsafe) let realm: JSRealm
    let heap: JSHeap
    var opts: JSInspectOptions
    var seen: [JSHandle] = []
    var circular: [(JSHandle, Int)] = []
    var currentDepth = 0
    var indentation = 0

    init(_ realm: JSRealm, _ opts: JSInspectOptions) {
        self.realm = realm
        self.heap = realm.heap
        self.opts = opts
    }

    func inspect(_ v: JSValue) -> String {
        seen = []
        circular = []
        currentDepth = 0
        indentation = 0
        return formatValue(v, 0, topLevel: true)
    }

    // MARK: console.log's format string

    func format(_ args: [JSValue]) -> String {
        if args.isEmpty { return "" }
        var out = ""
        var next = 0
        if args[0].isString {
            next = 1
            let f = heap.stringUnits(args[0])
            var lastPos = 0
            var i = 0
            var cur = ""
            func flushTo(_ end: Int) {
                if lastPos < end { cur += unitsToString(f, lastPos, end) }
            }
            while i + 1 < f.count {
                if f[i] == 0x25 {   // %
                    let c = f[i + 1]
                    if c == 0x25 {  // %%
                        flushTo(i)
                        cur += "%"
                        lastPos = i + 2
                        i += 2
                        continue
                    }
                    if next < args.count {
                        var rep: String? = nil
                        switch c {
                        case 0x73: rep = formatS(args[next])                       // s
                        case 0x64: rep = formatD(args[next])                       // d
                        case 0x69: rep = formatI(args[next])                       // i
                        case 0x66: rep = formatF(args[next])                       // f
                        case 0x6A: rep = formatJ(args[next])                       // j
                        case 0x6F:                                                  // o
                            var o = opts; o.depth = 4; o.rawStrings = false
                            rep = JSInspector(realm, o).inspect(args[next])
                        case 0x4F:                                                  // O
                            var o = opts; o.rawStrings = false
                            rep = JSInspector(realm, o).inspect(args[next])
                        case 0x63: rep = ""                                         // c
                        default: break
                        }
                        if let r = rep {
                            flushTo(i)
                            cur += r
                            lastPos = i + 2
                            next += 1
                            i += 2
                            continue
                        }
                    }
                }
                i += 1
            }
            flushTo(f.count)
            out = cur
        }
        var k = next
        while k < args.count {
            if k > 0 { out += " " }
            let a = args[k]
            if a.isString { out += heap.swiftString(a) } else {
                let ins = JSInspector(realm, opts)
                out += ins.inspect(a)
            }
            k += 1
        }
        return out
    }

    func formatS(_ v: JSValue) -> String {
        if v.isString { return heap.swiftString(v) }
        if v.isNumber { return numberString(v.numberValue) }
        if v.isBigInt { return bigintString(v) }
        if v.isSymbol || v.isObject {
            if v.isObject && !heap.isCallable(v) && heap.kind(v) != .error {
                // Objects with a user toString print through it; others inspect.
                var o = opts; o.depth = 0; o.rawStrings = false
                return JSInspector(realm, o).inspect(v)
            }
            var o = opts; o.depth = 0; o.rawStrings = false
            return JSInspector(realm, o).inspect(v)
        }
        return primitiveString(v)
    }

    func formatD(_ v: JSValue) -> String {
        if v.isObject { return "NaN" }
        if v.isSymbol { return "NaN" }
        if v.isBigInt { return bigintString(v) }
        if let d = try? realm.toNumber(v) { return numberString(d) }
        return "NaN"
    }

    func formatI(_ v: JSValue) -> String {
        if v.isObject || v.isSymbol { return "NaN" }
        if v.isBigInt { return bigintString(v) }
        if let d = try? realm.toNumber(v) {
            if d.isNaN || d.isInfinite { return "NaN" }
            return numberString(d.rounded(.towardZero) + 0)
        }
        return "NaN"
    }

    func formatF(_ v: JSValue) -> String {
        if v.isSymbol { return "NaN" }
        if v.isObject { return "NaN" }
        if let d = try? realm.toNumber(v) { return numberString(d) }
        return "NaN"
    }

    func formatJ(_ v: JSValue) -> String {
        let json = heap.getOwnProperty(realm.global, heap.key("JSON"))
        guard let j = json, j.value.isObject,
              let sf = heap.getOwnProperty(j.value, heap.key("stringify")), heap.isCallable(sf.value),
              let r = try? realm.call(sf.value, this: j.value, args: [v]) else { return "[Circular]" }
        if r.isString { return heap.swiftString(r) }
        return "undefined"
    }

    // MARK: Primitives

    func numberString(_ d: Double) -> String {
        if d == 0 && d.sign == .minus { return "-0" }
        return heap.swiftString(heap.numberToString(d))
    }

    func bigintString(_ v: JSValue) -> String {
        if let s = try? realm.toSwiftString(v) { return s + "n" }
        return "0n"
    }

    func primitiveString(_ v: JSValue) -> String {
        if v.isUndefined { return "undefined" }
        if v.isNull { return "null" }
        if v.isBool { return v == .true ? "true" : "false" }
        if v.isNumber { return numberString(v.numberValue) }
        if v.isBigInt { return bigintString(v) }
        if v.isSymbol { return symbolString(v) }
        return heap.swiftString(v)
    }

    func symbolString(_ v: JSValue) -> String {
        let d = heap.symbolDescription(v)
        return "Symbol(" + (d.isString ? heap.swiftString(d) : "") + ")"
    }

    /// A JS string as a quoted, escaped literal.
    func quote(_ v: JSValue) -> String {
        let u = heap.stringUnits(v)
        var hasSingle = false, hasDouble = false, hasBack = false
        for c in u {
            if c == 0x27 { hasSingle = true } else if c == 0x22 { hasDouble = true } else if c == 0x60 { hasBack = true }
        }
        var q: UInt16 = 0x27
        if hasSingle {
            if !hasDouble { q = 0x22 } else if !hasBack { q = 0x60 }
        }
        var out = String(UnicodeScalar(UInt8(truncatingIfNeeded: q)))
        var i = 0
        var limit = u.count
        var truncated = 0
        if limit > opts.maxStringLength { truncated = limit - opts.maxStringLength; limit = opts.maxStringLength }
        while i < limit {
            let c = u[i]
            i += 1
            if c == q || c == 0x5C { out += "\\"; out.unicodeScalars.append(UnicodeScalar(UInt8(truncatingIfNeeded: c))); continue }
            switch c {
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0x0D: out += "\\r"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0B: out += "\\v"
            case 0..<0x20, 0x7F:
                out += "\\x" + hex2(Int(c))
            case 0xD800...0xDBFF:
                if i < limit, u[i] >= 0xDC00 && u[i] <= 0xDFFF {
                    let cp = 0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(u[i]) - 0xDC00)
                    i += 1
                    if let s = UnicodeScalar(cp) { out.unicodeScalars.append(s) }
                } else { out += "\\u" + hex4(Int(c)) }
            case 0xDC00...0xDFFF:
                out += "\\u" + hex4(Int(c))
            default:
                if let s = UnicodeScalar(UInt32(c)) { out.unicodeScalars.append(s) }
            }
        }
        out.unicodeScalars.append(UnicodeScalar(UInt8(truncatingIfNeeded: q)))
        if truncated > 0 { out += "... \(truncated) more character" + (truncated > 1 ? "s" : "") }
        return out
    }

    func hex2(_ n: Int) -> String {
        let d: [UInt8] = Array("0123456789ABCDEF".utf8)
        return String(UnicodeScalar(d[(n >> 4) & 15])) + String(UnicodeScalar(d[n & 15]))
    }
    func hex4(_ n: Int) -> String { hex2((n >> 8) & 255) + hex2(n & 255) }

    func unitsToString(_ u: [UInt16], _ from: Int, _ to: Int) -> String {
        var out = ""
        var i = from
        while i < to {
            let c = u[i]
            i += 1
            if c >= 0xD800 && c <= 0xDBFF && i < to && u[i] >= 0xDC00 && u[i] <= 0xDFFF {
                let cp = 0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(u[i]) - 0xDC00)
                i += 1
                if let s = UnicodeScalar(cp) { out.unicodeScalars.append(s) }
            } else if let s = UnicodeScalar(UInt32(c)) { out.unicodeScalars.append(s) }
            else { out.unicodeScalars.append(UnicodeScalar(0xFFFD as UInt32)!) }
        }
        return out
    }

    // MARK: Objects

    func formatValue(_ v: JSValue, _ level: Int, topLevel: Bool = false) -> String {
        if !v.isObject {
            if v.isString { return topLevel && opts.rawStrings ? heap.swiftString(v) : quote(v) }
            return primitiveString(v)
        }
        // Circular?
        for h in seen where h == v.handle {
            var idx = 0
            for (ch, n) in circular where ch == v.handle { idx = n }
            if idx == 0 { idx = circular.count + 1; circular.append((v.handle, idx)) }
            return "[Circular *\(idx)]"
        }
        return formatObject(v, level)
    }

    func ownDataName(_ o: JSValue, _ name: String) -> JSValue? {
        if let p = heap.getOwnProperty(o, heap.key(name)), !p.isAccessor { return p.value }
        return nil
    }

    /// The constructor name found on the prototype chain, or nil (null prototype).
    func constructorName(_ o: JSValue) -> String? {
        var cur = o
        var steps = 0
        while cur.isObject && steps < 100 {
            steps += 1
            if let c = ownDataName(cur, "constructor"), c.isObject, heap.isCallable(c),
               let n = ownDataName(c, "name"), n.isString, heap.stringLength(n) > 0 {
                return heap.swiftString(n)
            }
            cur = heap.getPrototypeOf(cur)
        }
        return nil
    }

    func isIdentifier(_ u: [UInt16]) -> Bool {
        if u.isEmpty { return false }
        for (i, c) in u.enumerated() {
            let ok = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F || c == 0x24
                || (i > 0 && c >= 0x30 && c <= 0x39)
            if !ok { return false }
        }
        return true
    }

    func formatKey(_ k: JSPropertyKey) -> String {
        if k.isSymbol { return "[" + symbolString(.symbol(k.handle)) + "]" }
        let kv = heap.keyValue(k)
        let u = heap.stringUnits(kv)
        if isIdentifier(u) { return unitsToString(u, 0, u.count) }
        return quote(kv)
    }

    func formatProperty(_ o: JSValue, _ k: JSPropertyKey, _ p: JSProperty, _ level: Int, arrayStyle: Bool = false) -> String {
        var s: String
        if p.isAccessor {
            let hasG = p.getter.isObject, hasS = p.setter.isObject
            s = hasG ? (hasS ? "[Getter/Setter]" : "[Getter]") : (hasS ? "[Setter]" : "undefined")
        } else {
            indentation += 2
            s = formatValue(p.value, level + 1)
            indentation -= 2
        }
        if arrayStyle { return s }
        return formatKey(k) + ": " + s
    }

    func fnBase(_ o: JSValue, _ ctor: String?) -> String {
        let nameV = ownDataName(o, "name")
        let name = (nameV != nil && nameV!.isString) ? heap.swiftString(nameV!) : ""
        if heap.flags(o).contains(.classConstructor) {
            var s = "[class " + (name.isEmpty ? "(anonymous)" : name)
            let p = heap.getPrototypeOf(o)
            if p.isObject, p.handle != realm.functionPrototype.handle, let pn = ownDataName(p, "name"), pn.isString,
               heap.stringLength(pn) > 0 {
                s += " extends " + heap.swiftString(pn)
            }
            return s + "]"
        }
        let kindName = "Function"
        return "[" + kindName + (name.isEmpty ? " (anonymous)" : ": " + name) + "]"
    }

    func formatObject(_ o: JSValue, _ level: Int) -> String {
        let kind = heap.kind(o)
        let ctor = constructorName(o)
        var base = ""
        var braceOpen = "{"
        var braceClose = "}"
        var isArray = false
        var keys: [JSPropertyKey] = heap.ownKeys(o)
        var prefixOverride: String? = nil

        func prefix(_ fallback: String, _ size: Int = -1) -> String {
            if let c = ctor {
                return c + (size >= 0 ? "(\(size))" : "") + " "
            }
            return "[" + fallback + (size >= 0 ? "(\(size))" : "") + ": null prototype] "
        }

        switch kind {
        case .array:
            isArray = true
            braceOpen = "["; braceClose = "]"
            let n = heap.arrayLength(o)
            if ctor != "Array" { prefixOverride = prefix("Array", Int(n)) }
        case .function, .boundFunction, .nativeFunction:
            base = fnBase(o, ctor)
        case .error:
            base = errorBase(o)
        case .date:
            base = callToString(o, method: "toISOString") ?? "Invalid Date"
            if let c = ctor, c != "Date" { base = c + " " + base }
        case .regexp:
            base = (try? realm.toSwiftString(o)) ?? "/(?:)/"
        case .numberWrapper, .booleanWrapper, .stringWrapper, .symbolWrapper, .bigintWrapper:
            let tn: String
            switch kind {
            case .numberWrapper: tn = "Number"
            case .booleanWrapper: tn = "Boolean"
            case .stringWrapper: tn = "String"
            case .symbolWrapper: tn = "Symbol"
            default: tn = "BigInt"
            }
            let pv = heap.slotCount(o) > 0 ? heap.slot(o, 0) : JSValue.undefined
            base = "[" + tn + ": " + (pv.isString ? quote(pv) : primitiveString(pv)) + "]"
            if kind == .stringWrapper { keys = keys.filter { !$0.isIndex && !($0.isString && heap.swiftString(heap.keyValue($0)) == "length") } }
        case .promise:
            prefixOverride = prefix("Promise")
        case .map, .set:
            var n = 0
            let stride = kind == .map ? 2 : 1
            var i = 0
            while i < heap.slotCount(o) { if !heap.slot(o, i).isHole { n += 1 }; i += stride }
            prefixOverride = prefix(kind == .map ? "Map" : "Set", n)
        case .weakMap: prefixOverride = prefix("WeakMap")
        case .weakSet: prefixOverride = prefix("WeakSet")
        case .arguments:
            prefixOverride = "[Arguments] "
            braceOpen = "["; braceClose = "]"
            isArray = true
        case .proxy:
            return "Proxy"
        default:
            if ctor == nil { prefixOverride = "[Object: null prototype] " }
            else if ctor! != "Object" { prefixOverride = ctor! + " " }
        }

        // Which keys to show: own enumerable, not array indexes for arrays.
        var shown: [(JSPropertyKey, JSProperty)] = []
        var indexed: [(UInt32, JSProperty)] = []
        for k in keys {
            guard let p = heap.getOwnProperty(o, k), p.enumerable else { continue }
            if k.isIndex && (isArray || kind == .stringWrapper) { indexed.append((k.index, p)); continue }
            shown.append((k, p))
        }
        let isFn = kind == .function || kind == .boundFunction || kind == .nativeFunction
        let isBoxedOrSimple = !base.isEmpty
        if isBoxedOrSimple && shown.isEmpty && !isArray {
            return base   // [Function: f], errors, dates, ...
        }
        if level > opts.depth {
            if isArray { return "[Array]" }
            if !base.isEmpty { return base }
            let n = ctor ?? "Object: null prototype"
            return "[" + n + "]"
        }

        seen.append(o.handle)
        currentDepth = level
        var output: [String] = []
        var shownBefore = 0
        if isArray {
            let total = kind == .array ? Int(heap.arrayLength(o)) : indexed.count
            var pos = 0
            var count = 0
            var idx = 0
            var emptyRun = 0
            func flushEmpty() {
                if emptyRun > 0 { output.append("<\(emptyRun) empty item" + (emptyRun > 1 ? "s" : "") + ">"); emptyRun = 0; count += 1 }
            }
            while pos < total && count < opts.maxArrayLength {
                if idx < indexed.count && Int(indexed[idx].0) == pos {
                    flushEmpty()
                    if count >= opts.maxArrayLength { break }
                    output.append(formatProperty(o, .index(UInt32(pos)), indexed[idx].1, level, arrayStyle: true))
                    count += 1
                    idx += 1
                    pos += 1
                } else {
                    // A hole run up to the next present index.
                    let nextPos = idx < indexed.count ? Int(indexed[idx].0) : total
                    emptyRun = nextPos - pos
                    pos = nextPos
                    flushEmpty()
                }
            }
            if pos < total {
                let remaining = total - pos
                output.append("... \(remaining) more item" + (remaining > 1 ? "s" : ""))
            }
        }
        for (k, p) in shown where !(isArray && k.isString && heap.swiftString(heap.keyValue(k)) == "length") {
            output.append(formatProperty(o, k, p, level))
        }
        let extra = ""
        if kind == .map || kind == .set {
            let stride = kind == .map ? 2 : 1
            var i = 0
            while i < heap.slotCount(o) {
                let k = heap.slot(o, i)
                if !k.isHole {
                    indentation += 2
                    var e = formatValue(k, level + 1)
                    if kind == .map { e += " => " + formatValue(heap.slot(o, i + 1), level + 1) }
                    indentation -= 2
                    output.insert(e, at: min(output.count, shownBefore))
                    shownBefore += 1
                }
                i += stride
            }
        } else if kind == .promise {
            var e: String
            switch realm.promiseState(o) {
            case .pending: e = "<pending>"
            case .fulfilled:
                indentation += 2
                e = formatValue(realm.promiseResult(o), level + 1)
                indentation -= 2
            case .rejected:
                indentation += 2
                e = "<rejected> " + formatValue(realm.promiseResult(o), level + 1)
                indentation -= 2
            }
            output.insert(e, at: 0)
        }
        seen.removeLast()

        var start = prefixOverride ?? ""
        if !extra.isEmpty { start += extra }
        if isFn && !base.isEmpty { start = "" }

        var result: String
        if output.isEmpty {
            if !base.isEmpty { result = base }
            else { result = start + braceOpen + braceClose }
        } else {
            let opening = (base.isEmpty ? "" : base + " ") + start + braceOpen
            var out2 = output
            if isArray && output.count > 6 { out2 = groupArrayElements(output, o) }
            result = reduceToSingleString(out2, opening, braceClose, level, entries: output.count)
        }
        // <ref *n> if something inside pointed back at this object.
        for (h, n) in circular where h == o.handle { result = "<ref *\(n)> " + result }
        return result
    }

    func errorBase(_ o: JSValue) -> String {
        if let s = ownDataName(o, "stack"), s.isString, heap.stringLength(s) > 0 {
            var text = heap.swiftString(s)
            if indentation > 0 {
                let pad = String(repeating: " ", count: indentation)
                var out = ""
                for sc in text.unicodeScalars {
                    out.unicodeScalars.append(sc)
                    if sc == "\n" { out += pad }
                }
                text = out
            }
            return text
        }
        let n = ownDataName(o, "name")
        let m = ownDataName(o, "message")
        var name = "Error"
        if let n = n, n.isString { name = heap.swiftString(n) } else if let c = constructorName(o) { name = c }
        var s = name
        if let m = m, m.isString, heap.stringLength(m) > 0 { s += ": " + heap.swiftString(m) }
        return "[" + s + "]"
    }

    func callToString(_ o: JSValue, method: String) -> String? {
        let proto = heap.getPrototypeOf(o)
        guard proto.isObject, let f = ownDataName(proto, method), heap.isCallable(f) else { return nil }
        if heap.termination != nil { return nil }
        guard let r = try? realm.call(f, this: o, args: []), r.isString else { return nil }
        return heap.swiftString(r)
    }

    // MARK: Layout

    func width(_ s: String) -> Int { s.unicodeScalars.count }

    func reduceToSingleString(_ output: [String], _ open: String, _ close: String, _ level: Int, entries: Int) -> String {
        if currentDepth - level < 3 && entries == output.count {
            // Single line when it fits and no entry is multi-line.
            var total = output.count + indentation + width(open) + 10
            var multi = false
            for s in output {
                total += width(s)
                for c in s.unicodeScalars where c == "\n" { multi = true }
            }
            if !multi && total + output.count <= opts.breakLength {
                var line = open + " "
                for (i, s) in output.enumerated() { if i > 0 { line += ", " }; line += s }
                return line + " " + close
            }
        }
        let pad = String(repeating: " ", count: indentation)
        var out = open + "\n" + pad + "  "
        for (i, s) in output.enumerated() {
            if i > 0 { out += ",\n" + pad + "  " }
            out += s
        }
        return out + "\n" + pad + close
    }

    func groupArrayElements(_ output: [String], _ value: JSValue) -> [String] {
        var totalLength = 0
        var maxLength = 0
        var outputLength = output.count
        if opts.maxArrayLength < output.count || (output.last?.hasPrefix("... ") ?? false) { outputLength -= 1 }
        if outputLength <= 0 { return output }
        let separatorSpace = 2
        var dataLen: [Int] = []
        for i in 0..<outputLength {
            let len = width(output[i])
            dataLen.append(len)
            totalLength += len + separatorSpace
            if maxLength < len { maxLength = len }
        }
        let actualMax = maxLength + separatorSpace
        if actualMax * 3 + indentation < opts.breakLength
            && (Double(totalLength) / Double(actualMax) > 5 || maxLength <= 6) {
            let averageBias = (Double(actualMax) - Double(totalLength) / Double(output.count)).squareRoot()
            let biasedMax = max(Double(actualMax) - 3 - averageBias, 1)
            var columns = Int((2.5 * biasedMax * Double(outputLength)).squareRoot() / biasedMax + 0.5)
            columns = min(columns, (opts.breakLength - indentation) / actualMax)
            columns = min(columns, 12)
            columns = min(columns, 15)
            if columns <= 1 { return output }
            var maxLineLength: [Int] = []
            for i in 0..<columns {
                var lineLength = 0
                var j = i
                while j < outputLength { if dataLen[j] > lineLength { lineLength = dataLen[j] }; j += columns }
                maxLineLength.append(lineLength + separatorSpace)
            }
            // Numbers and bigints are right-aligned.
            var padStart = true
            var allNumbers = true
            var idx = 0
            while idx < outputLength {
                let pv = heap.getOwnProperty(value, .index(UInt32(idx)))?.value ?? .undefined
                if !pv.isNumber && !pv.isBigInt { allNumbers = false; break }
                idx += 1
            }
            if !allNumbers { padStart = false }
            var tmp: [String] = []
            var i = 0
            while i < outputLength {
                let maxI = min(i + columns, outputLength)
                var str = ""
                var j = i
                while j < maxI - 1 {
                    let cell = output[j] + ", "
                    let padLen = maxLineLength[j - i] - dataLen[j] - separatorSpace
                    let pad = String(repeating: " ", count: max(0, padLen))
                    str += padStart ? pad + cell : cell + pad
                    j += 1
                }
                if padStart {
                    let padLen = maxLineLength[j - i] - separatorSpace - dataLen[j]
                    str += String(repeating: " ", count: max(0, padLen)) + output[j]
                } else {
                    str += output[j]
                }
                tmp.append(str)
                i += columns
            }
            if outputLength < output.count { tmp.append(output[outputLength]) }
            return tmp
        }
        return output
    }
}

// MARK: console

public final class JSConsole {
    unowned(unsafe) let realm: JSRealm
    let sink: (JSConsoleLevel, String) -> Void
    let now: () -> Double
    var indent = ""
    var counts: [(String, Int)] = []
    var timers: [(String, Double)] = []
    public var options = JSInspectOptions()

    init(_ realm: JSRealm, now: @escaping () -> Double, sink: @escaping (JSConsoleLevel, String) -> Void) {
        self.realm = realm
        self.now = now
        self.sink = sink
    }

    func emit(_ level: JSConsoleLevel, _ text: String) {
        if indent.isEmpty { sink(level, text); return }
        var out = indent
        for sc in text.unicodeScalars {
            out.unicodeScalars.append(sc)
            if sc == "\n" { out += indent }
        }
        sink(level, out)
    }

    func format(_ args: [JSValue]) -> String {
        let ins = JSInspector(realm, options)
        ins.opts.rawStrings = true
        return ins.format(args)
    }

    func label(_ args: JSArgs) throws(JSThrow) -> String {
        if args.count == 0 || args[0].isUndefined { return "default" }
        return try realm.toSwiftString(args[0])
    }

    func fmtMs(_ ms: Double) -> String {
        let d = ms
        if d >= 1000 {
            let s = (d / 1000 * 1000).rounded() / 1000
            return realm.heap.swiftString(realm.heap.numberToString(s)) + "s"
        }
        let r = (d * 1000).rounded() / 1000
        return realm.heap.swiftString(realm.heap.numberToString(r)) + "ms"
    }

    func table(_ data: JSValue, _ filter: JSValue) -> String? {
        let heap = realm.heap
        guard data.isObject else { return nil }
        let ins = JSInspector(realm, options)
        var o = options; o.depth = 0; o.rawStrings = false
        let cell = JSInspector(realm, o)
        _ = ins
        var colNames: [String] = []
        var rows: [(String, [String: String], String?)] = []   // index label, cells, values cell
        var hasValues = false
        func cellText(_ v: JSValue) -> String { cell.inspect(v) }
        var onlyCols: [String]? = nil
        if filter.isObject && heap.kind(filter) == .array {
            var cols: [String] = []
            let n = Int(heap.arrayLength(filter))
            for i in 0..<min(n, 1000) {
                if let p = heap.getOwnProperty(filter, .index(UInt32(i))), p.value.isString { cols.append(heap.swiftString(p.value)) }
            }
            onlyCols = cols
        }
        var entries: [(String, JSValue)] = []
        for k in heap.ownKeys(data) where !k.isSymbol {
            guard let p = heap.getOwnProperty(data, k), p.enumerable, !p.isAccessor else { continue }
            let name = heap.swiftString(heap.keyValue(k))
            if heap.kind(data) == .array && name == "length" { continue }
            entries.append((name, p.value))
            if entries.count >= 1000 { break }
        }
        for (name, v) in entries {
            if v.isObject && !heap.isCallable(v) {
                var cells: [String: String] = [:]
                for k in heap.ownKeys(v) where !k.isSymbol {
                    guard let p = heap.getOwnProperty(v, k), p.enumerable, !p.isAccessor else { continue }
                    let cn = heap.swiftString(heap.keyValue(k))
                    if heap.kind(v) == .array && cn == "length" { continue }
                    if let only = onlyCols, !only.contains(cn) { continue }
                    if !colNames.contains(cn) { colNames.append(cn) }
                    cells[cn] = cellText(p.value)
                }
                rows.append((name, cells, nil))
            } else {
                hasValues = true
                rows.append((name, [:], cellText(v)))
            }
        }
        if let only = onlyCols { colNames = only }
        var header = ["(index)"] + colNames
        if hasValues { header.append("Values") }
        var matrix: [[String]] = []
        for (name, cells, val) in rows {
            var line = [name]
            for c in colNames { line.append(cells[c] ?? "") }
            if hasValues { line.append(val ?? "") }
            matrix.append(line)
        }
        func w(_ s: String) -> Int { s.unicodeScalars.count }
        var widths = header.map { w($0) + 2 }
        for line in matrix { for (i, c) in line.enumerated() { widths[i] = max(widths[i], w(c) + 2) } }
        func center(_ s: String, _ width: Int) -> String {
            let total = width - w(s)
            let left = total / 2
            return String(repeating: " ", count: left) + s + String(repeating: " ", count: total - left)
        }
        func rule(_ l: String, _ m: String, _ r: String) -> String {
            var s = l
            for (i, wd) in widths.enumerated() { if i > 0 { s += m }; s += String(repeating: "\u{2500}", count: wd) }
            return s + r
        }
        func row(_ cells: [String]) -> String {
            var s = "\u{2502}"
            for (i, c) in cells.enumerated() { if i > 0 { s += "\u{2502}" }; s += center(c, widths[i]) }
            return s + "\u{2502}"
        }
        var out = rule("\u{250C}", "\u{252C}", "\u{2510}") + "\n" + row(header) + "\n" + rule("\u{251C}", "\u{253C}", "\u{2524}")
        for line in matrix { out += "\n" + row(line) }
        out += "\n" + rule("\u{2514}", "\u{2534}", "\u{2518}")
        return out
    }
}

@discardableResult
public func jsInstallConsole(_ realm: JSRealm, now: @escaping () -> Double = { 0 },
                             sink: @escaping (JSConsoleLevel, String) -> Void) -> JSConsole {
    let c = JSConsole(realm, now: now, sink: sink)
    let con = realm.heap.newObject(proto: realm.objectPrototype, kind: .ordinary, flags: [.extensible])
    realm.defineGlobal("console", con)
    func level(_ name: String, _ lv: JSConsoleLevel) {
        realm.defineMethod(con, name, length: 0) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            c.emit(lv, c.format(args.values))
            return .undefined
        }
    }
    level("log", .log); level("info", .info); level("debug", .debug)
    level("warn", .warn); level("error", .error)
    realm.defineMethod(con, "trace", length: 0) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        var s = "Trace"
        if args.count > 0 { s += ": " + c.format(args.values) }
        c.emit(.error, s)
        return .undefined
    }
    realm.defineMethod(con, "dir", length: 1) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        var o = c.options; o.rawStrings = false
        c.emit(.log, jsInspect(realm, args[0], o))
        return .undefined
    }
    realm.defineMethod(con, "assert", length: 0) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if realm.heap.toBoolean(args[0]) { return .undefined }
        var rest = args.values
        if !rest.isEmpty { rest.removeFirst() }
        if rest.isEmpty { c.emit(.error, "Assertion failed") }
        else if rest[0].isString {
            var r2 = rest
            r2[0] = realm.string("Assertion failed: " + realm.heap.swiftString(rest[0]))
            c.emit(.error, c.format(r2))
        } else { c.emit(.error, "Assertion failed: " + c.format(rest)) }
        return .undefined
    }
    realm.defineMethod(con, "count", length: 0) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let l = try c.label(args)
        var n = 1
        var found = false
        for i in 0..<c.counts.count where c.counts[i].0 == l { c.counts[i].1 += 1; n = c.counts[i].1; found = true }
        if !found { c.counts.append((l, 1)) }
        c.emit(.log, l + ": \(n)")
        return .undefined
    }
    realm.defineMethod(con, "countReset", length: 0) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let l = try c.label(args)
        for i in 0..<c.counts.count where c.counts[i].0 == l { c.counts[i].1 = 0 }
        return .undefined
    }
    realm.defineMethod(con, "time", length: 0) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let l = try c.label(args)
        for i in 0..<c.timers.count where c.timers[i].0 == l {
            c.emit(.warn, "Timer '" + l + "' already exists")
            return .undefined
        }
        c.timers.append((l, c.now()))
        return .undefined
    }
    func timeEnd(_ name: String, _ remove: Bool) {
        realm.defineMethod(con, name, length: 0) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let l = try c.label(args)
            for i in 0..<c.timers.count where c.timers[i].0 == l {
                var s = l + ": " + c.fmtMs(c.now() - c.timers[i].1)
                if !remove && args.count > 1 {
                    var rest = args.values
                    rest.removeFirst()
                    s += " " + c.format(rest)
                }
                c.emit(.log, s)
                if remove { c.timers.remove(at: i) }
                return .undefined
            }
            c.emit(.warn, "Timer '" + l + "' does not exist")
            return .undefined
        }
    }
    timeEnd("timeEnd", true)
    timeEnd("timeLog", false)
    let group: JSNativeFunction = { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if args.count > 0 { c.emit(.log, c.format(args.values)) }
        c.indent += "  "
        return .undefined
    }
    realm.defineMethod(con, "group", length: 0, group)
    realm.defineMethod(con, "groupCollapsed", length: 0, group)
    realm.defineMethod(con, "groupEnd", length: 0) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if c.indent.count >= 2 { c.indent.removeLast(2) }
        return .undefined
    }
    realm.defineMethod(con, "table", length: 1) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if let t = c.table(args[0], args[1]) { c.emit(.log, t) } else { c.emit(.log, c.format(args.values)) }
        return .undefined
    }
    realm.defineMethod(con, "clear", length: 0) { [c] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        c.indent = ""
        return .undefined
    }
    return c
}
