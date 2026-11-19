// HTTP/1.1 client transport over BrowserStreams (lib/http for the protocol):
// keep-alive connections from an HTTPConnectionPool (6 per origin), cookies,
// an in-memory cache with revalidation, redirects (10), gzip/deflate bodies
// (lib/inflate), and timeouts. The app gives it `openStream` (a socket, or
// TLS over one); host tests give it scripted streams.

final class BrowserHTTPTransport: BrowserTransport {
    /// Open a stream to host:port (TLS for https). Must not block.
    var openStream: (_ host: String, _ port: UInt16, _ tls: Bool, _ now: Int) -> BrowserStream = { _, _, _, _ in BrowserStream() }
    /// Unix seconds (cookies and cache freshness).
    var unixTime: () -> Int = { 0 }
    var pool = HTTPConnectionPool()
    var cookies = HTTPCookieJar()
    var cache = HTTPCache()
    var options = HTTPRequestOptions()
    /// ms from opening a connection to the first response byte, and between bytes.
    var connectTimeout = 20_000
    var responseTimeout = 30_000
    var maxBody = 32 * 1024 * 1024

    private final class Conn {
        let id: Int
        let key: HTTPOriginKey
        let host: String
        let stream: BrowserStream
        var job: Int? = nil
        var parser = HTTPResponseParser()
        var reused = false
        var sawBytes = false
        init(id: Int, key: HTTPOriginKey, host: String, stream: BrowserStream) {
            self.id = id; self.key = key; self.host = host; self.stream = stream
        }
    }

    private final class Job {
        let id: Int
        var req: BrowserRequest
        var url: URLRecord
        var method: [UInt8]
        var body: [UInt8]
        var redirects = 0
        var head: HTTPResponseHead? = nil
        var raw: [UInt8] = []
        var conn: Int? = nil
        var deadline = 0
        var retried = false
        var conditional = false
        init(id: Int, req: BrowserRequest) {
            self.id = id
            self.req = req
            url = req.url
            method = Array(req.method.utf8)
            body = req.body
        }
    }

    private var conns: [Int: Conn] = [:]
    private var jobs: [Int: Job] = [:]
    private var queue: [Int] = []

    override init() { super.init() }

    override func handles(_ scheme: String) -> Bool { scheme == "http" || scheme == "https" }

    /// Connections open now (for tests and the status line).
    var connectionCount: Int { conns.count }

    override func start(_ id: Int, _ req: BrowserRequest, now: Int) {
        let j = Job(id: id, req: req)
        jobs[id] = j
        if serveFromCache(j) { return }
        queue.append(id)
        schedule(now: now)
    }

    override func cancel(_ id: Int) {
        guard let j = jobs.removeValue(forKey: id) else { return }
        queue.removeAll { $0 == id }
        if let cid = j.conn, let c = conns[cid] { drop(c) }
    }

    override func shutdown() {
        for (_, c) in conns { c.stream.close() }
        conns = [:]
        jobs = [:]
        queue = []
        pool = HTTPConnectionPool()
    }

    override var hasImmediateWork: Bool {
        for (_, c) in conns where c.stream.hasBufferedInput { return true }
        return false
    }

    override func nextDeadline(now: Int) -> Int? {
        var best: Int? = nil
        for (_, j) in jobs where j.conn != nil { best = best.map { min($0, j.deadline) } ?? j.deadline }
        return best
    }

    override func waitDescriptors() -> [(fd: Int, events: Int16)] {
        var out: [(fd: Int, events: Int16)] = []
        for (_, c) in conns where c.stream.waitFD >= 0 { out.append((fd: c.stream.waitFD, events: c.stream.waitEvents)) }
        return out
    }

    override var activity: String {
        for (_, c) in conns where c.job != nil {
            if case .connecting = c.stream.state { return "connecting to " + c.host }
        }
        for (_, c) in conns where c.job != nil && !c.sawBytes { return "waiting for " + c.host }
        return ""
    }

    // MARK: Scheduling

    private func serveFromCache(_ j: Job) -> Bool {
        guard j.method == Array("GET".utf8), !j.req.reload, let e = cache.lookup(j.url, now: unixTime()) else { return false }
        deliver(j, status: e.status, headers: e.headers, body: e.body)
        return true
    }

