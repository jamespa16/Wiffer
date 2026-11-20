// Fetch Standard, the parts pages use: Headers, Request, Response (bodies
// are whole byte arrays: text / json / arrayBuffer / bytes / blob /
// formData; `body` streams are not implemented and read as null), fetch()
// with AbortSignal, and the CORS protocol (same-origin policy, Origin,
// preflight for non-simple requests, Access-Control-Allow-Origin /
// -Credentials / -Methods / -Headers / -Expose-Headers). Blob and FormData
// live here too (bodies).

final class JSWebBlob {
    var bytes: [UInt8]
    var type: String
    /// A File: its name and lastModified.
    var name: String? = nil
    var lastModified = 0.0
    init(_ b: [UInt8], type: String) { bytes = b; self.type = type }
}

struct JSWebFormEntry {
    var name: String
    var value: String
    var file: JSWebBlob? = nil
}

final class JSWebFormData {
    var entries: [JSWebFormEntry] = []
    init() {}
}

final class JSWebHeaders {
    /// Lowercased names, in insertion order.
    var list: [(name: String, value: String)] = []
    /// 0 none, 1 request, 2 request-no-cors, 3 response, 4 immutable.
    var guardKind = 0
    init(_ g: Int = 0) { guardKind = g }

    func get(_ n: String) -> String? {
        var out: String? = nil
        for h in list where h.name == n { out = out.map { $0 + ", " + h.value } ?? h.value }
        return out
    }
    func has(_ n: String) -> Bool { list.contains { $0.name == n } }
    func remove(_ n: String) { list.removeAll { $0.name == n } }
    func set(_ n: String, _ v: String) {
        if let i = list.firstIndex(where: { $0.name == n }) {
            list[i].value = v
            var j = list.count - 1
            while j > i { if list[j].name == n { list.remove(at: j) }; j -= 1 }
        } else {
            list.append((name: n, value: v))
        }
    }
    /// Sorted and combined, set-cookie kept separate (the iteration order).
    func sortedCombined() -> [(String, String)] {
        var names: [String] = []
        for h in list where !names.contains(h.name) { names.append(h.name) }
        names.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var out: [(String, String)] = []
        for n in names {
            if n == "set-cookie" { for h in list where h.name == n { out.append((n, h.value)) } }
            else if let v = get(n) { out.append((n, v)) }
        }
        return out
    }
}

/// A Request's or Response's body.
final class JSWebBody {
    var bytes: [UInt8]?
    var used = false
    init(_ b: [UInt8]?) { bytes = b }
}

final class JSWebRequestObject {
    var method = "GET"
    var url: URLRecord
    let headers: JSWebHeaders
    var body: JSWebBody
    var mode = "cors"
    var credentials = "same-origin"
    var cache = "default"
    var redirect = "follow"
    var referrer = "about:client"
    var integrity = ""
    var keepalive = false
    var signal: JSDOMEventTargetObject
    init(url: URLRecord, headers: JSWebHeaders, body: JSWebBody, signal: JSDOMEventTargetObject) {
        self.url = url; self.headers = headers; self.body = body; self.signal = signal
    }
}

final class JSWebResponseObject {
    var type = "default"
    var url: URLRecord? = nil
    var status = 200
    var statusText = ""
    var redirected = false
    let headers: JSWebHeaders
    var body: JSWebBody
    init(headers: JSWebHeaders, body: JSWebBody) { self.headers = headers; self.body = body }
}

/// What the CORS layer hands to fetch / XHR.
enum JSWebFetchOutcome {
    case response(JSWebResponse, type: String)
    case networkError(String)
}

/// The request as fetch()/XHR hand it to the CORS layer.
struct JSWebFetchParams {
    var method = "GET"
    var url: URLRecord
    var headers: [(name: String, value: String)] = []
    var body: [UInt8]? = nil
    var mode = "cors"
    var credentials = "same-origin"
    var reload = false
    /// "fetch" or "XMLHttpRequest" (console messages).
    var api = "fetch"
    init(url: URLRecord) { self.url = url }
}

/// One in-flight network exchange (the GC roots it holds: a promise, a wrapper).
final class JSWebJob {
    let id: Int
    var netID = 0
    var keep: [JSValue] = []
    var finished = false
    var aborted = false
    init(id: Int) { self.id = id }
    func mark(_ h: JSHeap) { for v in keep { h.markValue(v) } }
}

// MARK: CORS tables

func jswebIsSimpleMethod(_ m: String) -> Bool { m == "GET" || m == "HEAD" || m == "POST" }

func jswebIsForbiddenMethod(_ m: String) -> Bool {
    let u = jswebLowerASCII(m)
    return u == "connect" || u == "trace" || u == "track"
}

/// Normalize: the six methods are uppercased, others kept.
func jswebNormalizeMethod(_ m: String) -> String {
    let u = jswebLowerASCII(m)
    for k in ["delete", "get", "head", "options", "post", "put"] where u == k {
        return String(decoding: Array(k.utf8).map { $0 - 32 }, as: UTF8.self)
    }
    return m
}

func jswebIsForbiddenRequestHeader(_ n: String) -> Bool {
    let l = jswebLowerASCII(n)
    switch l {
    case "accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
         "connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive",
         "origin", "referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "via":
        return true
    default:
        return l.hasPrefix("proxy-") || l.hasPrefix("sec-")
    }
}

