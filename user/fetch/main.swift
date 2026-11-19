// /bin/fetch [options] <url>: HTTP and HTTPS GET; the body goes to stdout
// (or a file). Follows redirects (up to 10), undoes gzip/deflate, checks
// certificates against /etc/roots.der with the RTC's time.
//
//   -o <file>          write the body to <file> ("-": stdout)
//   -q                 discard the body (with -v: just count and hash it)
//   -v                 status line, headers and a summary on stderr
//                      ("fetch: 200 OK, N bytes, fnv1a H, T ms, R KiB/s")
//   -k                 don't check the server's certificate (testing)
//   --ca <file>        trust the CA certificates in <file> (concatenated
//                      DER) instead of /etc/roots.der
//   --dns <ip[:port]>  resolve names with this DNS server
//   --resolve <name>:<ip>   connect to <ip> for <name> (any port), as
//                      curl's --resolve; TLS still checks <name>
//   --max-redirs <n>   (default 10)
//
// The work is lib/fetch's FetchExchange (I/O-free) driven over a
// non-blocking socket with wait(), the way the browser's event loop does.

var outPath: String? = nil
var quiet = false
var verbose = false
var insecure = false
var caPath = "/etc/roots.der"
var dnsServer: UInt32 = 0
var dnsPort: UInt16 = 53
var overrides: [(String, UInt32)] = []
var maxRedirects = 10
var target: String? = nil

func usage() -> Never {
    File.stderr.write("usage: fetch [-o file] [-q] [-v] [-k] [--ca file] [--dns ip[:port]] [--resolve name:ip] <url>\n")
    Process.exit(2)
}

func fail(_ message: String) -> Never {
    File.stderr.write("fetch: " + message + "\n")
    Process.exit(1)
}

let argv = Process.args
var i = 1
while i < argv.count {
    let a = argv[i]
    func value() -> String {
        guard i + 1 < argv.count else { usage() }
        i += 1
        return argv[i]
    }
    switch a {
    case "-o": outPath = value()
    case "-q": quiet = true
    case "-v": verbose = true
    case "-k": insecure = true
    case "--ca": caPath = value()
    case "--dns":
        let v = value()
        let parts = v.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let ip = IPv4.parse(String(parts[0])) else { fail("bad --dns server '\(v)'") }
        dnsServer = ip
        if parts.count == 2 {
            guard let p = Int(String(parts[1])), p > 0, p < 65536 else { fail("bad --dns port '\(v)'") }
            dnsPort = UInt16(p)
        }
    case "--resolve":
        let v = value()
        guard let colon = v.lastIndex(of: ":"), let ip = IPv4.parse(String(v[v.index(after: colon)...])) else {
            fail("bad --resolve '\(v)' (want name:ip)")
        }
        overrides.append((String(v[..<colon]).lowercased(), ip))
    case "--max-redirs":
        guard let n = Int(value()), n >= 0, n <= 50 else { usage() }
        maxRedirects = n
    default:
        if a.hasPrefix("-") || target != nil { usage() }
        target = a
    }
    i += 1
}
guard let target else { usage() }
guard var url = URLRecord.parseOrNil(target) else { fail("\(target): not a valid URL") }

// MARK: Output

var outFile: File? = nil
if let p = outPath, p != "-", !quiet {
    do throws(SysError) {
        outFile = try File.open(p, flags: OpenFlags.write | OpenFlags.create | OpenFlags.truncate)
    } catch {
        fail("\(p): \(error.message)")
    }
}
var bodyBytes = 0
var bodyHash: UInt64 = 0xcbf2_9ce4_8422_2325

func emit(_ data: [UInt8]) {
    bodyBytes += data.count
    for b in data { bodyHash = (bodyHash ^ UInt64(b)) &* 0x100_0000_01b3 }
    if quiet { return }
    let r = (outFile ?? File.stdout).writeAll(data)
    if r < 0 { fail("writing the body: \(SysError(errno: -r).message)") }
}

func say(_ s: String) {
    if verbose { File.stderr.write(s + "\n") }
}

// MARK: Trust

var trustStore: X509TrustStore? = nil
func tlsConfig(_ host: String) -> TLSClientConfig {
    let now = Int64(Time.unixSeconds)
    if insecure { return TLSClientConfig(serverName: host, trust: .insecureAcceptAny, now: now) }
    if trustStore == nil {
        do throws(SysError) {
            let f = try File.open(caPath)
            let der = try f.readAll()
            f.close()
            trustStore = X509TrustStore(concatenatedDER: der)
        } catch {
            fail("\(caPath): \(error.message)")
        }
    }
    return TLSClientConfig(serverName: host, trust: .roots(trustStore!), now: now)
}

// MARK: One exchange

/// Where `host` is (an IPv4 literal, a --resolve entry, or DNS).
func address(_ ep: FetchEndpoint) -> UInt32 {
    if let ip = ep.ipv4 { return ip }
    let name = ep.host.lowercased()
    for (n, ip) in overrides where n == name { return ip }
    do throws(SysError) {
        let a = try DNS.resolve(ep.host, server: dnsServer, port: dnsPort)
        guard let ip = a.addresses.first else { fail("\(ep.host): no address") }
        return ip
    } catch {
        fail("\(ep.host): \(error.errno == Errno.ENOENT ? "host not found" : error.message)")
    }
}

