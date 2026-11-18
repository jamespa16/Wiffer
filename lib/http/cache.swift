// In-memory HTTP cache keyed by URL (without fragment). A private
// (single-user) cache: honors no-store, no-cache, max-age, Expires and Age;
// no heuristic freshness; responses with Vary (other than Accept-Encoding)
// are not stored. Only GET responses are stored.

struct HTTPCacheEntry {
    var key: [UInt8]
    var status: Int
    var headers: [HTTPHeader]
    /// Body as received (still Content-Encoding encoded, like the wire).
    var body: [UInt8]
    var storedAt: Int
    /// Fresh until this Unix time (== storedAt or earlier means "always
    /// revalidate").
    var freshUntil: Int
    var etag: [UInt8]?
    var lastModified: [UInt8]?

    func isFresh(now: Int) -> Bool { now < freshUntil }
}

struct HTTPCacheControl {
    var noStore = false
    var noCache = false
    var maxAge: Int? = nil
    var mustRevalidate = false

    init(_ headers: [HTTPHeader]) {
        for v in headers.httpValues("Cache-Control") {
            for d in httpSplitList(v) {
                var name = d, arg: [UInt8] = []
                if let e = d.firstIndex(of: 0x3d) {
                    name = Array(d[0..<e]); arg = Array(d[(e + 1)...])
                    if arg.first == 0x22 && arg.last == 0x22 && arg.count >= 2 { arg = Array(arg[1..<(arg.count - 1)]) }
                }
                switch String(decoding: httpLowercased(httpTrim(name)), as: UTF8.self) {
                case "no-store": noStore = true
                case "no-cache": noCache = true
                case "must-revalidate": mustRevalidate = true
                case "max-age": if let n = httpParseDecimal(httpTrim(arg), limit: 1 << 40) { maxAge = n }
                default: break
                }
            }
        }
        if !headers.httpHas("Cache-Control") && headers.httpHas("Pragma") {
            if let p = headers.httpValue("Pragma"), httpLowercased(p) == Array("no-cache".utf8) { noCache = true }
        }
    }
}

struct HTTPCache {
    private(set) var entries: [HTTPCacheEntry] = []
    private(set) var totalBytes = 0
    var maxBytes: Int
    var maxEntryBytes: Int

    init(maxBytes: Int = 32 * 1024 * 1024) {
        self.maxBytes = maxBytes
        self.maxEntryBytes = maxBytes / 4
    }

    static func key(for url: URLRecord) -> [UInt8] { url.serializedBytes(excludeFragment: true) }

    private func index(_ key: [UInt8]) -> Int? {
        for (i, e) in entries.enumerated() where e.key == key { return i }
        return nil
    }

    private mutating func remove(at i: Int) {
        totalBytes -= entries[i].body.count
        entries.remove(at: i)
    }

    mutating func invalidate(_ url: URLRecord) {
        if let i = index(HTTPCache.key(for: url)) { remove(at: i) }
    }

    mutating func clear() { entries = []; totalBytes = 0 }

    private static func cacheableStatus(_ s: Int) -> Bool {
        switch s {
        case 200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501: return true
        default: return false
        }
    }

    /// Store a complete response if it's cacheable; returns whether it was
    /// stored. `now` is when the response was received.
    @discardableResult
    mutating func store(url: URLRecord, method: [UInt8], head: HTTPResponseHead, body: [UInt8], now: Int) -> Bool {
        let key = HTTPCache.key(for: url)
        let cc = HTTPCacheControl(head.headers)
        if cc.noStore { invalidate(url); return false }
        guard httpEqualsIgnoreCase(method, "GET"), HTTPCache.cacheableStatus(head.status) else { return false }
        if let vary = head.headers.httpValue("Vary") {
            for item in httpSplitList(vary) where httpLowercased(item) != Array("accept-encoding".utf8) {
                invalidate(url); return false
            }
        }
        if body.count > maxEntryBytes { return false }

        var lifetime = 0
        if cc.noCache { lifetime = 0 }
        else if let ma = cc.maxAge { lifetime = ma }
        else if let ex = head.headers.httpValue("Expires") {
            let date = head.headers.httpValue("Date").flatMap { httpParseDate($0) } ?? now
            lifetime = (httpParseDate(ex) ?? date) - date   // invalid Expires = already expired
        }
        var age = 0
        if let a = head.headers.httpValue("Age"), let v = httpParseDecimal(httpTrim(a), limit: 1 << 40) { age = v }
        let fresh = now - age + lifetime
        let etag = head.headers.httpValue("ETag")
        let lm = head.headers.httpValue("Last-Modified")
        // nothing to reuse or revalidate with
        if fresh <= now && etag == nil && lm == nil { invalidate(url); return false }

        invalidate(url)
        let entry = HTTPCacheEntry(key: key, status: head.status, headers: head.headers, body: body,
                                   storedAt: now, freshUntil: fresh, etag: etag, lastModified: lm)
        entries.append(entry)
        totalBytes += body.count
        while totalBytes > maxBytes && entries.count > 1 {
            var oldest = 0
            for i in 0..<entries.count where entries[i].storedAt < entries[oldest].storedAt { oldest = i }
            remove(at: oldest)
        }
        return true
    }

    /// A fresh entry for `url`, or nil.
    func lookup(_ url: URLRecord, now: Int) -> HTTPCacheEntry? {
        guard let i = index(HTTPCache.key(for: url)) else { return nil }
        return entries[i].isFresh(now: now) ? entries[i] : nil
    }

    /// Any entry (possibly stale), for conditional requests.
    func stale(_ url: URLRecord) -> HTTPCacheEntry? {
        guard let i = index(HTTPCache.key(for: url)) else { return nil }
        return entries[i]
    }

    /// Conditional request headers (If-None-Match / If-Modified-Since) for a
    /// stale entry.
    func conditionalHeaders(for url: URLRecord) -> [HTTPHeader] {
        guard let e = stale(url) else { return [] }
        var out: [HTTPHeader] = []
        if let t = e.etag { out.append(HTTPHeader(Array("If-None-Match".utf8), t)) }
        if let m = e.lastModified { out.append(HTTPHeader(Array("If-Modified-Since".utf8), m)) }
        return out
    }

    /// A 304 arrived: refresh the stored entry's freshness from the new
    /// headers and return it for use as the response.
    mutating func revalidated(_ url: URLRecord, newHeaders: [HTTPHeader], now: Int) -> HTTPCacheEntry? {
        guard let i = index(HTTPCache.key(for: url)) else { return nil }
        let cc = HTTPCacheControl(newHeaders)
        if cc.noStore { let e = entries[i]; remove(at: i); return e }
        var lifetime = 0
        if cc.noCache { lifetime = 0 }
        else if let ma = cc.maxAge { lifetime = ma }
        else if let ex = newHeaders.httpValue("Expires") {
            let date = newHeaders.httpValue("Date").flatMap { httpParseDate($0) } ?? now
            lifetime = (httpParseDate(ex) ?? date) - date
        }
        entries[i].storedAt = now
        entries[i].freshUntil = now + lifetime
        return entries[i]
    }
}