func jswebIsSafelistedRequestHeader(_ n: String, _ v: String) -> Bool {
    if v.utf8.count > 128 { return false }
    switch jswebLowerASCII(n) {
    case "accept", "accept-language", "content-language":
        for c in v.utf8 where c == 0x22 || c == 0x28 || c == 0x29 || c == 0x3a || c == 0x3c || c == 0x3e || c == 0x3f
            || c == 0x40 || c == 0x5b || c == 0x5c || c == 0x5d || c == 0x7b || c == 0x7d || c == 0x7f || (c < 0x20 && c != 0x09) {
            return false
        }
        return true
    case "content-type":
        let e = jswebMIMEEssence(v)
        return e == "application/x-www-form-urlencoded" || e == "multipart/form-data" || e == "text/plain"
    default:
        return false
    }
}

func jswebIsSafelistedResponseHeader(_ n: String) -> Bool {
    switch n {
    case "cache-control", "content-language", "content-length", "content-type", "expires", "last-modified", "pragma":
        return true
    default:
        return false
    }
}

/// A comma-separated header value as lowercased trimmed items.
func jswebHeaderList(_ v: String?) -> [String] {
    guard let v = v else { return [] }
    var out: [String] = []
    for part in v.split(separator: ",") {
        let t = jswebTrimHTTPSpace(String(part))
        if !t.isEmpty { out.append(t) }
    }
    return out
}

/// The CORS check: does `r` allow `origin` (with or without credentials)?
func jswebCORSAllows(_ r: JSWebResponse, origin: String, credentials: Bool) -> Bool {
    guard let acao = r.header("Access-Control-Allow-Origin").map({ jswebTrimHTTPSpace($0) }) else { return false }
    if acao == "*" { return !credentials }
    if acao != origin { return false }
    if !credentials { return true }
    return r.header("Access-Control-Allow-Credentials").map { jswebTrimHTTPSpace($0) } == "true"
}

func jswebSameOrigin(_ a: URLRecord?, _ b: URLRecord) -> Bool {
    guard let a = a else { return false }
    let file = Array("file".utf8)
    if a.scheme == file && b.scheme == file { return true }
    if a.origin == "null" { return false }
    return a.sameOrigin(as: b)
}

extension JSWeb {
    // MARK: The CORS layer (shared by fetch and XHR)

    func consoleError(_ s: String) { b.host.console(.error, s) }

    /// Send `p` with the same-origin policy and CORS; `done` runs as a task.
    func corsFetch(_ p: JSWebFetchParams, job: JSWebJob, _ done: @escaping (JSWebFetchOutcome) -> Void) {
        let pageURL = b.url
        let org = origin
        let same = jswebSameOrigin(pageURL, p.url)
        let scheme = String(decoding: p.url.scheme, as: UTF8.self)
        if scheme == "data" { done(dataURLFetch(p)); return }
        if !same && p.mode == "same-origin" {
            consoleError(p.api + " " + p.url.href + ": cross-origin request blocked (mode: same-origin)")
            done(.networkError("same-origin mode"))
            return
        }
        if !same && scheme != "http" && scheme != "https" {
            consoleError(p.api + " " + p.url.href + ": cross-origin requests are only supported for HTTP(S)")
            done(.networkError("unsupported scheme"))
            return
        }
        var req = JSWebRequest(url: p.url)
        req.method = p.method
        req.headers = p.headers
        req.body = p.body ?? []
        req.reload = p.reload
        let include = p.credentials == "include"
        req.credentials = p.credentials != "omit" && (same || include)
        if same {
            send(req, job: job) { r in
                switch r {
                case .failure(let m): done(.networkError(m))
                case .response(let resp):
                    if jswebSameOrigin(pageURL, resp.url) { done(.response(resp, type: "basic")); return }
                    // Redirected to another origin: it must allow us.
                    if jswebCORSAllows(resp, origin: org, credentials: req.credentials) { done(.response(self.corsFiltered(resp), type: "cors")); return }
                    self.blocked(p, why: "No 'Access-Control-Allow-Origin' header is present on the requested resource (after a redirect).")
                    done(.networkError("CORS"))
                }
            }
            return
        }
        if p.mode == "no-cors" {
            if !jswebIsSimpleMethod(p.method) { done(.networkError("no-cors with a non-simple method")); return }
            send(req, job: job) { r in
                switch r {
                case .failure(let m): done(.networkError(m))
                case .response(let resp):
                    var o = JSWebResponse(url: resp.url)
                    o.status = 0
                    done(.response(o, type: "opaque"))
                }
            }
            return
        }
        // CORS.
        req.headers.append((name: "Origin", value: org))
        var unsafeNames: [String] = []
        for h in p.headers where !jswebIsSafelistedRequestHeader(h.name, h.value) {
            let l = jswebLowerASCII(h.name)
            if !unsafeNames.contains(l) { unsafeNames.append(l) }
        }
        unsafeNames.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let actual: () -> Void = { [unowned(unsafe) self] in
            self.send(req, job: job) { r in
                switch r {
                case .failure(let m):
                    self.blocked(p, why: "the request failed (" + m + ").")
                    done(.networkError(m))
                case .response(let resp):
                    if jswebCORSAllows(resp, origin: org, credentials: req.credentials) {
                        done(.response(self.corsFiltered(resp), type: "cors"))
                    } else {
                        let why = resp.header("Access-Control-Allow-Origin") == nil
                            ? "No 'Access-Control-Allow-Origin' header is present on the requested resource."
                            : "The 'Access-Control-Allow-Origin' header does not allow origin '" + org + "'."
                        self.blocked(p, why: why)
                        done(.networkError("CORS"))
                    }
                }
            }
        }
        if jswebIsSimpleMethod(p.method) && unsafeNames.isEmpty { actual(); return }
        var pre = JSWebRequest(url: p.url)
        pre.method = "OPTIONS"
        pre.credentials = false
        pre.preflight = true
        pre.reload = true
        pre.headers = [(name: "Origin", value: org), (name: "Access-Control-Request-Method", value: p.method)]
        if !unsafeNames.isEmpty {
            var s = ""
            for (i, n) in unsafeNames.enumerated() { s += (i > 0 ? "," : "") + n }
            pre.headers.append((name: "Access-Control-Request-Headers", value: s))
        }
        send(pre, job: job) { r in
            if job.aborted { return }
            switch r {
            case .failure(let m):
                self.blocked(p, why: "the preflight request failed (" + m + ").")
                done(.networkError(m))
            case .response(let resp):
                guard resp.status >= 200 && resp.status < 300 && jswebCORSAllows(resp, origin: org, credentials: req.credentials) else {
                    self.blocked(p, why: "Response to preflight request doesn't pass access control check.")
                    done(.networkError("CORS preflight"))
                    return
                }
                let methods = jswebHeaderList(resp.header("Access-Control-Allow-Methods"))
                let star = !req.credentials
                if !jswebIsSimpleMethod(p.method) && !methods.contains(p.method) && !(star && methods.contains("*")) {
                    self.blocked(p, why: "Method " + p.method + " is not allowed by Access-Control-Allow-Methods in preflight response.")
                    done(.networkError("CORS preflight"))
                    return
                }
                let allowed = jswebHeaderList(resp.header("Access-Control-Allow-Headers")).map { jswebLowerASCII($0) }
                for n in unsafeNames where !allowed.contains(n) && !(star && allowed.contains("*")) {
                    self.blocked(p, why: "Request header field " + n + " is not allowed by Access-Control-Allow-Headers in preflight response.")
                    done(.networkError("CORS preflight"))
                    return
                }
                actual()
            }
        }
    }

