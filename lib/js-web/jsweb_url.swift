// URL and URLSearchParams (URL Standard) over lib/url's parser. Setters
// rebuild the URL text and reparse (as lib/js-dom's Location does), which
// covers what pages do (pathname/search/hash edits); the full state-override
// parser is not implemented.

final class JSWebURL {
    var url: URLRecord
    init(_ u: URLRecord) { url = u }
}

final class JSWebParams {
    var list: [(String, String)] = []
    /// The URL whose query this object reflects (url.searchParams).
    var owner: JSWebURL? = nil
    init() {}

    func pull() {
        guard let o = owner else { return }
        list = jswebDecodeQuery(o.url.query ?? [])
    }

    func push() {
        guard let o = owner else { return }
        let q = jswebEncodeQuery(list)
        o.url.query = q.isEmpty ? nil : Array(q.utf8)
    }
}

func jswebDecodeQuery(_ q: [UInt8]) -> [(String, String)] {
    var b = q
    if b.first == 0x3f { b.removeFirst() }
    var out: [(String, String)] = []
    for p in urlFormDecode(b) {
        out.append((String(decoding: p.name, as: UTF8.self), String(decoding: p.value, as: UTF8.self)))
        if out.count >= 100_000 { break }
    }
    return out
}

func jswebEncodeQuery(_ list: [(String, String)]) -> String {
    var pairs: [URLFormPair] = []
    for (k, v) in list { pairs.append(URLFormPair(k, v)) }
    return String(decoding: urlFormEncode(pairs), as: UTF8.self)
}

extension JSWeb {
    func parseURL(_ s: String, base: String?) -> URLRecord? {
        if let bs = base {
            guard let bu = URLRecord.parseOrNil(bs) else { return nil }
            return URLRecord.parseOrNil(s, base: bu)
        }
        return URLRecord.parseOrNil(s)
    }

    /// Rebuild and reparse (host, hostname, port, pathname, protocol setters).
    func rebuildURL(_ u: JSWebURL, scheme: String? = nil, host: String? = nil, path: String? = nil) {
        let cur = u.url
        if cur.hasOpaquePath && (host != nil || path != nil) { return }
        var s = (scheme ?? String(decoding: cur.scheme, as: UTF8.self)) + ":"
        if cur.host != nil || host != nil {
            s += "//"
            if !cur.username.isEmpty || !cur.password.isEmpty {
                s += String(decoding: cur.username, as: UTF8.self)
                if !cur.password.isEmpty { s += ":" + String(decoding: cur.password, as: UTF8.self) }
                s += "@"
            }
            s += host ?? cur.hostWithPort
        }
        if let p = path {
            s += p.hasPrefix("/") || cur.host == nil ? p : "/" + p
        } else {
            s += cur.hasOpaquePath ? String(decoding: cur.opaquePath, as: UTF8.self) : cur.pathname
        }
        s += cur.search + cur.hash
        if let nu = URLRecord.parseOrNil(s) {
            // A protocol change may not switch between special and non-special.
            if scheme != nil && nu.isSpecial != cur.isSpecial { return }
            u.url = nu
        }
    }

