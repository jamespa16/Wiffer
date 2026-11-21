// TextEncoder and TextDecoder (Encoding Standard) over lib/text: UTF-8
// out; UTF-8, UTF-16LE/BE and windows-1252 (with its labels, e.g.
// iso-8859-1 and ascii) in.

final class JSWebTextEncoder { init() {} }

final class JSWebTextDecoder {
    let encoding: TextEncoding
    let name: String
    let fatal: Bool
    let ignoreBOM: Bool
    var pending: [UInt8] = []
    var sawStart = false
    init(_ e: TextEncoding, name: String, fatal: Bool, ignoreBOM: Bool) {
        encoding = e; self.name = name; self.fatal = fatal; self.ignoreBOM = ignoreBOM
    }
}

func jswebEncodingName(_ e: TextEncoding) -> String {
    switch e {
    case .utf8: return "utf-8"
    case .utf16le: return "utf-16le"
    case .utf16be: return "utf-16be"
    default: return "windows-1252"
    }
}

/// Bytes at the end of `b` that start an incomplete UTF-8 sequence.
func jswebIncompleteUTF8Tail(_ b: [UInt8]) -> Int {
    var k = 1
    while k <= 3 && k <= b.count {
        let c = b[b.count - k]
        if c & 0xc0 == 0x80 { k += 1; continue }
        let need = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc0 ? 2 : 1
        return need > k ? k : 0
    }
    return 0
}

/// Strict UTF-8 validity (for TextDecoder's fatal mode).
func jswebValidUTF8(_ b: [UInt8]) -> Bool {
    var i = 0
    while i < b.count {
        let c = b[i]
        var need = 0
        var lo: UInt8 = 0x80, hi: UInt8 = 0xbf
        switch c {
        case 0x00...0x7f: i += 1; continue
        case 0xc2...0xdf: need = 1
        case 0xe0: need = 2; lo = 0xa0
        case 0xe1...0xec, 0xee, 0xef: need = 2
        case 0xed: need = 2; hi = 0x9f
        case 0xf0: need = 3; lo = 0x90
        case 0xf1...0xf3: need = 3
        case 0xf4: need = 3; hi = 0x8f
        default: return false
        }
        var j = 1
        while j <= need {
            if i + j >= b.count { return false }
            let x = b[i + j]
            if j == 1 { if x < lo || x > hi { return false } } else if x & 0xc0 != 0x80 { return false }
            j += 1
        }
        i += need + 1
    }
    return true
}

