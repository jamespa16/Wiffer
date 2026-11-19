// /bin/browse: a non-blocking TCP connection as a BrowserStream (lib/browser
// stream.swift): non-blocking DNS (the kernel resolver, polled), a
// non-blocking connect, then reads and writes that never wait. TLS goes on
// top as BrowserTLSStream. The HTTP transport pumps every stream after each
// `wait`, which covers the socket fds (WaitFD) and, while DNS is pending, a
// short timer (`needsTimer`).

/// --resolve name:ip overrides (tests: a certificate for "localhost" served
/// from the host at 10.0.2.2).
var browseResolveOverrides: [(name: String, ip: UInt32)] = []

final class BrowseSocketStream: BrowserStream {
    private enum Phase { case resolving, connecting, open, closed, failed }
    private var phase = Phase.resolving
    private var failure = BrowserLoadError.connectionFailed("")
    let host: String
    let port: UInt16
    private var sock: Socket? = nil
    private var out: [UInt8] = []
    private var inbox: [UInt8] = []

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        super.init()
    }

    override var state: BrowserStreamState {
        switch phase {
        case .resolving, .connecting: return .connecting
        case .open: return .open
        case .closed: return inbox.isEmpty ? .closed : .open
        case .failed: return .failed(failure)
        }
    }

    private func fail(_ e: BrowserLoadError) {
        failure = e
        phase = .failed
        if let s = sock { _ = s.close(); sock = nil }
    }

    private func socketError(_ errno: Int) -> BrowserLoadError {
        switch errno {
        case NetErrno.ECONNREFUSED: return .connectionRefused(host)
        case NetErrno.ETIMEDOUT: return .timedOut(host)
        default: return .connectionFailed(host + ": " + netErrnoMessage(errno))
        }
    }

    override func pump(now: Int) {
        if phase == .resolving {
            do throws(SysError) {
                var addr: UInt32? = nil
                for o in browseResolveOverrides where o.name == host { addr = o.ip }
                if addr == nil { addr = try DNS.resolve(host, nonBlocking: true).addresses.first }
                guard let ip = addr else { fail(.dnsFailure(host)); return }
                let s = try Socket.tcp(nonBlocking: true)
                sock = s
                phase = try s.connectStart(ip, port) ? .open : .connecting
            } catch {
                if error.errno == Errno.EAGAIN { return }
                if sock == nil { fail(.dnsFailure(host)) } else { fail(socketError(error.errno)) }
                return
            }
        }
        guard let s = sock else { return }
        if phase == .connecting {
            let e = s.pendingError
            if e != 0 { fail(socketError(e)); return }
            if !s.isConnected { return }
            phase = .open
        }
        if phase != .open { return }
        while !out.isEmpty {
            let n = s.send(out)
            if n > 0 { out.removeFirst(n); continue }
            if n == -Errno.EAGAIN || n == 0 { break }
            fail(socketError(-n))
            return
        }
        var rounds = 0
        while rounds < 64 {
            rounds += 1
            do throws(SysError) {
                let d = try s.receive(max: 65536)
                if d.isEmpty { phase = .closed; return }
                inbox += d
            } catch {
                if error.errno != Errno.EAGAIN {
                    if error.errno == NetErrno.ECONNRESET && !inbox.isEmpty { phase = .closed } else { fail(socketError(error.errno)) }
                }
                return
            }
        }
    }

    override func send(_ bytes: [UInt8]) { out += bytes }

    override func receive() -> [UInt8] {
        let d = inbox
        inbox = []
        return d
    }

    override var hasBufferedInput: Bool { !inbox.isEmpty }

    override func close() {
        if let s = sock { _ = s.close(); sock = nil }
        if phase != .failed { phase = .closed }
        inbox = []
    }

    override var waitFD: Int { sock?.fd ?? -1 }

    override var waitEvents: Int16 {
        switch phase {
        case .connecting: return WaitEvent.writable
        case .open: return WaitEvent.readable | (out.isEmpty ? 0 : WaitEvent.writable)
        default: return 0
        }
    }

    override var needsTimer: Bool { phase == .resolving }
}