    func installURL() {
        let web = self
        urlClass = JSHostClass<JSWebURL>(realm: realm, name: "URL")
        paramsClass = JSHostClass<JSWebParams>(realm: realm, name: "URLSearchParams")
        typealias A = JSHostAccessor<JSWebURL>
        func text(_ name: String, _ get: @escaping (URLRecord) -> String,
                  _ set: ((JSWeb, JSWebURL, String) throws(JSThrow) -> Void)?) -> A {
            let g = { (realm: JSRealm, u: JSWebURL) throws(JSThrow) -> JSValue in web.js(get(u.url)) }
            guard let st = set else { return A(name, get: g) }
            return A(name, get: g, set: { (realm: JSRealm, u: JSWebURL, v: JSValue) throws(JSThrow) -> Void in
                try st(web, u, try web.str(v))
            })
        }
        urlClass.define(methods: [
            JSHostMethod("toString", 0) { (realm: JSRealm, u: JSWebURL, args: JSArgs) throws(JSThrow) -> JSValue in web.js(u.url.href) },
            JSHostMethod("toJSON", 0) { (realm: JSRealm, u: JSWebURL, args: JSArgs) throws(JSThrow) -> JSValue in web.js(u.url.href) },
        ], accessors: [
            text("href", { $0.href }) { (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                guard let nu = URLRecord.parseOrNil(v) else { throw w.typeError("Failed to set the 'href' property on 'URL': Invalid URL") }
                u.url = nu
            },
            text("origin", { $0.origin }, nil),
            text("protocol", { $0.protocolString }) { (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                var s = Array(v.utf8)
                if let i = s.firstIndex(of: 0x3a) { s = Array(s[..<i]) }
                if s.isEmpty { return }
                w.rebuildURL(u, scheme: jswebLowerASCII(String(decoding: s, as: UTF8.self)))
            },
            text("username", { String(decoding: $0.username, as: UTF8.self) }) { (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                if u.url.host == nil || u.url.scheme == Array("file".utf8) { return }
                u.url.username = urlPercentEncode(Array(v.utf8), .userinfo)
            },
            text("password", { String(decoding: $0.password, as: UTF8.self) }) { (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                if u.url.host == nil || u.url.scheme == Array("file".utf8) { return }
                u.url.password = urlPercentEncode(Array(v.utf8), .userinfo)
            },
            text("host", { $0.hostWithPort }) { (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                if v.isEmpty { return }
                w.rebuildURL(u, host: v)
            },
            text("hostname", { $0.hostname }) { (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                if v.isEmpty { return }
                var h = v
                if let p = u.url.port { h += ":" + String(Int(p)) }
                w.rebuildURL(u, host: h)
            },
            text("port", { $0.portString }) { (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                if u.url.host == nil || u.url.scheme == Array("file".utf8) { return }
                if v.isEmpty { u.url.port = nil; return }
                var n = 0
                var any = false
                for c in v.utf8 {
                    if c < 0x30 || c > 0x39 { break }
                    n = n * 10 + Int(c - 0x30)
                    any = true
                    if n > 65535 { return }
                }
                if !any { return }
                let def = urlDefaultPort(u.url.scheme)
                u.url.port = def == UInt16(n) ? nil : UInt16(n)
            },
            text("pathname", { $0.hasOpaquePath ? String(decoding: $0.opaquePath, as: UTF8.self) : $0.pathname }) {
                (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                w.rebuildURL(u, path: v)
            },
            text("search", { $0.search }) { (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                var s = Array(v.utf8)
                if s.first == 0x3f { s.removeFirst() }
                u.url.query = s.isEmpty ? nil : urlPercentEncode(s, u.url.isSpecial ? .specialQuery : .query)
            },
            text("hash", { $0.hash }) { (w: JSWeb, u: JSWebURL, v: String) throws(JSThrow) -> Void in
                var s = Array(v.utf8)
                if s.first == 0x23 { s.removeFirst() }
                u.url.fragment = s.isEmpty ? nil : urlPercentEncode(s, .fragment)
            },
            A("searchParams", get: { (realm: JSRealm, u: JSWebURL) throws(JSThrow) -> JSValue in
                guard let w = web.urlClass.existingWrapper(for: u) else { return .undefined }
                let cached = web.b.hiddenSlot(w, 0)
                if cached.isObject { return cached }
                let p = JSWebParams()
                p.owner = u
                let pw = web.paramsClass.wrap(p)
                web.b.setHiddenSlot(w, 0, pw)
                return pw
            }),
        ])
        let ctor = urlClass.exposeConstructor(length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSWebURL in
            if args.count < 1 { throw web.typeError("Failed to construct 'URL': 1 argument required, but only 0 present.") }
            let s = try web.str(args[0])
            let base: String? = args[1].isUndefined ? nil : try web.str(args[1])
            guard let u = web.parseURL(s, base: base) else {
                throw web.typeError("Failed to construct 'URL': Invalid URL")
            }
            return JSWebURL(u)
        }
        realm.defineMethod(ctor, "canParse", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let s = try web.str(args[0])
            let base: String? = args[1].isUndefined ? nil : try web.str(args[1])
            return .bool(web.parseURL(s, base: base) != nil)
        }
        realm.defineMethod(ctor, "parse", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let s = try web.str(args[0])
            let base: String? = args[1].isUndefined ? nil : try web.str(args[1])
            guard let u = web.parseURL(s, base: base) else { return .null }
            return web.urlClass.wrap(JSWebURL(u))
        }
        realm.defineMethod(ctor, "createObjectURL", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            web.js("blob:" + web.origin + "/unsupported")
        }
        realm.defineMethod(ctor, "revokeObjectURL", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in .undefined }

        // URLSearchParams
        typealias M = JSHostMethod<JSWebParams>
        paramsClass.define(methods: [
            M("append", 2) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                if args.count < 2 { throw web.typeError("Failed to execute 'append' on 'URLSearchParams': 2 arguments required.") }
                p.pull()
                if p.list.count < 100_000 { p.list.append((try web.str(args[0]), try web.str(args[1]))) }
                p.push()
                return .undefined
            },
            M("delete", 1) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.str(args[0])
                let v: String? = args[1].isUndefined ? nil : try web.str(args[1])
                p.pull()
                p.list.removeAll { $0.0 == n && (v == nil || $0.1 == v!) }
                p.push()
                return .undefined
            },
            M("get", 1) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.str(args[0])
                p.pull()
                for (k, v) in p.list where k == n { return web.js(v) }
                return .null
            },
            M("getAll", 1) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.str(args[0])
                p.pull()
                let d = web.heap.rootDepth
                defer { web.heap.popRoots(to: d) }
                var vals: [JSValue] = []
                for (k, v) in p.list where k == n { let s = web.js(v); _ = web.heap.root(s); vals.append(s) }
                return web.array(vals)
            },
            M("has", 1) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.str(args[0])
                let v: String? = args[1].isUndefined ? nil : try web.str(args[1])
                p.pull()
                return .bool(p.list.contains { $0.0 == n && (v == nil || $0.1 == v!) })
            },
            M("set", 2) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                if args.count < 2 { throw web.typeError("Failed to execute 'set' on 'URLSearchParams': 2 arguments required.") }
                let n = try web.str(args[0]), v = try web.str(args[1])
                p.pull()
                if let i = p.list.firstIndex(where: { $0.0 == n }) {
                    p.list[i].1 = v
                    var j = p.list.count - 1
                    while j > i { if p.list[j].0 == n { p.list.remove(at: j) }; j -= 1 }
                } else {
                    p.list.append((n, v))
                }
                p.push()
                return .undefined
            },
            M("sort", 0) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                p.pull()
                // Stable sort by UTF-16 code units of the name.
                let keyed = p.list.enumerated().map { (Array($0.element.0.utf16), $0.offset, $0.element) }
                let sorted = keyed.sorted { a, b in
                    if a.0 != b.0 { return a.0.lexicographicallyPrecedes(b.0) }
                    return a.1 < b.1
                }
                p.list = sorted.map { $0.2 }
                p.push()
                return .undefined
            },
            M("toString", 0) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                p.pull()
                return web.js(jswebEncodeQuery(p.list))
            },
            M("forEach", 1) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                let f = args[0]
                if !web.heap.isCallable(f) { throw web.typeError("URLSearchParams.forEach: callback is not a function") }
                p.pull()
                var i = 0
                while i < p.list.count {
                    let (k, v) = p.list[i]
                    let d = web.heap.rootDepth
                    let ks = web.js(k); _ = web.heap.root(ks)
                    let vs = web.js(v); _ = web.heap.root(vs)
                    _ = try realm.call(f, this: args[1], args: [vs, ks, args.this])
                    web.heap.popRoots(to: d)
                    i += 1
                    p.pull()
                }
                return .undefined
            },
            M("entries", 0) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                p.pull()
                let l = p.list
                return try web.listIterator(l.count, kind: 2) { (i: Int) throws(JSThrow) -> (String, JSValue) in (l[i].0, web.js(l[i].1)) }
            },
            M("keys", 0) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                p.pull()
                let l = p.list
                return try web.listIterator(l.count, kind: 0) { (i: Int) throws(JSThrow) -> (String, JSValue) in (l[i].0, web.js(l[i].1)) }
            },
            M("values", 0) { (realm: JSRealm, p: JSWebParams, args: JSArgs) throws(JSThrow) -> JSValue in
                p.pull()
                let l = p.list
                return try web.listIterator(l.count, kind: 1) { (i: Int) throws(JSThrow) -> (String, JSValue) in (l[i].0, web.js(l[i].1)) }
            },
        ], accessors: [
            JSHostAccessor("size", get: { (realm: JSRealm, p: JSWebParams) throws(JSThrow) -> JSValue in
                p.pull()
                return .number(p.list.count)
            }),
        ])
        aliasIterator(paramsClass.prototype, "entries")
        setToStringTag(paramsClass.prototype, "URLSearchParams")
        setToStringTag(urlClass.prototype, "URL")
        paramsClass.exposeConstructor(length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSWebParams in
            let p = JSWebParams()
            try web.fillParams(p, args[0])
            return p
        }
    }

    /// URLSearchParams(init): a string, a sequence of pairs, or a record.
    func fillParams(_ p: JSWebParams, _ v: JSValue) throws(JSThrow) {
        if v.isUndefined || v.isNull { return }
        if v.isObject {
            if let other = paramsClass.unwrap(v) { other.pull(); p.list = other.list; return }
            let iterFn = try realm.getV(v, .symbol(heap.symbolsWellKnown.iterator.handle))
            if !iterFn.isNullish {
                let d = heap.rootDepth
                defer { heap.popRoots(to: d) }
                let (it, next) = try realm.getIterator(v)
                _ = heap.root(it); _ = heap.root(next)
                var n = 0
                while n < 100_000 {
                    let (done, pair) = try realm.iteratorStep(it, next)
                    if done { break }
                    let d2 = heap.rootDepth
                    _ = heap.root(pair)
                    if !pair.isObject { throw typeError("Failed to construct 'URLSearchParams': The provided value cannot be converted to a sequence.") }
                    let len = try realm.toLength(try get(pair, "length"))
                    if len != 2 { throw typeError("Failed to construct 'URLSearchParams': Sequence initializer must only contain pair elements") }
                    let k = try str(try realm.getV(pair, JSPropertyKey.index(0)))
                    let val = try str(try realm.getV(pair, JSPropertyKey.index(1)))
                    p.list.append((k, val))
                    heap.popRoots(to: d2)
                    n += 1
                }
                return
            }
            let d = heap.rootDepth
            defer { heap.popRoots(to: d) }
            _ = heap.root(v)
            for k in heap.ownKeys(v) {
                guard !k.isSymbol, let prop = heap.getOwnProperty(v, k), prop.enumerable else { continue }
                let val = try realm.getV(v, k)
                p.list.append((try str(heap.keyValue(k)), try str(val)))
                if p.list.count >= 100_000 { break }
            }
            return
        }
        p.list = jswebDecodeQuery(Array(try str(v).utf8))
    }
}
