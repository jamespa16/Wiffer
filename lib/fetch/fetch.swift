// lib/fetch: an HTTP/1.1 (and HTTPS) client exchange with no I/O (Phase
// 7F; /bin/fetch and the browser use it). It glues lib/tls, lib/http and
// lib/inflate together; the caller owns the socket and the event loop:
//
//   var ex = FetchExchange(url: url, tls: tlsConfig /* nil for http */, random: { Random.bytes($0) })
//   ex.start()                                  // request (or ClientHello) queued
//   loop {
//       send(socket, ex.takeOutput())           // whatever is queued (may be empty)
//       let wire = recv(socket)                 // any split, non-blocking is fine
//       let events = wire.isEmpty ? ex.receiveEOF() : ex.receive(wire)
//       for e in events {
//           case .head(h):      status, headers (h.status, h.location, ...)
//           case .body(bytes):  decoded body (gzip/deflate undone)
//           case .complete(keepAlive): done; .failed(message): give up
//       }
//   }
//
// Pieces, usable on their own:
//   FetchTransport          plain or TLS byte pipe (start/write/takeOutput/
//                           feed/read/transportClosed/close, failure)
//   FetchResponseReader     HTTPResponseParser + Content-Encoding decoding
//                           (Inflater) -> FetchEvent
//   fetchRequestBytes(...)  the request (httpBuildRequest with our defaults)
//   fetchEndpoint(url)      host, port, TLS or not; nil for other schemes
//   fetchRedirect(...)      httpRedirectDecision for a finished head
//
// Keep-alive: after .complete(keepAlive: true) the transport can carry the
// next request (`FetchExchange(next:url:...)` reuses it); /bin/fetch sends
// "Connection: close" instead.

enum FetchEvent {
    case head(HTTPResponseHead)
    /// Decoded body bytes (Content-Encoding removed).
    case body([UInt8])
    case complete(keepAlive: Bool)
    case failed(String)
}

struct FetchEndpoint {
    var host: String
    /// The host as an IPv4 literal, if it is one.
    var ipv4: UInt32?
    var port: UInt16
    var tls: Bool
}

/// Where to connect for `url` (http and https only).
func fetchEndpoint(_ url: URLRecord) -> FetchEndpoint? {
    let https = url.scheme == Array("https".utf8)
    guard https || url.scheme == Array("http".utf8), let host = url.host else { return nil }
    var ip: UInt32? = nil
    var name = ""
    switch host {
    case .domain(let d): name = String(decoding: d, as: UTF8.self)
    case .ipv4(let a): ip = a; name = String(decoding: host.serialized, as: UTF8.self)
    default: return nil // IPv6 and opaque hosts: not supported
    }
    return FetchEndpoint(host: name, ipv4: ip, port: url.effectivePort ?? (https ? 443 : 80), tls: https)
}

/// The request for `url`. `keepAlive` false sends "Connection: close".
func fetchRequestBytes(url: URLRecord, method: String = "GET", headers: [HTTPHeader] = [], body: [UInt8] = [],
                       contentType: [UInt8]? = nil, keepAlive: Bool = false,
                       userAgent: String = "Wiffer-fetch/0.1") -> [UInt8] {
    var o = HTTPRequestOptions()
    o.keepAlive = keepAlive
    o.userAgent = userAgent
    o.accept = "*/*"
    return httpBuildRequest(method: Array(method.utf8), url: url, headers: headers, body: body,
                            contentType: contentType, options: o)
}

/// The redirect to follow for a finished response head, if any.
func fetchRedirect(_ head: HTTPResponseHead, method: String, url: URLRecord, redirectsSoFar: Int) -> HTTPRedirectDecision {
    httpRedirectDecision(status: head.status, method: Array(method.utf8), location: head.location, current: url,
                         redirectsSoFar: redirectsSoFar)
}

// MARK: Transport

/// The byte pipe under HTTP: either plain (bytes pass straight through) or a
/// TLSClient. "Wire" bytes go to and come from the socket; "plain" bytes are
/// HTTP.
final class FetchTransport {
    let tls: TLSClient?
    private var outWire: [UInt8] = []
    private var inPlain: [UInt8] = []
    private(set) var eof = false