enum Outcome {
    case done(HTTPResponseHead)
    case redirect(URLRecord, HTTPResponseHead)
}

func exchange(_ url: URLRecord, redirects: Int) -> Outcome {
    guard let ep = fetchEndpoint(url) else { fail("\(url.href): only http and https URLs are supported") }
    let ip = address(ep)
    say("* connecting to \(IPv4.string(ip)):\(ep.port)" + (ep.tls ? " (TLS, server name \(ep.host))" : ""))
    let s: Socket
    do throws(SysError) {
        s = try Socket.tcp(nonBlocking: true)
        if !(try s.connectStart(ip, ep.port)) {
            var fds = [WaitFD(socket: s, events: WaitEvent.writable)]
            if wait(&fds, timeoutMs: 30000) <= 0 { fail("\(ep.host):\(ep.port): connect timed out") }
            if s.pendingError != 0 { throw SysError(errno: s.pendingError) }
        }
    } catch {
        fail("\(ep.host):\(ep.port): \(error.message)")
    }
    defer { s.close() }

    let ex = FetchExchange(url: url, tls: ep.tls ? tlsConfig(ep.host) : nil, random: { Random.bytes($0) })
    ex.start()
    var pending = ex.takeOutput()
    var head: HTTPResponseHead? = nil
    var redirect: URLRecord? = nil
    var finished = false
    var buffer = [UInt8](repeating: 0, count: 65536)
    while !finished {
        var fds = [WaitFD(socket: s, events: WaitEvent.readable | (pending.isEmpty ? 0 : WaitEvent.writable))]
        let n = wait(&fds, timeoutMs: 30000)
        if n == 0 { fail("\(url.href): timed out") }
        if n < 0 { fail("wait: \(SysError(errno: -n).message)") }
        let rev = fds[0].revents
        if rev & WaitEvent.writable != 0 && !pending.isEmpty {
            let sent = s.send(pending)
            if sent > 0 {
                pending.removeFirst(sent)
            } else if sent < 0 && sent != -Errno.EAGAIN {
                fail("\(url.href): send: \(SysError(errno: -sent).message)")
            }
        }
        var events: [FetchEvent] = []
        if rev & (WaitEvent.readable | WaitEvent.hangup) != 0 {
            let got = buffer.withUnsafeMutableBytes { s.receive(into: $0) }
            if got > 0 {
                events = ex.receive(Array(buffer[0..<got]))
            } else if got == 0 {
                events = ex.receiveEOF()
            } else if got != -Errno.EAGAIN {
                fail("\(url.href): \(SysError(errno: -got).message)")
            }
        }
        for e in events {
            switch e {
            case .head(let h):
                head = h
                say("< HTTP/1.\(h.minorVersion) \(h.status) " + String(decoding: h.reason, as: UTF8.self))
                for hd in h.headers {
                    say("< " + String(decoding: hd.name, as: UTF8.self) + ": " + String(decoding: hd.value, as: UTF8.self))
                }
                switch fetchRedirect(h, method: "GET", url: url, redirectsSoFar: redirects) {
                case .follow(_, let next, _, _): redirect = next
                case .tooMany: fail("\(url.href): too many redirects")
                case .invalid: fail("\(url.href): bad redirect Location")
                case .notRedirect: break
                }
            case .body(let d):
                if redirect == nil { emit(d) }
            case .complete:
                finished = true
            case .failed(let why):
                fail("\(url.href): \(why)")
            }
        }
        pending += ex.takeOutput()
        if ex.done && !finished { finished = true }
    }
    if ex.transport.isTLS {
        ex.transport.close()
        _ = s.send(ex.takeOutput())
    }
    guard let h = head else { fail("\(url.href): no response") }
    if let r = redirect { return .redirect(r, h) }
    return .done(h)
}

// MARK: Main

let start = Time.now
var redirects = 0
while true {
    switch exchange(url, redirects: redirects) {
    case .redirect(let next, let h):
        say("* \(h.status) redirect to \(next.href)")
        redirects += 1
        if redirects > maxRedirects { fail("too many redirects") }
        url = next
        continue
    case .done(let h):
        outFile?.close()
        let ms = max(Time.now - start, 1)
        var hex = ""
        let digits = Array("0123456789abcdef".utf8)
        for k in 0..<16 { hex.append(Character(Unicode.Scalar(digits[Int((bodyHash >> UInt64(60 - 4 * k)) & 15)]))) }
        say("fetch: \(h.status) " + String(decoding: h.reason, as: UTF8.self)
            + ", \(bodyBytes) bytes, fnv1a \(hex), \(ms) ms, \(bodyBytes * 1000 / 1024 / ms) KiB/s")
        Process.exit(h.status >= 400 ? 3 : 0)
    }
}