    private func schedule(now: Int) {
        var i = 0
        while i < queue.count {
            guard let j = jobs[queue[i]] else { queue.remove(at: i); continue }
            let key = HTTPOriginKey(url: j.url)
            switch pool.acquire(key, now: now / 1000) {
            case .wait:
                i += 1
            case .reuse(let cid):
                queue.remove(at: i)
                if let c = conns[cid] {
                    c.reused = true
                    attach(j, c, now: now)
                } else {
                    pool.remove(cid)
                    queue.insert(j.id, at: i)
                }
            case .open(let cid):
                queue.remove(at: i)
                let tls = j.url.scheme == Array("https".utf8)
                let port = j.url.effectivePort ?? (tls ? 443 : 80)
                let c = Conn(id: cid, key: key, host: j.url.hostname, stream: openStream(j.url.hostname, port, tls, now))
                conns[cid] = c
                attach(j, c, now: now)
            }
        }
        for cid in pool.drainClosable() {
            if let c = conns.removeValue(forKey: cid) { c.stream.close() }
        }
    }

    private func attach(_ j: Job, _ c: Conn, now: Int) {
        j.conn = c.id
        j.head = nil
        j.raw = []
        c.job = j.id
        c.sawBytes = false
        c.parser = HTTPResponseParser(requestMethod: j.method)
        var headers: [HTTPHeader] = []
        switch j.req.kind {
        case .image: headers.append(HTTPHeader("Accept", "image/png,image/jpeg,image/gif,image/*;q=0.8,*/*;q=0.5"))
        case .stylesheet: headers.append(HTTPHeader("Accept", "text/css,*/*;q=0.1"))
        case .document: break
        }
        j.conditional = false
        if j.method == Array("GET".utf8) && !j.req.reload {
            let cond = cache.conditionalHeaders(for: j.url)
            if !cond.isEmpty { headers += cond; j.conditional = true }
        }
        let cookie = cookies.cookieHeader(for: j.url, now: unixTime())
        let ct: [UInt8]? = j.body.isEmpty ? nil : j.req.contentType.map { Array($0.utf8) }
        c.stream.send(httpBuildRequest(method: j.method, url: j.url, headers: headers, body: j.body, contentType: ct,
                                       cookie: cookie, options: options))
        j.deadline = now + connectTimeout
        c.stream.pump(now: now)
    }

    private func drop(_ c: Conn) {
        c.stream.close()
        pool.remove(c.id)
        conns[c.id] = nil
    }

    // MARK: Progress

    override func poll(now: Int) {
        for (_, c) in conns { service(c, now: now) }
        for (id, j) in jobs where j.conn != nil && now >= j.deadline {
            if let cid = j.conn, let c = conns[cid] { drop(c) }
            jobs[id] = nil
            events.append(.failed(id: id, .timedOut(j.url.hostname)))
        }
        schedule(now: now)
    }

    private func service(_ c: Conn, now: Int) {
        c.stream.pump(now: now)
        let data = c.stream.receive()
        let st = c.stream.state
        guard let jid = c.job, let j = jobs[jid] else {
            // Idle: the server may close it; anything else is unexpected.
            switch st {
            case .closed, .failed: drop(c)
            default: if !data.isEmpty { drop(c) }
            }
            return
        }
        var evs: [HTTPParseEvent] = []
        if !data.isEmpty {
            c.sawBytes = true
            j.deadline = now + responseTimeout
            c.parser.feed(data, &evs)
        }
        switch st {
        case .closed:
            c.parser.finish(&evs)
        case .failed(let e):
            if !c.sawBytes {
                if c.reused && !j.retried { retry(j, c, now: now); return }
                fail(j, c, e)
                return
            }
            c.parser.finish(&evs)
        default: break
        }
        if st == .closed && !c.sawBytes && c.reused && !j.retried && evs.allSatisfy({ if case .error = $0 { return true }; return false }) {
            retry(j, c, now: now)
            return
        }
        process(evs, j, c, now: now)
    }

    private func retry(_ j: Job, _ c: Conn, now: Int) {
        j.retried = true
        j.conn = nil
        c.job = nil
        drop(c)
        queue.insert(j.id, at: 0)
    }

