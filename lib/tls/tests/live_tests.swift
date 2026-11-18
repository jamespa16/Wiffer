// Live handshakes with a local `openssl s_server` (OpenSSL 3 or later),
// on 127.0.0.1 only. Skipped with a note if openssl isn't available.
// Each case starts `s_server -naccept 1 -www` on a free port with a leaf
// from tests/certs/, restricted to one cipher suite and/or group, sends
// "GET / HTTP/1.0" and checks the "HTTP/1.0 200 ok" status page.

final class TLSLiveRandom {
    var drbg: ChaChaDRBG
    init(seed: UInt64) {
        var r = TestRandom(seed: seed)
        var s: [UInt8] = []
        for _ in 0..<4 { let v = r.next(); for i in 0..<8 { s.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
        drbg = ChaChaDRBG(seed: s)
    }
    func next(_ n: Int) -> [UInt8] { drbg.generate(n) }
}

struct TLSLiveServer {
    var pipe: UnsafeMutablePointer<FILE>? = nil
    var port = 0

    /// Start s_server; nil if it doesn't report a port.
    static func start(_ args: String) -> TLSLiveServer? {
        let cmd = "openssl s_server -accept 0 -naccept 1 -www -tls1_3 \(args) 2>&1"
        guard let p = host_popen(cmd) else { return nil }
        var s = TLSLiveServer()
        s.pipe = p
        var line = [CChar](repeating: 0, count: 512)
        for _ in 0..<20 {
            guard fgets(&line, 512, p) != nil else { break }
            let text = String(cString: line)
            if text.hasPrefix("ACCEPT") {
                var digits = 0, scale = 1
                for c in text.utf8.reversed() {
                    if c == 0x0a || c == 0x0d { continue }
                    guard c >= 0x30 && c <= 0x39 else { break }
                    digits += Int(c - 0x30) * scale; scale *= 10
                }
                s.port = digits
                return s.port > 0 ? s : nil
            }
        }
        _ = host_pclose(p)
        return nil
    }

    func finish() { if let p = pipe { _ = host_pclose(p) } }
}

struct TLSLiveResult {
    var response: [UInt8] = []
    var client: TLSClient
}

/// Drive a TLSClient over a socket until it closes or fails.
func tlsLiveRun(port: Int, config: TLSClientConfig, seed: UInt64) -> TLSLiveResult? {
    let fd = host_tcp_connect(Int32(port))
    guard fd >= 0 else { return nil }
    defer { host_close(fd) }
    let rnd = TLSLiveRandom(seed: seed)
    let c = TLSClient(config: config, random: { rnd.next($0) })
    var res = TLSLiveResult(client: c)
    c.start()
    c.write(Array("GET / HTTP/1.0\r\n\r\n".utf8))
    var buf = [UInt8](repeating: 0, count: 16384)
    for _ in 0..<2000 {
        let out = c.takeOutput()
        if !out.isEmpty {
            let sent = out.withUnsafeBytes { host_send(fd, $0.baseAddress, out.count) }
            if sent < 0 { break }
        }
        if c.state == .failed || c.state == .closed { break }
        let n = buf.withUnsafeMutableBytes { host_recv(fd, $0.baseAddress, 16384) }
        if n <= 0 { c.transportClosed(); res.response += c.read(); break }
        c.feed(Array(buf[0..<Int(n)]))
        res.response += c.read()
    }
    let out = c.takeOutput()
    if !out.isEmpty { _ = out.withUnsafeBytes { host_send(fd, $0.baseAddress, out.count) } }
    return res
}

func tlsLiveTests(_ t: Tests) {
    t.section("live s_server")
    guard host_system("openssl version 2>/dev/null | grep -Eq '^OpenSSL ([3-9]|[1-9][0-9])'") == 0 else {
        print("  note: OpenSSL 3+ `openssl` not found; skipping the live s_server handshakes")
        return
    }
    guard let rootsDER = t.readFile("tests/certs/roots.der") else { return }
    let roots = X509TrustStore(concatenatedDER: rootsDER)
    let d = "tests/certs/"
    let ec = "-cert \(d)leaf-ec.chain.pem -cert_chain \(d)int-ec.pem -key \(d)leaf-ec.key.pem"
    let rsa = "-cert \(d)leaf-rsa.chain.pem -cert_chain \(d)int-rsa.pem -key \(d)leaf-rsa.key.pem"
    struct Case { let name: String; let args: String; let suite: UInt16; let group: UInt16; let hrr: Bool; let scheme: UInt16 }
    let cases = [
        Case(name: "EC, AES-128-GCM", args: "\(ec) -ciphersuites TLS_AES_128_GCM_SHA256", suite: 0x1301, group: TLSConst.x25519, hrr: false, scheme: TLSConst.ecdsaSecp256r1SHA256),
        Case(name: "EC, AES-256-GCM", args: "\(ec) -ciphersuites TLS_AES_256_GCM_SHA384", suite: 0x1302, group: TLSConst.x25519, hrr: false, scheme: TLSConst.ecdsaSecp256r1SHA256),
        Case(name: "EC, ChaCha20-Poly1305", args: "\(ec) -ciphersuites TLS_CHACHA20_POLY1305_SHA256", suite: 0x1303, group: TLSConst.x25519, hrr: false, scheme: TLSConst.ecdsaSecp256r1SHA256),
        Case(name: "RSA, AES-128-GCM", args: "\(rsa) -ciphersuites TLS_AES_128_GCM_SHA256", suite: 0x1301, group: TLSConst.x25519, hrr: false, scheme: TLSConst.rsaPSSRSAESHA256),
        Case(name: "RSA, AES-256-GCM", args: "\(rsa) -ciphersuites TLS_AES_256_GCM_SHA384", suite: 0x1302, group: TLSConst.x25519, hrr: false, scheme: TLSConst.rsaPSSRSAESHA256),
        Case(name: "RSA, ChaCha20-Poly1305", args: "\(rsa) -ciphersuites TLS_CHACHA20_POLY1305_SHA256", suite: 0x1303, group: TLSConst.x25519, hrr: false, scheme: TLSConst.rsaPSSRSAESHA256),
        Case(name: "EC, HelloRetryRequest to P-256", args: "\(ec) -groups P-256", suite: 0x1303, group: TLSConst.secp256r1, hrr: true, scheme: TLSConst.ecdsaSecp256r1SHA256),
        Case(name: "RSA, HelloRetryRequest to P-384", args: "\(rsa) -groups P-384 -ciphersuites TLS_AES_256_GCM_SHA384", suite: 0x1302, group: TLSConst.secp384r1, hrr: true, scheme: TLSConst.rsaPSSRSAESHA256),
    ]
    var seed: UInt64 = 1
    var passed = 0
    for cs in cases {
        seed += 1
        guard let srv = TLSLiveServer.start("\(cs.args) -alpn http/1.1") else {
            t.check(false, "\(cs.name): start s_server"); continue
        }
        let cfg = TLSClientConfig(serverName: "localhost", trust: .roots(roots), now: tlsTestNow)
        let r = tlsLiveRun(port: srv.port, config: cfg, seed: seed)
        srv.finish()
        guard let res = r else { t.check(false, "\(cs.name): connect"); continue }
        let c = res.client
        let text = String(decoding: res.response.prefix(15), as: UTF8.self)
        let ok = c.error == nil && text == "HTTP/1.0 200 ok"
        t.check(ok, "\(cs.name): handshake and GET", "\(c.error?.description ?? "response \"\(text)\"")")
        t.check(c.cipherSuite == cs.suite, "\(cs.name): cipher suite")
        t.check(c.keyExchangeGroup == cs.group && c.didHelloRetry == cs.hrr, "\(cs.name): group / HRR")
        t.check(c.signatureScheme == cs.scheme, "\(cs.name): signature scheme")
        t.check(c.alpnProtocol == "http/1.1", "\(cs.name): ALPN")
        t.check(c.peerCertificates.count == 3, "\(cs.name): validated path leaf..root")
        if ok { passed += 1 }
    }
    // Refusals over the wire: wrong name, and a server sending the expired leaf.
    if let srv = TLSLiveServer.start(ec) {
        let cfg = TLSClientConfig(serverName: "wrong.example", trust: .roots(roots), now: tlsTestNow)
        let r = tlsLiveRun(port: srv.port, config: cfg, seed: 77)
        srv.finish()
        t.check(r?.client.error == .certificate(.hostnameMismatch), "wrong host refused", r?.client.error?.description ?? "no error")
    }
    if let srv = TLSLiveServer.start("\(ec) -ciphersuites TLS_AES_128_GCM_SHA256") {
        var cfg = TLSClientConfig(serverName: "localhost", trust: .roots(roots), now: tlsTestNow)
        cfg.now = asn1UnixTime(year: 2040, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        let r = tlsLiveRun(port: srv.port, config: cfg, seed: 78)
        srv.finish()
        t.check(r?.client.error == .certificate(.expired), "expired chain refused", r?.client.error?.description ?? "no error")
    }
    print("  live s_server: \(passed)/\(cases.count) handshakes + GET ok")
}
