// lib/js-web: the Web platform APIs a page's scripts use beside the DOM
// (ROADMAP Phase 9H): URL and URLSearchParams (lib/url), TextEncoder and
// TextDecoder (lib/text), Blob, FormData, Headers, Request, Response,
// fetch() and XMLHttpRequest (async only), with the same-origin policy and
// simple CORS. No OS and no lib/http: the network is a pair of closures the
// embedder fills in (the browser: BrowserHTTPTransport through its loader,
// so requests share the connection pool, cookies and cache; host tests: a
// fake), so everything here is host-testable.
//
//     let net = JSWebNetwork()
//     net.start = { req, done in ...; return id }   // later: done(.response(r)) or done(.failure(msg))
//     net.cancel = { id in ... }
//     let web = JSWeb(page: page, network: net)       // installs the globals
//     ...
//     web.tearDown()                                  // before page.tearDown()
//
// `done` may be called at any time after `start` returns (also from inside
// it); the result is handled as a task on the page's event loop. The
// embedder keeps `web` alive as long as the page (natives hold it unowned).
//
// The network sees the request as it goes on the wire: `credentials` says
// whether cookies are sent and stored; `headers` already carry Origin for
// cross-origin requests. Redirects are the network's job (followed, at most
// 20); the response's url is the final one. The CORS checks (preflight,
// Access-Control-Allow-Origin, exposed headers) are done here.

struct JSWebRequest {
    var method = "GET"
    var url: URLRecord
    var headers: [(name: String, value: String)] = []
    var body: [UInt8] = []
    /// Send cookies (and store Set-Cookie): same-origin, or credentials "include".
    var credentials = true
    /// Bypass the cache (cache: "no-store" / "reload" / "no-cache").
    var reload = false
    /// A CORS preflight (OPTIONS): never served from the cache, no body.
    var preflight = false
    init(url: URLRecord) { self.url = url }
}

struct JSWebResponse {
    /// The final URL (after redirects).
    var url: URLRecord
    var status = 200
    var statusText = ""
    var headers: [(name: String, value: String)] = []
    var body: [UInt8] = []
    init(url: URLRecord) { self.url = url }

    func header(_ name: String) -> String? {
        for h in headers where jswebEqualsIgnoreCase(h.name, name) { return h.value }
        return nil
    }
}

enum JSWebNetResult {
    case response(JSWebResponse)
    /// A network error (DNS, refused, TLS, ...): fetch rejects with TypeError.
    case failure(String)
}

final class JSWebNetwork {
    /// Start a request; returns an id for cancel. Call `done` once, later.
    var start: (_ request: JSWebRequest, _ done: @escaping (JSWebNetResult) -> Void) -> Int = { _, done in
        done(.failure("no network"))
        return 0
    }
    var cancel: (_ id: Int) -> Void = { _ in }
    /// Requests started (diagnostics, tests).
    var started = 0
    init() {}
}

// MARK: Small string helpers

func jswebLowerASCII(_ s: String) -> String {
    var b = Array(s.utf8)
    for i in 0..<b.count where b[i] >= 0x41 && b[i] <= 0x5a { b[i] += 32 }
    return String(decoding: b, as: UTF8.self)
}

func jswebEqualsIgnoreCase(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    if x.count != y.count { return false }
    for i in 0..<x.count {
        let p = x[i] >= 0x41 && x[i] <= 0x5a ? x[i] + 32 : x[i]
        let q = y[i] >= 0x41 && y[i] <= 0x5a ? y[i] + 32 : y[i]
        if p != q { return false }
    }
    return true
}

func jswebTrimHTTPSpace(_ s: String) -> String {
    var b = Array(s.utf8)
    while let l = b.last, l == 0x20 || l == 0x09 || l == 0x0a || l == 0x0d { b.removeLast() }
    var i = 0
    while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0a || b[i] == 0x0d { i += 1 }
    return String(decoding: b[i...], as: UTF8.self)
}

/// A header name is an RFC 9110 token.
func jswebIsToken(_ s: String) -> Bool {
    let b = Array(s.utf8)
    if b.isEmpty { return false }
    for c in b {
        switch c {
        case 0x30...0x39, 0x41...0x5a, 0x61...0x7a: continue
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2a, 0x2b, 0x2d, 0x2e, 0x5e, 0x5f, 0x60, 0x7c, 0x7e: continue
        default: return false
        }
    }
    return true
}