    func blocked(_ p: JSWebFetchParams, why: String) {
        consoleError("Access to " + p.api + " at '" + p.url.href + "' from origin '" + origin + "' has been blocked by CORS policy: " + why)
    }

    /// Only the CORS-safelisted response headers plus Access-Control-Expose-Headers.
    func corsFiltered(_ r: JSWebResponse) -> JSWebResponse {
        var o = r
        let expose = jswebHeaderList(r.header("Access-Control-Expose-Headers")).map { jswebLowerASCII($0) }
        o.headers = r.headers.filter { h in
            let l = jswebLowerASCII(h.name)
            return jswebIsSafelistedResponseHeader(l) || expose.contains(l) || (expose.contains("*") && l != "set-cookie")
        }
        return o
    }

    /// Hand a request to the network; the completion runs as a page task.
    func send(_ req: JSWebRequest, job: JSWebJob, _ done: @escaping (JSWebNetResult) -> Void) {
        if tornDown || job.aborted { return }
        network.started += 1
        var delivered = false
        job.netID = network.start(req) { [unowned(unsafe) self] r in
            if delivered { return }
            delivered = true
            self.queue {
                job.netID = 0
                if job.aborted || self.tornDown { return }
                done(r)
            }
        }
    }

    /// data: URLs (base64 or percent-encoded), answered locally.
    func dataURLFetch(_ p: JSWebFetchParams) -> JSWebFetchOutcome {
        var rest = Array(p.url.serializedBytes(excludeFragment: true).dropFirst(5))
        guard let comma = rest.firstIndex(of: 0x2c) else { return .networkError("bad data: URL") }
        var meta = String(decoding: rest[..<comma], as: UTF8.self)
        rest = Array(rest[(comma + 1)...])
        var base64 = false
        if jswebLowerASCII(meta).hasSuffix(";base64") { base64 = true; meta = String(meta.dropLast(7)) }
        var body = urlPercentDecode(rest)
        if base64 {
            guard let d = jswebBase64Decode(body) else { return .networkError("bad base64 in data: URL") }
            body = d
        }
        var r = JSWebResponse(url: p.url)
        r.statusText = "OK"
        r.headers = [(name: "Content-Type", value: meta.isEmpty ? "text/plain;charset=US-ASCII" : meta)]
        r.body = body
        return .response(r, type: "basic")
    }

    // MARK: Bodies

    /// BodyInit -> (bytes, content type); nil for null/undefined.
    func extractBody(_ v: JSValue) throws(JSThrow) -> (bytes: [UInt8], type: String?)? {
        if v.isNullish { return nil }
        if v.isObject {
            if let p = paramsClass.unwrap(v) {
                p.pull()
                return (Array(jswebEncodeQuery(p.list).utf8), "application/x-www-form-urlencoded;charset=UTF-8")
            }
            if let blob = blobClass.unwrap(v) { return (blob.bytes, blob.type.isEmpty ? nil : blob.type) }
            if let fd = formDataClass.unwrap(v) {
                let (bytes, boundary) = multipartEncode(fd)
                return (bytes, "multipart/form-data; boundary=" + boundary)
            }
            if let bytes = bufferSourceBytes(v) { return (bytes, nil) }
        }
        return (Array(try str(v).utf8), "text/plain;charset=UTF-8")
    }