    private func fail(_ j: Job, _ c: Conn?, _ e: BrowserLoadError) {
        if let c = c { c.job = nil; drop(c) }
        jobs[j.id] = nil
        events.append(.failed(id: j.id, e))
    }

    private func process(_ evs: [HTTPParseEvent], _ j: Job, _ c: Conn, now: Int) {
        for e in evs {
            switch e {
            case .head(let h):
                if h.status >= 100 && h.status < 200 { continue }
                j.head = h
                for sc in h.setCookies { _ = cookies.setCookie(sc, from: j.url, now: unixTime()) }
                var total: Int? = nil
                if let cl = h.header("Content-Length") { total = httpParseDecimal(httpTrim(cl)) }
                events.append(.progress(id: j.id, received: 0, total: total))
            case .body(let b):
                j.raw += b
                if j.raw.count > maxBody { fail(j, c, .tooLarge); return }
                events.append(.progress(id: j.id, received: j.raw.count, total: nil))
            case .trailers:
                break
            case .complete(let keepAlive):
                c.job = nil
                j.conn = nil
                if !pool.release(c.id, reusable: keepAlive && c.stream.state == .open, now: now / 1000) {
                    conns[c.id] = nil
                    c.stream.close()
                }
                complete(j, now: now)
                return
            case .error(let pe):
                fail(j, c, .badResponse(browserParseErrorName(pe)))
                return
            }
        }
    }

    private func complete(_ j: Job, now: Int) {
        guard let h = j.head else { fail(j, nil, .badResponse("no response")); return }
        if h.status == 304 && j.conditional, let e = cache.revalidated(j.url, newHeaders: h.headers, now: unixTime()) {
            deliver(j, status: e.status, headers: e.headers, body: e.body)
            return
        }
        switch httpRedirectDecision(status: h.status, method: j.method, location: h.location, current: j.url,
                                    redirectsSoFar: j.redirects) {
        case .follow(let method, let url, let dropBody, _):
            j.redirects += 1
            j.method = method
            if dropBody { j.body = []; j.req.contentType = nil }
            j.url = url
            if !serveFromCache(j) { queue.insert(j.id, at: 0) }
            return
        case .tooMany:
            fail(j, nil, .tooManyRedirects)
            return
        case .invalid:
            fail(j, nil, .badRedirect)
            return
        case .notRedirect:
            break
        }
        var body = j.raw
        switch h.contentEncoding {
        case .identity: break
        case .gzip, .deflate:
            do throws(InflateError) {
                body = try inflateBytes(j.raw, format: .auto, maxOutput: maxBody)
            } catch {
                fail(j, nil, .decodeFailed(h.contentEncoding == .gzip ? "gzip" : "deflate"))
                return
            }
        case .brotli, .unknown:
            fail(j, nil, .decodeFailed("unsupported Content-Encoding"))
            return
        }
        var stored = h
        stored.headers.removeAll { httpEqualsIgnoreCase($0.name, "Content-Encoding") }
        _ = cache.store(url: j.url, method: j.method, head: stored, body: body, now: unixTime())
        deliver(j, status: h.status, headers: stored.headers, body: body)
    }

    private func deliver(_ j: Job, status: Int, headers: [HTTPHeader], body: [UInt8]) {
        jobs[j.id] = nil
        var r = BrowserResponse(url: j.url)
        r.status = status
        r.headers = headers
        r.contentType = headers.httpValue("Content-Type")
        r.body = body
        events.append(.progress(id: j.id, received: body.count, total: body.count))
        events.append(.done(id: j.id, r))
    }
}

func browserParseErrorName(_ e: HTTPParseError) -> String {
    switch e {
    case .lineTooLong: return "header line too long"
    case .tooManyHeaders: return "too many headers"
    case .headersTooLarge: return "headers too large"
    case .badStatusLine: return "bad status line"
    case .badHeader: return "bad header"
    case .badContentLength: return "bad Content-Length"
    case .badChunk: return "bad chunked encoding"
    case .bodyTooLarge: return "body too large"
    case .truncated: return "the connection closed early"
    }
}