/// A header value has no NUL, CR or LF (after trimming).
func jswebIsHeaderValue(_ s: String) -> Bool {
    for c in s.utf8 where c == 0 || c == 0x0a || c == 0x0d { return false }
    return true
}

/// The essence of a MIME type ("text/html; charset=x" -> "text/html").
func jswebMIMEEssence(_ s: String) -> String {
    var out: [UInt8] = []
    for c in s.utf8 {
        if c == 0x3b { break }
        if c == 0x20 || c == 0x09 { continue }
        out.append(c >= 0x41 && c <= 0x5a ? c + 32 : c)
    }
    return String(decoding: out, as: UTF8.self)
}

/// The charset parameter of a MIME type, lowercased.
func jswebMIMECharset(_ s: String) -> String? {
    guard let cs = charsetFromContentType(Array(s.utf8)) else { return nil }
    return jswebLowerASCII(String(decoding: cs, as: UTF8.self))
}

/// Bytes as text: BOM sniffing, then the label (default UTF-8).
func jswebDecodeText(_ bytes: [UInt8], label: String? = nil) -> String {
    var enc = TextEncoding.utf8
    var start = 0
    if bytes.count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf { start = 3 }
    else if bytes.count >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe { enc = .utf16le; start = 2 }
    else if bytes.count >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff { enc = .utf16be; start = 2 }
    else if let l = label, let e = charsetEncodingForLabel(l), e != .unsupported { enc = e }
    return String(decoding: charsetDecodeToUTF8(bytes, enc, from: start), as: UTF8.self)
}

// MARK: The per-page API object

final class JSWeb {
    let page: JSDOMPage
    let b: JSDOMBindings
    let realm: JSRealm
    let heap: JSHeap
    let network: JSWebNetwork
    var tornDown = false

    var urlClass: JSHostClass<JSWebURL>!
    var paramsClass: JSHostClass<JSWebParams>!
    var encoderClass: JSHostClass<JSWebTextEncoder>!
    var decoderClass: JSHostClass<JSWebTextDecoder>!
    var blobClass: JSHostClass<JSWebBlob>!
    var formDataClass: JSHostClass<JSWebFormData>!
    var headersClass: JSHostClass<JSWebHeaders>!
    var requestClass: JSHostClass<JSWebRequestObject>!
    var responseClass: JSHostClass<JSWebResponseObject>!
    /// XMLHttpRequest.prototype (wrappers are EventTarget objects).
    var xhrProto: JSValue = .undefined
    var xhrUploadProto: JSValue = .undefined
    var timeoutFn: JSValue = .undefined
    var rootID = 0

    /// In-flight network jobs (for cancel at teardown).
    var jobs: [Int: JSWebJob] = [:]
    var nextJob = 1
    /// fetch() / XHR calls (diagnostics).
    var fetchCount = 0
    var xhrCount = 0
    /// Max response body kept by XHR/fetch.
    var maxBody = 64 * 1024 * 1024

    init(page: JSDOMPage, network: JSWebNetwork) {
        self.page = page
        b = page.bindings
        realm = page.realm
        heap = page.realm.heap
        self.network = network
        rootID = heap.addRootProvider { [unowned(unsafe) self] h in
            h.markValue(self.xhrProto)
            h.markValue(self.xhrUploadProto)
            h.markValue(self.timeoutFn)
            for (_, j) in self.jobs { j.mark(h) }
        }
        installURL()
        installEncoding()
        installBlobAndFormData()
        installFetch()
        installXHR()
    }

    /// Cancel in-flight requests; call before page.tearDown().
    func tearDown() {
        if tornDown { return }
        tornDown = true
        for (_, j) in jobs { if j.netID != 0 { network.cancel(j.netID) } }
        jobs = [:]
        heap.removeRootProvider(rootID)
    }

    /// The document's origin ("null" for opaque ones).
    var origin: String { b.url?.origin ?? "null" }

    // MARK: Value helpers

    func str(_ v: JSValue) throws(JSThrow) -> String { try realm.toSwiftString(v) }
    func js(_ s: String) -> JSValue { heap.newString(s) }

    func get(_ o: JSValue, _ name: String) throws(JSThrow) -> JSValue { try realm.getV(o, heap.key(name)) }