    func multipartEncode(_ fd: JSWebFormData) -> ([UInt8], String) {
        nextJob += 1
        let boundary = "----WifferFormBoundary" + String(nextJob * 7919 + fd.entries.count)
        var out: [UInt8] = []
        func esc(_ s: String) -> String {
            var r = ""
            for u in s.unicodeScalars {
                if u == "\"" { r += "%22" } else if u == "\r" { r += "%0D" } else if u == "\n" { r += "%0A" } else { r.unicodeScalars.append(u) }
            }
            return r
        }
        for e in fd.entries {
            out += Array(("--" + boundary + "\r\n").utf8)
            if let f = e.file {
                out += Array(("Content-Disposition: form-data; name=\"" + esc(e.name) + "\"; filename=\"" + esc(f.name ?? "blob") + "\"\r\n").utf8)
                out += Array(("Content-Type: " + (f.type.isEmpty ? "application/octet-stream" : f.type) + "\r\n\r\n").utf8)
                out += f.bytes
            } else {
                out += Array(("Content-Disposition: form-data; name=\"" + esc(e.name) + "\"\r\n\r\n").utf8)
                out += Array(e.value.utf8)
            }
            out += [0x0d, 0x0a]
        }
        out += Array(("--" + boundary + "--\r\n").utf8)
        return (out, boundary)
    }

    /// A promise already settled with `f()` (or rejected with what it threw).
    func settled(_ f: () throws(JSThrow) -> JSValue) throws(JSThrow) -> JSValue {
        let p = realm.newPromise()
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(p)
        do throws(JSThrow) {
            let v = try f()
            _ = heap.root(v)
            try realm.resolvePromise(p, v)
        } catch {
            if realm.isTerminating { throw error }
            realm.rejectPromise(p, realm.takeException())
        }
        return p
    }

    func rejected(_ reason: JSValue) -> JSValue {
        let d = heap.rootDepth
        _ = heap.root(reason)
        let p = realm.newPromise()
        _ = heap.root(p)
        realm.rejectPromise(p, reason)
        heap.popRoots(to: d)
        return p
    }

