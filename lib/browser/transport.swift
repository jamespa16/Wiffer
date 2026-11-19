// Transports: how the loader gets bytes for a URL. A transport is a class
// (no existentials in Embedded Swift) that starts requests, makes progress in
// poll() without blocking, and appends events for the loader to drain.
//
//   BrowserFileTransport (user/browse)   file:// through the libwiffer File API
//   BrowserHTTPTransport (http.swift)    http:// and https:// over BrowserStreams
//   BrowserMemoryTransport (here)        canned responses, for host tests
//
// Every request has an id chosen by the loader; cancel(id) drops it and no
// further events for it are delivered.

enum BrowserResourceKind: Equatable { case document, stylesheet, image }

struct BrowserRequest {
    var url: URLRecord
    var method = "GET"
    var body: [UInt8] = []
    var contentType: String? = nil
    var kind = BrowserResourceKind.document
    /// Skip fresh cache entries (reload).
    var reload = false

    init(url: URLRecord) { self.url = url }
}

struct BrowserResponse {
    /// The final URL (after redirects).
    var url: URLRecord
    var status = 200
    var contentType: [UInt8]? = nil
    var headers: [HTTPHeader] = []
    var body: [UInt8] = []
    /// file:// directories: the listing (the loader turns it into a page).
    var directory: [(name: String, isDirectory: Bool, size: Int)]? = nil

    init(url: URLRecord) { self.url = url }
}

/// Why a load failed (an error page shows `title` and `detail`).
enum BrowserLoadError: Equatable {
    case fileNotFound(String)
    case fileError(String)
    case dnsFailure(String)
    case connectionRefused(String)
    case connectionFailed(String)
    case timedOut(String)
    case tls(String)
    case badResponse(String)
    case tooManyRedirects
    case badRedirect
    case unsupportedScheme(String)
    case tooLarge
    case decodeFailed(String)

    var title: String {
        switch self {
        case .fileNotFound: return "File not found"
        case .fileError: return "Can't read the file"
        case .dnsFailure: return "Server not found"
        case .connectionRefused: return "Connection refused"
        case .connectionFailed: return "Connection failed"
        case .timedOut: return "The connection timed out"
        case .tls: return "Secure connection failed"
        case .badResponse: return "Bad response"
        case .tooManyRedirects, .badRedirect: return "Redirect loop"
        case .unsupportedScheme: return "Unsupported address"
        case .tooLarge: return "Too large"
        case .decodeFailed: return "Content encoding error"
        }
    }

    var detail: String {
        switch self {
        case .fileNotFound(let p): return "There is no file at " + p + "."
        case .fileError(let m): return m
        case .dnsFailure(let h): return "Can't find the server at " + h + " (DNS lookup failed)."
        case .connectionRefused(let h): return h + " refused the connection."
        case .connectionFailed(let m): return m
        case .timedOut(let h): return h + " took too long to respond."
        case .tls(let m): return "TLS: " + m
        case .badResponse(let m): return "The server sent something that isn't HTTP: " + m + "."
        case .tooManyRedirects: return "The page redirected too many times."
        case .badRedirect: return "The page redirected to an invalid address."
        case .unsupportedScheme(let s): return "The browser can't open \(s) addresses."
        case .tooLarge: return "The response is too large."
        case .decodeFailed(let m): return "The compressed response is corrupt (" + m + ")."
        }
    }
}

enum BrowserTransportEvent {
    case progress(id: Int, received: Int, total: Int?)
    case done(id: Int, BrowserResponse)
    case failed(id: Int, BrowserLoadError)
}

/// The base transport: handles nothing.
class BrowserTransport {
    /// Events for the loader (drained by it).
    var events: [BrowserTransportEvent] = []

    init() {}

    /// Can this transport fetch `scheme` ("file", "http", ...)?
    func handles(_ scheme: String) -> Bool { false }

    func start(_ id: Int, _ req: BrowserRequest, now: Int) {
        events.append(.failed(id: id, .unsupportedScheme(String(decoding: req.url.scheme, as: UTF8.self))))
    }

    func cancel(_ id: Int) {}

    /// Make progress without blocking.
    func poll(now: Int) {}

    /// True if poll() could make progress right away (the event loop should
    /// not sleep).
    var hasImmediateWork: Bool { false }

    /// The next time (ms) poll() must run for timeouts, or nil.
    func nextDeadline(now: Int) -> Int? { nil }

    /// File descriptors to wait on (fd, WaitEvent bits).
    func waitDescriptors() -> [(fd: Int, events: Int16)] { [] }

    /// Close everything (navigation away keeps connections; this is for exit).
    func shutdown() {}

    /// Status text ("Connecting to x", "Waiting for x").
    var activity: String { "" }
}

/// Canned responses by URL (without fragment), delivered `latency` polls
/// after the request (one response per poll, in request order), for tests.
final class BrowserMemoryTransport: BrowserTransport {
    struct Canned {
        var status: Int
        var contentType: String
        var body: [UInt8]
        var latency: Int
    }

    var resources: [String: Canned] = [:]
    var schemes: [String] = ["http", "https"]
    /// Requests seen (in order), and cancelled ids.
    private(set) var started: [(id: Int, request: BrowserRequest)] = []
    private(set) var cancelled: [Int] = []
    private var pending: [(id: Int, url: URLRecord, key: String, polls: Int)] = []

    override init() { super.init() }

    func add(_ url: String, _ body: String, type: String = "text/html", status: Int = 200, latency: Int = 0) {
        resources[url] = Canned(status: status, contentType: type, body: Array(body.utf8), latency: latency)
    }

    func add(_ url: String, bytes: [UInt8], type: String, status: Int = 200, latency: Int = 0) {
        resources[url] = Canned(status: status, contentType: type, body: bytes, latency: latency)
    }

    override func handles(_ scheme: String) -> Bool { schemes.contains(scheme) }

    override func start(_ id: Int, _ req: BrowserRequest, now: Int) {
        started.append((id: id, request: req))
        let key = String(decoding: req.url.serializedBytes(excludeFragment: true), as: UTF8.self)
        pending.append((id: id, url: req.url, key: key, polls: resources[key]?.latency ?? 0))
    }

    override func cancel(_ id: Int) {
        cancelled.append(id)
        pending.removeAll { $0.id == id }
    }

    override var hasImmediateWork: Bool { !pending.isEmpty }

    var pendingCount: Int { pending.count }

    override func poll(now: Int) {
        var i = 0
        while i < pending.count {
            if pending[i].polls > 0 { pending[i].polls -= 1; i += 1; continue }
            let p = pending.remove(at: i)
            if let c = resources[p.key] {
                var r = BrowserResponse(url: p.url)
                r.status = c.status
                r.contentType = Array(c.contentType.utf8)
                r.body = c.body
                events.append(.progress(id: p.id, received: c.body.count, total: c.body.count))
                events.append(.done(id: p.id, r))
            } else {
                events.append(.failed(id: p.id, .dnsFailure(p.url.hostname)))
            }
            return
        }
    }
}