    /// A plain (http) transport.
    init() { tls = nil }

    /// An https transport.
    init(tls config: TLSClientConfig, random: @escaping (Int) -> [UInt8]) {
        tls = TLSClient(config: config, random: random)
    }

    var isTLS: Bool { tls != nil }

    /// Queue the ClientHello (TLS); nothing for plain.
    func start() { tls?.start() }

    /// Queue plaintext to send (TLS: buffered until the handshake is done).
    @discardableResult
    func write(_ data: [UInt8]) -> Bool {
        if let t = tls { return t.write(data) }
        guard !eof else { return false }
        outWire += data
        return true
    }

    /// Wire bytes to send now.
    func takeOutput() -> [UInt8] {
        if let t = tls { return t.takeOutput() }
        let o = outWire
        outWire = []
        return o
    }

    var hasOutput: Bool { tls?.hasOutput ?? !outWire.isEmpty }

    /// Wire bytes from the socket.
    func feed(_ wire: [UInt8]) {
        if let t = tls { t.feed(wire) } else { inPlain += wire }
    }

    /// Plaintext received so far (and clears it).
    func read() -> [UInt8] {
        if let t = tls { return t.read() }
        let d = inPlain
        inPlain = []
        return d
    }

    /// The socket reached end of stream.
    func transportClosed() {
        eof = true
        tls?.transportClosed()
    }

    /// No more plaintext will arrive (EOF, or the server's close_notify).
    var inputEnded: Bool { eof || (tls?.peerClosed ?? false) }

    /// TLS: send close_notify (take the output afterwards).
    func close() { tls?.close() }

    /// Why the transport failed (TLS errors), or nil.
    var failure: String? {
        guard let t = tls, t.state == .failed else { return nil }
        return "TLS: " + (t.error.map { $0.description } ?? "failed")
    }

    /// TLS handshake finished (always true for plain).
    var ready: Bool { tls.map { $0.state == .connected || $0.state == .closed } ?? true }
}

// MARK: Response

/// An HTTP response, parsed and decoded as bytes arrive.
final class FetchResponseReader {
    private var parser: HTTPResponseParser
    private var inflater: Inflater? = nil
    private(set) var head: HTTPResponseHead? = nil
    private(set) var finished = false
    let maxBody: Int
    private(set) var bodyBytes = 0

    init(method: String = "GET", maxBody: Int = 256 << 20) {
        parser = HTTPResponseParser(requestMethod: Array(method.utf8))
        self.maxBody = maxBody
    }

    func feed(_ data: [UInt8]) -> [FetchEvent] {
        guard !finished, !data.isEmpty else { return [] }
        var events: [HTTPParseEvent] = []
        parser.feed(data, &events)
        return translate(events)
    }

    /// End of input (the server closed).
    func finish() -> [FetchEvent] {
        guard !finished else { return [] }
        var events: [HTTPParseEvent] = []
        parser.finish(&events)
        var out = translate(events)
        if !finished {
            finished = true
            out.append(.failed("connection closed before the response ended"))
        }
        return out
    }

    private func fail(_ why: String, _ out: inout [FetchEvent]) {
        finished = true
        out.append(.failed(why))
    }

    private func translate(_ events: [HTTPParseEvent]) -> [FetchEvent] {
        var out: [FetchEvent] = []
        for e in events where !finished {
            switch e {
            case .head(let h):
                head = h
                switch h.contentEncoding {
                case .identity: inflater = nil
                case .gzip: inflater = Inflater(format: .gzip, maxOutput: maxBody)
                case .deflate: inflater = Inflater(format: .auto, maxOutput: maxBody)
                case .brotli, .unknown:
                    fail("unsupported Content-Encoding", &out)
                    continue
                }
                out.append(.head(h))
            case .body(let raw):
                if inflater != nil {
                    do throws(InflateError) {
                        try inflater!.feed(raw)
                    } catch {
                        fail("bad compressed body (" + fetchInflateMessage(error) + ")", &out)
                        continue
                    }
                    let d = inflater!.take()
                    if !d.isEmpty { emit(d, &out) }
                } else {
                    emit(raw, &out)
                }
            case .trailers:
                break
            case .complete(let keepAlive):
                if inflater != nil {
                    do throws(InflateError) {
                        try inflater!.finish()
                    } catch {
                        fail("bad compressed body (" + fetchInflateMessage(error) + ")", &out)
                        continue
                    }
                    let d = inflater!.take()
                    if !d.isEmpty { emit(d, &out) }
                }
                if !finished {
                    finished = true
                    out.append(.complete(keepAlive: keepAlive))
                }
            case .error(let err):
                fail("bad HTTP response (" + fetchParseMessage(err) + ")", &out)
            }
        }
        return out
    }