    func jsonParse(_ text: String) throws(JSThrow) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let json = try get(realm.global, "JSON")
        _ = heap.root(json)
        let parse = try get(json, "parse")
        _ = heap.root(parse)
        let s = js(text)
        _ = heap.root(s)
        return try realm.call(parse, this: json, args: [s])
    }

    /// Consume a body (text / json / arrayBuffer / bytes / blob / formData).
    func consume(_ body: JSWebBody, _ how: String, type: String) throws(JSThrow) -> JSValue {
        if body.used {
            let e = realm.makeError(.typeError, "Failed to execute '" + how + "': body stream already read")
            return rejected(e)
        }
        body.used = body.bytes != nil
        let bytes = body.bytes ?? []
        let web = self
        return try settled { () throws(JSThrow) -> JSValue in
            switch how {
            case "text": return web.js(jswebDecodeText(bytes))
            case "json": return try web.jsonParse(jswebDecodeText(bytes))
            case "arrayBuffer": return try web.realm.newArrayBuffer(bytes: bytes)
            case "bytes": return try web.uint8Array(bytes)
            case "blob": return web.blobClass.wrap(JSWebBlob(bytes, type: jswebLowerASCII(type)))
            default:
                let fd = JSWebFormData()
                if jswebMIMEEssence(type) == "application/x-www-form-urlencoded" {
                    for (k, v) in jswebDecodeQuery(bytes) { fd.entries.append(JSWebFormEntry(name: k, value: v)) }
                } else if jswebMIMEEssence(type) != "multipart/form-data" {
                    throw web.typeError("Failed to execute 'formData': invalid MIME type")
                }
                return web.formDataClass.wrap(fd)
            }
        }
    }

    // MARK: Headers

    func headerName(_ v: JSValue) throws(JSThrow) -> String {
        let n = try str(v)
        if !jswebIsToken(n) { throw typeError("Failed to execute on 'Headers': Invalid name '" + n + "'") }
        return jswebLowerASCII(n)
    }

    func headerValue(_ v: JSValue) throws(JSThrow) -> String {
        let s = jswebTrimHTTPSpace(try str(v))
        if !jswebIsHeaderValue(s) { throw typeError("Failed to execute on 'Headers': Invalid value") }
        return s
    }

    /// Append with the guard's rules (forbidden names are ignored).
    func headersAppend(_ h: JSWebHeaders, _ n: String, _ v: String) throws(JSThrow) {
        if h.guardKind == 4 { throw typeError("Headers are immutable") }
        if h.guardKind == 1 && jswebIsForbiddenRequestHeader(n) { return }
        if h.guardKind == 3 && (n == "set-cookie" || n == "set-cookie2") { return }
        if h.guardKind == 2 && !jswebIsSafelistedRequestHeader(n, v) { return }
        if h.list.count < 1000 { h.list.append((name: n, value: v)) }
    }

    /// HeadersInit: Headers, sequence of pairs, or a record.
    func fillHeaders(_ h: JSWebHeaders, _ v: JSValue) throws(JSThrow) {
        if v.isUndefined { return }
        if !v.isObject { throw typeError("Failed to construct 'Headers': The provided value is not of type '(record<ByteString, ByteString> or sequence<sequence<ByteString>>)'.") }
        if let other = headersClass.unwrap(v) {
            for x in other.list { try headersAppend(h, x.name, x.value) }
            return
        }
        let iterFn = try realm.getV(v, .symbol(heap.symbolsWellKnown.iterator.handle))
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(v)
        if !iterFn.isNullish {
            let (it, next) = try realm.getIterator(v)
            _ = heap.root(it); _ = heap.root(next)
            var n = 0
            while n < 1000 {
                let (done, pair) = try realm.iteratorStep(it, next)
                if done { break }
                let d2 = heap.rootDepth
                _ = heap.root(pair)
                if !pair.isObject { throw typeError("Failed to construct 'Headers': The provided value cannot be converted to a sequence.") }
                let len = try realm.toLength(try get(pair, "length"))
                if len != 2 { throw typeError("Failed to construct 'Headers': Invalid value") }
                let k = try headerName(try realm.getV(pair, JSPropertyKey.index(0)))
                let val = try headerValue(try realm.getV(pair, JSPropertyKey.index(1)))
                try headersAppend(h, k, val)
                heap.popRoots(to: d2)
                n += 1
            }
            return
        }
        for k in heap.ownKeys(v) {
            guard !k.isSymbol, let prop = heap.getOwnProperty(v, k), prop.enumerable else { continue }
            let val = try realm.getV(v, k)
            try headersAppend(h, try headerName(heap.keyValue(k)), try headerValue(val))
        }
    }

    // MARK: Request construction (new Request / fetch)

    func makeRequest(_ input: JSValue, _ initV: JSValue) throws(JSThrow) -> JSWebRequestObject {
        var url: URLRecord
        var method = "GET"
        let headers = JSWebHeaders(1)
        var bodyBytes: [UInt8]? = nil
        var bodyType: String? = nil
        var mode = "cors", credentials = "same-origin", cache = "default", redirect = "follow", referrer = "about:client"
        var signal: JSDOMEventTargetObject? = nil
        if let r = requestClass.unwrap(input) {
            url = r.url
            method = r.method
            headers.list = r.headers.list
            if r.body.used { throw typeError("Failed to construct 'Request': Cannot construct a Request with a Request object that has already been used.") }
            bodyBytes = r.body.bytes
            mode = r.mode; credentials = r.credentials; cache = r.cache; redirect = r.redirect; referrer = r.referrer
            signal = r.signal
        } else {
            let s = try str(input)
            guard let resolved = b.resolveURL(s), let u = URLRecord.parseOrNil(resolved) else {
                throw typeError("Failed to construct 'Request': Invalid URL '" + s + "'")
            }
            if !u.username.isEmpty || !u.password.isEmpty {
                throw typeError("Failed to construct 'Request': Request cannot be constructed from a URL that includes credentials")
            }
            url = u
        }
        url.fragment = nil
        if initV.isObject {
            let m = try get(initV, "method")
            if !m.isUndefined {
                let ms = try str(m)
                if !jswebIsToken(ms) { throw typeError("Failed to construct 'Request': '" + ms + "' is not a valid HTTP method.") }
                if jswebIsForbiddenMethod(ms) { throw typeError("Failed to construct 'Request': '" + ms + "' HTTP method is unsupported.") }
                method = jswebNormalizeMethod(ms)
            }
            func enumMember(_ name: String, _ allowed: [String], _ cur: String) throws(JSThrow) -> String {
                let v = try get(initV, name)
                if v.isUndefined { return cur }
                let s = try str(v)
                if !allowed.contains(s) { throw typeError("Failed to construct 'Request': The provided value '" + s + "' is not a valid enum value of type Request" + name + ".") }
                return s
            }
            mode = try enumMember("mode", ["cors", "no-cors", "same-origin", "navigate"], mode)
            if mode == "navigate" { throw typeError("Failed to construct 'Request': Cannot construct a Request with a RequestInit whose mode member is set as 'navigate'.") }
            credentials = try enumMember("credentials", ["omit", "same-origin", "include"], credentials)
            cache = try enumMember("cache", ["default", "no-store", "reload", "no-cache", "force-cache", "only-if-cached"], cache)
            redirect = try enumMember("redirect", ["follow", "error", "manual"], redirect)
            let ref = try get(initV, "referrer")
            if !ref.isUndefined { referrer = try str(ref) }
            let sig = try get(initV, "signal")
            if !sig.isUndefined {
                if sig.isNull { signal = nil }
                else if let so = b.classes.EventTargetObject.unwrap(sig), so.iface == .AbortSignal { signal = so }
                else { throw typeError("Failed to construct 'Request': member signal is not of type AbortSignal.") }
            }
            let hv = try get(initV, "headers")
            if !hv.isUndefined {
                headers.list = []
                try fillHeaders(headers, hv)
            }
            let bv = try get(initV, "body")
            if !bv.isUndefined {
                if let (bytes, t) = try extractBody(bv) {
                    bodyBytes = bytes
                    bodyType = t
                } else {
                    bodyBytes = nil
                }
            }
        }
        if mode == "no-cors" {
            if !jswebIsSimpleMethod(method) { throw typeError("Failed to construct 'Request': '" + method + "' is unsupported in no-cors mode.") }
            headers.guardKind = 2
            headers.list = headers.list.filter { jswebIsSafelistedRequestHeader($0.name, $0.value) }
        }
        if bodyBytes != nil && (method == "GET" || method == "HEAD") {
            throw typeError("Failed to construct 'Request': Request with GET/HEAD method cannot have body.")
        }
        if let t = bodyType, !headers.has("content-type") { headers.list.append((name: "content-type", value: t)) }
        let sigObj = JSDOMEventTargetObject(.AbortSignal)
        if let s = signal {
            // Follow the given signal (the request's own signal mirrors it).
            if s.aborted { sigObj.aborted = true }
            else {
                s.abortAlgorithms.append { [unowned(unsafe) self] in
                    self.b.signalAbort(sigObj, self.b.AbortSignal_reason(s))
                }
            }
        }
        let r = JSWebRequestObject(url: url, headers: headers, body: JSWebBody(bodyBytes), signal: signal ?? sigObj)
        r.method = method
        r.mode = mode; r.credentials = credentials; r.cache = cache; r.redirect = redirect; r.referrer = referrer
        return r
    }

    func makeResponse(_ r: JSWebResponse, type: String, requestURL: URLRecord) -> JSWebResponseObject {
        let h = JSWebHeaders(4)
        for x in r.headers { h.list.append((name: jswebLowerASCII(x.name), value: x.value)) }
        let o = JSWebResponseObject(headers: h, body: JSWebBody(type == "opaque" ? nil : r.body))
        o.type = type
        o.url = type == "opaque" ? nil : r.url
        o.status = r.status
        o.statusText = type == "opaque" ? "" : r.statusText
        o.redirected = r.url.href != requestURL.href
        return o
    }

    // MARK: Install

    func installFetch() {
        let web = self
        headersClass = JSHostClass<JSWebHeaders>(realm: realm, name: "Headers")
        typealias HM = JSHostMethod<JSWebHeaders>
        headersClass.define(methods: [
            HM("append", 2) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                try web.headersAppend(h, try web.headerName(args[0]), try web.headerValue(args[1]))
                return .undefined
            },
            HM("delete", 1) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.headerName(args[0])
                if h.guardKind == 4 { throw web.typeError("Headers are immutable") }
                if h.guardKind == 1 && jswebIsForbiddenRequestHeader(n) { return .undefined }
                h.remove(n)
                return .undefined
            },
            HM("get", 1) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                web.b.strOrNull(h.get(try web.headerName(args[0])))
            },
            HM("getSetCookie", 0) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                web.stringArray(h.list.filter { $0.name == "set-cookie" }.map { $0.value })
            },
            HM("has", 1) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                .bool(h.has(try web.headerName(args[0])))
            },
            HM("set", 2) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.headerName(args[0]), v = try web.headerValue(args[1])
                if h.guardKind == 4 { throw web.typeError("Headers are immutable") }
                if h.guardKind == 1 && jswebIsForbiddenRequestHeader(n) { return .undefined }
                if h.guardKind == 3 && n == "set-cookie" { return .undefined }
                h.set(n, v)
                return .undefined
            },
            HM("forEach", 1) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                let f = args[0]
                if !web.heap.isCallable(f) { throw web.typeError("Headers.forEach: callback is not a function") }
                for (k, v) in h.sortedCombined() {
                    let d = web.heap.rootDepth
                    let ks = web.js(k); _ = web.heap.root(ks)
                    let vs = web.js(v); _ = web.heap.root(vs)
                    _ = try realm.call(f, this: args[1], args: [vs, ks, args.this])
                    web.heap.popRoots(to: d)
                }
                return .undefined
            },
            HM("entries", 0) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                let l = h.sortedCombined()
                return try web.listIterator(l.count, kind: 2) { (i: Int) throws(JSThrow) -> (String, JSValue) in (l[i].0, web.js(l[i].1)) }
            },
            HM("keys", 0) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                let l = h.sortedCombined()
                return try web.listIterator(l.count, kind: 0) { (i: Int) throws(JSThrow) -> (String, JSValue) in (l[i].0, .undefined) }
            },
            HM("values", 0) { (realm: JSRealm, h: JSWebHeaders, args: JSArgs) throws(JSThrow) -> JSValue in
                let l = h.sortedCombined()
                return try web.listIterator(l.count, kind: 1) { (i: Int) throws(JSThrow) -> (String, JSValue) in (l[i].0, web.js(l[i].1)) }
            },
        ])
        aliasIterator(headersClass.prototype, "entries")
        setToStringTag(headersClass.prototype, "Headers")
        headersClass.exposeConstructor(length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSWebHeaders in
            let h = JSWebHeaders(0)
            try web.fillHeaders(h, args[0])
            return h
        }

        // Body mixin members, shared by Request and Response.
        func bodyMethods<T: AnyObject>(_ body: @escaping (T) -> JSWebBody, _ type: @escaping (T) -> String) -> [JSHostMethod<T>] {
            var out: [JSHostMethod<T>] = []
            for how in ["text", "json", "arrayBuffer", "bytes", "blob", "formData"] {
                out.append(JSHostMethod<T>(how, 0) { (realm: JSRealm, o: T, args: JSArgs) throws(JSThrow) -> JSValue in
                    try web.consume(body(o), how, type: type(o))
                })
            }
            return out
        }

        requestClass = JSHostClass<JSWebRequestObject>(realm: realm, name: "Request")
        typealias RA = JSHostAccessor<JSWebRequestObject>
        func rs(_ n: String, _ g: @escaping (JSWebRequestObject) -> String) -> RA {
            RA(n, get: { (realm: JSRealm, r: JSWebRequestObject) throws(JSThrow) -> JSValue in web.js(g(r)) })
        }
        requestClass.define(methods: bodyMethods({ $0.body }, { $0.headers.get("content-type") ?? "" }) + [
            JSHostMethod("clone", 0) { (realm: JSRealm, r: JSWebRequestObject, args: JSArgs) throws(JSThrow) -> JSValue in
                if r.body.used { throw web.typeError("Failed to execute 'clone' on 'Request': Request body is already used") }
                let h = JSWebHeaders(r.headers.guardKind)
                h.list = r.headers.list
                let c = JSWebRequestObject(url: r.url, headers: h, body: JSWebBody(r.body.bytes), signal: r.signal)
                c.method = r.method; c.mode = r.mode; c.credentials = r.credentials; c.cache = r.cache
                c.redirect = r.redirect; c.referrer = r.referrer
                return web.requestClass.wrap(c)
            },
        ], accessors: [
            rs("method") { $0.method }, rs("url") { $0.url.href }, rs("mode") { $0.mode }, rs("credentials") { $0.credentials },
            rs("cache") { $0.cache }, rs("redirect") { $0.redirect }, rs("integrity") { $0.integrity },
            rs("destination") { _ in "" }, rs("referrerPolicy") { _ in "" },
            rs("referrer") { $0.referrer == "about:client" ? "about:client" : $0.referrer },
            RA("headers", get: { (realm: JSRealm, r: JSWebRequestObject) throws(JSThrow) -> JSValue in web.headersClass.wrap(r.headers) }),
            RA("signal", get: { (realm: JSRealm, r: JSWebRequestObject) throws(JSThrow) -> JSValue in web.b.classes.EventTargetObject.wrap(r.signal) }),
            RA("bodyUsed", get: { (realm: JSRealm, r: JSWebRequestObject) throws(JSThrow) -> JSValue in .bool(r.body.used) }),
            RA("body", get: { (realm: JSRealm, r: JSWebRequestObject) throws(JSThrow) -> JSValue in .null }),
            RA("keepalive", get: { (realm: JSRealm, r: JSWebRequestObject) throws(JSThrow) -> JSValue in .bool(r.keepalive) }),
        ])
        setToStringTag(requestClass.prototype, "Request")
        requestClass.exposeConstructor(length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSWebRequestObject in
            if args.count < 1 { throw web.typeError("Failed to construct 'Request': 1 argument required, but only 0 present.") }
            return try web.makeRequest(args[0], args[1])
        }

        responseClass = JSHostClass<JSWebResponseObject>(realm: realm, name: "Response")
        typealias PA = JSHostAccessor<JSWebResponseObject>
        responseClass.define(methods: bodyMethods({ $0.body }, { $0.headers.get("content-type") ?? "" }) + [
            JSHostMethod("clone", 0) { (realm: JSRealm, r: JSWebResponseObject, args: JSArgs) throws(JSThrow) -> JSValue in
                if r.body.used { throw web.typeError("Failed to execute 'clone' on 'Response': Response body is already used") }
                let h = JSWebHeaders(r.headers.guardKind)
                h.list = r.headers.list
                let c = JSWebResponseObject(headers: h, body: JSWebBody(r.body.bytes))
                c.type = r.type; c.url = r.url; c.status = r.status; c.statusText = r.statusText; c.redirected = r.redirected
                return web.responseClass.wrap(c)
            },
        ], accessors: [
            PA("type", get: { (realm: JSRealm, r: JSWebResponseObject) throws(JSThrow) -> JSValue in web.js(r.type) }),
            PA("url", get: { (realm: JSRealm, r: JSWebResponseObject) throws(JSThrow) -> JSValue in web.js(r.url?.href ?? "") }),
            PA("status", get: { (realm: JSRealm, r: JSWebResponseObject) throws(JSThrow) -> JSValue in .number(r.status) }),
            PA("ok", get: { (realm: JSRealm, r: JSWebResponseObject) throws(JSThrow) -> JSValue in .bool(r.status >= 200 && r.status < 300) }),
            PA("statusText", get: { (realm: JSRealm, r: JSWebResponseObject) throws(JSThrow) -> JSValue in web.js(r.statusText) }),
            PA("redirected", get: { (realm: JSRealm, r: JSWebResponseObject) throws(JSThrow) -> JSValue in .bool(r.redirected) }),
            PA("headers", get: { (realm: JSRealm, r: JSWebResponseObject) throws(JSThrow) -> JSValue in web.headersClass.wrap(r.headers) }),
            PA("bodyUsed", get: { (realm: JSRealm, r: JSWebResponseObject) throws(JSThrow) -> JSValue in .bool(r.body.used) }),
            PA("body", get: { (realm: JSRealm, r: JSWebResponseObject) throws(JSThrow) -> JSValue in .null }),
        ])
        setToStringTag(responseClass.prototype, "Response")
        let rctor = responseClass.exposeConstructor(length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSWebResponseObject in
            try web.makeResponseFromInit(args[0], args[1])
        }
        realm.defineMethod(rctor, "error", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let o = JSWebResponseObject(headers: JSWebHeaders(4), body: JSWebBody(nil))
            o.type = "error"
            o.status = 0
            return web.responseClass.wrap(o)
        }
        realm.defineMethod(rctor, "redirect", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let s = try web.str(args[0])
            guard let resolved = web.b.resolveURL(s) else { throw web.typeError("Failed to execute 'redirect' on 'Response': Invalid URL") }
            let status = args[1].isUndefined ? 302 : Int(try realm.toNumber(args[1]))
            if ![301, 302, 303, 307, 308].contains(status) { throw realm.throwRangeError("Failed to execute 'redirect' on 'Response': Invalid status code") }
            let o = JSWebResponseObject(headers: JSWebHeaders(4), body: JSWebBody(nil))
            o.status = status
            o.headers.list = [(name: "location", value: resolved)]
            return web.responseClass.wrap(o)
        }
        realm.defineMethod(rctor, "json", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let d = web.heap.rootDepth
            defer { web.heap.popRoots(to: d) }
            let json = try web.get(realm.global, "JSON")
            _ = web.heap.root(json)
            let f = try web.get(json, "stringify")
            let s = try realm.call(f, this: json, args: [args[0]])
            if s.isUndefined { throw web.typeError("Failed to execute 'json' on 'Response': The data is not JSON serializable") }
            _ = web.heap.root(s)
            let o = try web.makeResponseFromInit(.undefined, args[1])
            o.body = JSWebBody(Array(try web.str(s).utf8))
            if !o.headers.has("content-type") { o.headers.list.append((name: "content-type", value: "application/json")) }
            return web.responseClass.wrap(o)
        }

        realm.defineMethod(realm.global, "fetch", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            web.fetchCount += 1
            let r: JSWebRequestObject
            do throws(JSThrow) {
                r = try web.makeRequest(args[0], args[1])
            } catch {
                if realm.isTerminating { throw error }
                return web.rejected(realm.takeException())
            }
            return web.startFetch(r)
        }
    }

    func stringArray(_ s: [String]) -> JSValue {
        let d = heap.rootDepth
        var vals: [JSValue] = []
        for x in s { let v = js(x); _ = heap.root(v); vals.append(v) }
        let a = array(vals)
        heap.popRoots(to: d)
        return a
    }

    func makeResponseFromInit(_ bodyV: JSValue, _ initV: JSValue) throws(JSThrow) -> JSWebResponseObject {
        let h = JSWebHeaders(3)
        var status = 200
        var statusText = ""
        if initV.isObject {
            let s = try get(initV, "status")
            if !s.isUndefined {
                let n = try realm.toNumber(s)
                if !(n >= 200 && n <= 599) { throw realm.throwRangeError("Failed to construct 'Response': The status provided (" + String(Int(n.isFinite ? n : 0)) + ") is outside the range [200, 599].") }
                status = Int(n)
            }
            let st = try get(initV, "statusText")
            if !st.isUndefined { statusText = try str(st) }
            let hv = try get(initV, "headers")
            if !hv.isUndefined { try fillHeaders(h, hv) }
        }
        var bytes: [UInt8]? = nil
        if let (b, t) = try extractBody(bodyV) {
            if status == 101 || status == 204 || status == 205 || status == 304 {
                throw typeError("Failed to construct 'Response': Response with null body status cannot have body")
            }
            bytes = b
            if let t = t, !h.has("content-type") { h.list.append((name: "content-type", value: t)) }
        }
        let o = JSWebResponseObject(headers: h, body: JSWebBody(bytes))
        o.status = status
        o.statusText = statusText
        return o
    }

    /// fetch(): a promise for the Response.
    func startFetch(_ r: JSWebRequestObject) -> JSValue {
        let promise = realm.newPromise()
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(promise)
        if r.signal.aborted {
            realm.rejectPromise(promise, b.AbortSignal_reason(r.signal))
            return promise
        }
        let job = JSWebJob(id: nextJob)
        nextJob += 1
        job.keep = [promise]
        jobs[job.id] = job
        var p = JSWebFetchParams(url: r.url)
        p.method = r.method
        for h in r.headers.list { p.headers.append((name: h.name, value: h.value)) }
        p.body = r.body.bytes
        p.mode = r.mode
        p.credentials = r.credentials
        p.reload = r.cache == "no-store" || r.cache == "reload" || r.cache == "no-cache"
        let url = r.url
        let signal = r.signal
        signal.abortAlgorithms.append { [unowned(unsafe) self] in
            if job.finished { return }
            job.aborted = true
            job.finished = true
            if job.netID != 0 { self.network.cancel(job.netID); job.netID = 0 }
            self.jobs[job.id] = nil
            let reason = self.b.AbortSignal_reason(signal)
            self.realm.rejectPromise(promise, reason)
        }
        corsFetch(p, job: job) { [unowned(unsafe) self] outcome in
            if job.finished { return }
            job.finished = true
            self.jobs[job.id] = nil
            let d2 = self.heap.rootDepth
            _ = self.heap.root(promise)
            switch outcome {
            case .networkError:
                self.realm.rejectPromise(promise, self.realm.makeError(.typeError, "Failed to fetch"))
            case .response(let resp, let type):
                var rr = resp
                if rr.body.count > self.maxBody { rr.body = Array(rr.body.prefix(self.maxBody)) }
                let o = self.makeResponse(rr, type: type, requestURL: url)
                let w = self.responseClass.wrap(o)
                _ = self.heap.root(w)
                try? self.realm.resolvePromise(promise, w)
            }
            self.heap.popRoots(to: d2)
        }
        return promise
    }
}

