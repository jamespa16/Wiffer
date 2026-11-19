// Byte streams for the HTTP client: a TCP connection (user/browse wraps a
// non-blocking socket), or TLS over one (BrowserTLSStream, here). Nothing
// blocks: pump() moves whatever bytes can move, and the event loop waits on
// `waitFD` for `waitEvents`.

enum BrowserStreamState: Equatable {
    /// Resolving, connecting or handshaking.
    case connecting
    case open
    /// The peer finished sending (data already received can still be read).
    case closed
    case failed(BrowserLoadError)
}

/// The base stream: already failed. Subclasses override everything.
class BrowserStream {
    init() {}
    var state: BrowserStreamState { .failed(.connectionFailed("no stream")) }
    /// Move bytes without blocking.
    func pump(now: Int) {}
    /// Queue bytes to send.
    func send(_ bytes: [UInt8]) {}
    /// Bytes received so far (and clears them).
    func receive() -> [UInt8] { [] }
    /// Received bytes ready without waiting for the fd.
    var hasBufferedInput: Bool { false }
    func close() {}
    var waitFD: Int { -1 }
    var waitEvents: Int16 { 0 }
    /// True while progress needs polling on a timer, not an fd (DNS).
    var needsTimer: Bool { false }
}

/// TLS 1.3 (lib/tls) over another stream.
final class BrowserTLSStream: BrowserStream {
    let raw: BrowserStream
    let tls: TLSClient
    private var started = false
    private var failure: BrowserLoadError? = nil

    init(raw: BrowserStream, config: TLSClientConfig, random: @escaping (Int) -> [UInt8]) {
        self.raw = raw
        tls = TLSClient(config: config, random: random)
        super.init()
    }

    override var state: BrowserStreamState {
        if let f = failure { return .failed(f) }
        switch tls.state {
        case .idle, .handshaking: return .connecting
        case .connected: return tls.peerClosed ? .closed : .open
        case .closed: return .closed
        case .failed: return .failed(.tls(tls.error.map { $0.description } ?? "TLS: handshake failed"))
        }
    }

    override func pump(now: Int) {
        if failure != nil { return }
        raw.pump(now: now)
        switch raw.state {
        case .connecting: return
        case .failed(let e):
            if tls.state == .connected { tls.transportClosed() } else { failure = e }
            return
        default: break
        }
        if !started {
            started = true
            tls.start()
        }
        let input = raw.receive()
        if !input.isEmpty { tls.feed(input) }
        if raw.state == .closed { tls.transportClosed() }
        flush(now)
    }

    private func flush(_ now: Int) {
        if tls.hasOutput {
            raw.send(tls.takeOutput())
            raw.pump(now: now)
        }
    }

    override func send(_ bytes: [UInt8]) {
        _ = tls.write(bytes)
        if tls.state == .connected && tls.hasOutput { raw.send(tls.takeOutput()) }
    }

    override func receive() -> [UInt8] { tls.read() }
    override var hasBufferedInput: Bool { tls.hasData }

    override func close() {
        if tls.state == .connected {
            tls.close()
            if tls.hasOutput { raw.send(tls.takeOutput()) }
            raw.pump(now: 0)
        }
        raw.close()
    }

    override var waitFD: Int { raw.waitFD }
    override var waitEvents: Int16 { raw.waitEvents }
    override var needsTimer: Bool { raw.needsTimer }
}