    private func emit(_ d: [UInt8], _ out: inout [FetchEvent]) {
        bodyBytes += d.count
        if bodyBytes > maxBody { fail("body larger than \(maxBody) bytes", &out); return }
        out.append(.body(d))
    }
}

// MARK: Exchange

/// One request and its response over a transport.
final class FetchExchange {
    let url: URLRecord
    let method: String
    let transport: FetchTransport
    let reader: FetchResponseReader
    private let request: [UInt8]
    private(set) var done = false

    /// A request on a new connection. `tls` nil: plain HTTP.
    init(url: URLRecord, method: String = "GET", headers: [HTTPHeader] = [], body: [UInt8] = [],
         keepAlive: Bool = false, tls: TLSClientConfig?, random: @escaping (Int) -> [UInt8],
         maxBody: Int = 256 << 20) {
        self.url = url
        self.method = method
        transport = tls.map { FetchTransport(tls: $0, random: random) } ?? FetchTransport()
        reader = FetchResponseReader(method: method, maxBody: maxBody)
        request = fetchRequestBytes(url: url, method: method, headers: headers, body: body, keepAlive: keepAlive)
    }

    /// The next request on a kept-alive transport (already started).
    init(next transport: FetchTransport, url: URLRecord, method: String = "GET", headers: [HTTPHeader] = [],
         body: [UInt8] = [], keepAlive: Bool = true, maxBody: Int = 256 << 20) {
        self.url = url
        self.method = method
        self.transport = transport
        reader = FetchResponseReader(method: method, maxBody: maxBody)
        request = fetchRequestBytes(url: url, method: method, headers: headers, body: body, keepAlive: keepAlive)
    }

    /// Queue the request (after the ClientHello, for TLS). Call once.
    func start() {
        if transport.isTLS && transport.tls!.state == .idle { transport.start() }
        transport.write(request)
    }

    func takeOutput() -> [UInt8] { transport.takeOutput() }

    /// Bytes from the socket.
    func receive(_ wire: [UInt8]) -> [FetchEvent] {
        guard !done else { return [] }
        transport.feed(wire)
        return collect()
    }

    /// The socket reached end of stream.
    func receiveEOF() -> [FetchEvent] {
        guard !done else { return [] }
        transport.transportClosed()
        return collect()
    }

    private func collect() -> [FetchEvent] {
        var out = reader.feed(transport.read())
        if let f = transport.failure, !reader.finished {
            out.append(.failed(f))
            done = true
            return out
        }
        if transport.inputEnded && !reader.finished { out += reader.finish() }
        if reader.finished { done = true }
        return out
    }
}

func fetchInflateMessage(_ e: InflateError) -> String {
    switch e {
    case .badHeader: return "bad gzip/zlib header"
    case .badChecksum: return "checksum mismatch"
    case .truncated: return "truncated"
    case .invalidBlockType, .invalidStoredLength, .invalidCode, .invalidDistance: return "corrupt deflate data"
    case .outputLimit: return "too large"
    }
}

func fetchParseMessage(_ e: HTTPParseError) -> String {
    switch e {
    case .lineTooLong: return "line too long"
    case .tooManyHeaders: return "too many headers"
    case .headersTooLarge: return "headers too large"
    case .badStatusLine: return "bad status line"
    case .badHeader: return "bad header"
    case .badContentLength: return "bad Content-Length"
    case .badChunk: return "bad chunk"
    case .bodyTooLarge: return "body too large"
    case .truncated: return "truncated"
    }
}