// MARK: base64 (data: URLs; Window has atob/btoa already)

func jswebBase64Decode(_ input: [UInt8]) -> [UInt8]? {
    var vals: [UInt8] = []
    for c in input {
        switch c {
        case 0x41...0x5a: vals.append(c - 0x41)
        case 0x61...0x7a: vals.append(c - 0x61 + 26)
        case 0x30...0x39: vals.append(c - 0x30 + 52)
        case 0x2b, 0x2d: vals.append(62)
        case 0x2f, 0x5f: vals.append(63)
        case 0x3d, 0x20, 0x0a, 0x0d, 0x09: continue
        default: return nil
        }
    }
    if vals.count % 4 == 1 { return nil }
    var out: [UInt8] = []
    var i = 0
    while i + 1 < vals.count {
        let a = UInt32(vals[i]), b = UInt32(vals[i + 1])
        let c = i + 2 < vals.count ? UInt32(vals[i + 2]) : 0
        let d = i + 3 < vals.count ? UInt32(vals[i + 3]) : 0
        let n = (a << 18) | (b << 12) | (c << 6) | d
        out.append(UInt8((n >> 16) & 0xff))
        if i + 2 < vals.count { out.append(UInt8((n >> 8) & 0xff)) }
        if i + 3 < vals.count { out.append(UInt8(n & 0xff)) }
        i += 4
    }
    return out
}