    func setValue(_ o: JSValue, _ name: String, _ v: JSValue) {
        let d = heap.rootDepth
        _ = heap.root(o)
        _ = heap.root(v)
        _ = heap.createDataProperty(o, heap.key(name), v)
        heap.popRoots(to: d)
    }

    /// A JS array of `vals` (rooted while it is built).
    func array(_ vals: [JSValue]) -> JSValue {
        let d = heap.rootDepth
        for v in vals { _ = heap.root(v) }
        let a = heap.newArray(proto: realm.arrayPrototype, elements: vals)
        heap.popRoots(to: d)
        return a
    }

    /// An array iterator over `n` items: kind 0 keys, 1 values, 2 [key, value].
    func listIterator(_ n: Int, kind: Int, _ item: (Int) throws(JSThrow) -> (String, JSValue)) throws(JSThrow) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        var vals: [JSValue] = []
        var i = 0
        while i < n {
            let (k, v) = try item(i)
            _ = heap.root(v)
            let x: JSValue
            switch kind {
            case 0: x = js(k)
            case 1: x = v
            default:
                let ks = js(k)
                _ = heap.root(ks)
                x = array([ks, v])
            }
            _ = heap.root(x)
            vals.append(x)
            i += 1
        }
        let a = array(vals)
        _ = heap.root(a)
        return try realm.call(realm.intrinsic(.arrayValues), this: a, args: [])
    }

    func uint8Array(_ bytes: [UInt8]) throws(JSThrow) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let buf = try realm.newArrayBuffer(bytes: bytes)
        _ = heap.root(buf)
        return realm.makeTypedArray(proto: realm.intrinsic(.uint8ArrayPrototype), type: .uint8, buffer: buf,
                                    offset: 0, length: bytes.count)
    }

    /// The bytes of an ArrayBuffer, typed array or DataView (nil otherwise).
    func bufferSourceBytes(_ v: JSValue) -> [UInt8]? {
        guard v.isObject else { return nil }
        switch heap.kind(v) {
        case .arrayBuffer:
            return realm.arrayBufferBytes(v) ?? []
        case .typedArray:
            guard let i = heap.objectIndex(v) else { return nil }
            guard let view = heap.typedArrayView(i) else { return [] }
            let store = heap.byteStores[view.store]
            let n = view.length * view.type.size
            let lo = min(max(view.offset, 0), store.count)
            let hi = min(lo + max(n, 0), store.count)
            return Array(store[lo..<hi])
        case .dataView:
            let buf = heap.slot(v, 0)
            guard let all = realm.arrayBufferBytes(buf) else { return [] }
            let off = heap.slot(v, 1).numberValue
            let lenV = heap.slot(v, 2)
            let lo = off.isFinite ? min(max(Int(off), 0), all.count) : 0
            var hi = all.count
            if lenV.isNumber && lenV.numberValue >= 0 && lenV.numberValue.isFinite { hi = min(lo + Int(lenV.numberValue), all.count) }
            return Array(all[lo..<max(lo, hi)])
        default:
            return nil
        }
    }

    func typeError(_ msg: String) -> JSThrow { realm.throwTypeError(msg) }

    /// Read a dictionary member (undefined if `o` is not an object).
    func member(_ o: JSValue, _ name: String) throws(JSThrow) -> JSValue {
        if !o.isObject { return .undefined }
        return try get(o, name)
    }

    /// Define a method keyed by Symbol.iterator, aliasing `name` on `proto`.
    func aliasIterator(_ proto: JSValue, _ name: String) {
        let f = heap.getProperty(proto, heap.key(name))
        if case .value(let v) = f {
            let d = heap.rootDepth
            _ = heap.root(v)
            _ = heap.defineOwnProperty(proto, .symbol(heap.symbolsWellKnown.iterator.handle), .data(v, [.writable, .configurable]))
            heap.popRoots(to: d)
        }
    }

    func setToStringTag(_ proto: JSValue, _ name: String) {
        let d = heap.rootDepth
        let s = js(name)
        _ = heap.root(s)
        _ = heap.defineOwnProperty(proto, .symbol(heap.symbolsWellKnown.toStringTag.handle), .data(s, [.configurable]))
        heap.popRoots(to: d)
    }

    /// Run `body` as a task on the page's loop (network completions).
    func queue(_ body: @escaping () -> Void) {
        if tornDown { return }
        page.loop.queueTask(body)
    }
}