extension JSWeb {
    func installEncoding() {
        let web = self
        encoderClass = JSHostClass<JSWebTextEncoder>(realm: realm, name: "TextEncoder")
        encoderClass.define(methods: [
            JSHostMethod("encode", 0) { (realm: JSRealm, e: JSWebTextEncoder, args: JSArgs) throws(JSThrow) -> JSValue in
                let s = args[0].isUndefined ? "" : try web.str(args[0])
                return try web.uint8Array(Array(s.utf8))
            },
            JSHostMethod("encodeInto", 2) { (realm: JSRealm, e: JSWebTextEncoder, args: JSArgs) throws(JSThrow) -> JSValue in
                let src = try realm.toStringValue(args[0])
                let dst = args[1]
                guard dst.isObject, web.heap.kind(dst) == .typedArray, let i = web.heap.objectIndex(dst),
                      web.heap.typedArrayType(i) == .uint8 else {
                    throw web.typeError("Failed to execute 'encodeInto' on 'TextEncoder': parameter 2 is not of type 'Uint8Array'.")
                }
                let units = web.heap.stringUnits(src)
                var read = 0, written = 0
                if let view = web.heap.typedArrayView(i) {
                    var k = 0
                    while k < units.count {
                        var cp = UInt32(units[k])
                        var n = 1
                        if cp >= 0xd800 && cp <= 0xdbff && k + 1 < units.count && units[k + 1] >= 0xdc00 && units[k + 1] <= 0xdfff {
                            cp = 0x10000 + ((cp - 0xd800) << 10) + (UInt32(units[k + 1]) - 0xdc00)
                            n = 2
                        } else if cp >= 0xd800 && cp <= 0xdfff { cp = 0xfffd }
                        var enc: [UInt8] = []
                        charsetAppendUTF8(cp, to: &enc)
                        if written + enc.count > view.length { break }
                        for (j, byte) in enc.enumerated() { web.heap.byteStores[view.store][view.offset + written + j] = byte }
                        written += enc.count
                        read += n
                        k += n
                    }
                }
                let o = web.b.newObject()
                let d = web.heap.rootDepth
                _ = web.heap.root(o)
                web.setValue(o, "read", .number(read))
                web.setValue(o, "written", .number(written))
                web.heap.popRoots(to: d)
                return o
            },
        ], accessors: [
            JSHostAccessor("encoding", get: { (realm: JSRealm, e: JSWebTextEncoder) throws(JSThrow) -> JSValue in web.js("utf-8") }),
        ])
        encoderClass.exposeConstructor(length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSWebTextEncoder in JSWebTextEncoder() }
        setToStringTag(encoderClass.prototype, "TextEncoder")

        decoderClass = JSHostClass<JSWebTextDecoder>(realm: realm, name: "TextDecoder")
        decoderClass.define(methods: [
            JSHostMethod("decode", 0) { (realm: JSRealm, dec: JSWebTextDecoder, args: JSArgs) throws(JSThrow) -> JSValue in
                var bytes: [UInt8] = []
                if !args[0].isUndefined {
                    guard let bs = web.bufferSourceBytes(args[0]) else {
                        throw web.typeError("Failed to execute 'decode' on 'TextDecoder': The provided value is not of type '(ArrayBuffer or ArrayBufferView)'.")
                    }
                    bytes = bs
                }
                let stream = web.heap.toBoolean(try web.member(args[1], "stream"))
                var all = dec.pending + bytes
                dec.pending = []
                if stream {
                    var keep = 0
                    if dec.encoding == .utf8 { keep = jswebIncompleteUTF8Tail(all) }
                    else if dec.encoding == .utf16le || dec.encoding == .utf16be { keep = all.count % 2 }
                    if keep > 0 { dec.pending = Array(all[(all.count - keep)...]); all.removeLast(keep) }
                }
                var start = 0
                if !dec.ignoreBOM && !dec.sawStart {
                    switch dec.encoding {
                    case .utf8: if all.count >= 3 && all[0] == 0xef && all[1] == 0xbb && all[2] == 0xbf { start = 3 }
                    case .utf16le: if all.count >= 2 && all[0] == 0xff && all[1] == 0xfe { start = 2 }
                    case .utf16be: if all.count >= 2 && all[0] == 0xfe && all[1] == 0xff { start = 2 }
                    default: break
                    }
                }
                if !all.isEmpty { dec.sawStart = stream }
                if !stream { dec.sawStart = false }
                if dec.fatal && dec.encoding == .utf8 && !jswebValidUTF8(Array(all[start...])) {
                    throw web.typeError("Failed to execute 'decode' on 'TextDecoder': The encoded data was not valid for encoding utf-8")
                }
                return web.js(String(decoding: charsetDecodeToUTF8(all, dec.encoding, from: start), as: UTF8.self))
            },
        ], accessors: [
            JSHostAccessor("encoding", get: { (realm: JSRealm, d: JSWebTextDecoder) throws(JSThrow) -> JSValue in web.js(d.name) }),
            JSHostAccessor("fatal", get: { (realm: JSRealm, d: JSWebTextDecoder) throws(JSThrow) -> JSValue in .bool(d.fatal) }),
            JSHostAccessor("ignoreBOM", get: { (realm: JSRealm, d: JSWebTextDecoder) throws(JSThrow) -> JSValue in .bool(d.ignoreBOM) }),
        ])
        decoderClass.exposeConstructor(length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSWebTextDecoder in
            let label = args[0].isUndefined ? "utf-8" : try web.str(args[0])
            guard let e = charsetEncodingForLabel(label), e != .unsupported else {
                throw realm.throwRangeError("Failed to construct 'TextDecoder': The encoding label provided ('" + label + "') is invalid.")
            }
            let fatal = web.heap.toBoolean(try web.member(args[1], "fatal"))
            let ignore = web.heap.toBoolean(try web.member(args[1], "ignoreBOM"))
            return JSWebTextDecoder(e, name: jswebEncodingName(e), fatal: fatal, ignoreBOM: ignore)
        }
        setToStringTag(decoderClass.prototype, "TextDecoder")
    }
}
