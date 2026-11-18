// Host tests for lib/tls: RFC 8448 sections 3 (simple 1-RTT) and 5
// (HelloRetryRequest) replayed byte for byte, protocol error paths,
// KeyUpdate, fuzzing of the record and handshake parsers with mutated
// server flights, and (live_tests.swift) handshakes with a local
// `openssl s_server` using the test PKI in tests/certs/.

func libTests(_ t: Tests) {
    guard let fx = RFC8448(t) else { return }
    rfc8448Simple(t, fx)
    rfc8448HelloRetry(t, fx)
    tlsErrorTests(t, fx)
    tlsKeyUpdateTests(t, fx)
    tlsFuzzTests(t, fx)
    tlsLiveTests(t)
}

let tlsTestNow = asn1UnixTime(year: 2026, month: 11, day: 18, hour: 12, minute: 0, second: 0)

/// The values of lib/tls/fixtures/rfc8448.txt (gen_rfc8448.py).
struct RFC8448 {
    var values: [(String, [UInt8])] = []

    init?(_ t: Tests) {
        guard let data = t.readFile("lib/tls/fixtures/rfc8448.txt") else { return nil }
        var line: [UInt8] = []
        for b in data + [0x0a] {
            if b != 0x0a { line.append(b); continue }
            if let sp = line.firstIndex(of: 0x20), line.first != 0x23 {
                values.append((String(decoding: line[..<sp], as: UTF8.self),
                               unhex(String(decoding: line[(sp + 1)...], as: UTF8.self))))
            }
            line = []
        }
    }

    func get(_ k: String) -> [UInt8] {
        for (n, v) in values where n == k { return v }
        print("FAIL tls: missing RFC 8448 value \(k)")
        return []
    }
}

/// A random source that hands out fixed chunks, then zeros.
final class TLSFixedRandom {
    var chunks: [[UInt8]]
    var calls: [Int] = []
    init(_ c: [[UInt8]]) { chunks = c }
    func next(_ n: Int) -> [UInt8] {
        calls.append(n)
        if chunks.isEmpty { return [UInt8](repeating: 0, count: n) }
        return chunks.removeFirst()
    }
}

/// The ClientHello options of the RFC 8448 client (an NSS build).
func rfc8448Config(_ fx: RFC8448, groups: [UInt16], ticket: Bool) -> TLSClientConfig {
    // The server's certificate: from the Certificate message in section 3.
    let certMsg = fx.get("s3.server.construct_a_certificate_handshake_message.certificate")
    var leaf: [UInt8] = []
    if certMsg.count > 11 {
        let n = Int(certMsg[8]) << 16 | Int(certMsg[9]) << 8 | Int(certMsg[10])
        if 11 + n <= certMsg.count { leaf = Array(certMsg[11..<(11 + n)]) }
    }
    var c = TLSClientConfig(serverName: "server", trust: .pinned(leaf), now: tlsTestNow)
    c.alpn = []
    c.cipherSuites = [0x1301, 0x1303, 0x1302]
    c.supportedGroups = groups
    c.keyShareGroups = [TLSConst.x25519]
    c.signatureAlgorithms = [0x0403, 0x0503, 0x0603, 0x0203, 0x0804, 0x0805, 0x0806,
                             0x0401, 0x0501, 0x0601, 0x0201, 0x0402, 0x0502, 0x0602, 0x0202]
    c.middleboxCompatibility = false
    c.sendRenegotiationInfo = true
    c.sendSessionTicket = ticket
    c.sendPSKModes = true
    c.recordSizeLimit = 0x4001
    return c
}

let rfc8448Groups3: [UInt16] = [0x001d, 0x0017, 0x0018, 0x0019, 0x0100, 0x0101, 0x0102, 0x0103, 0x0104]

/// A client at the start of RFC 8448 section 3, ClientHello taken.
func rfc8448Client(_ fx: RFC8448) -> TLSClient {
    let ch = fx.get("s3.client.construct_a_clienthello_handshake_message.clienthello")
    let rnd = TLSFixedRandom([Array(ch.count >= 38 ? ch[6..<38] : []),
                              fx.get("s3.client.create_an_ephemeral_x25519_key_pair.private_key")])
    let c = TLSClient(config: rfc8448Config(fx, groups: rfc8448Groups3, ticket: true), random: { rnd.next($0) })
    c.start()
    _ = c.takeOutput()
    return c
}

func rfc8448Simple(_ t: Tests, _ fx: RFC8448) {
    t.section("RFC 8448 1-RTT")
    let ch = fx.get("s3.client.construct_a_clienthello_handshake_message.clienthello")
    let rnd = TLSFixedRandom([Array(ch.count >= 38 ? ch[6..<38] : []),
                              fx.get("s3.client.create_an_ephemeral_x25519_key_pair.private_key")])
    let c = TLSClient(config: rfc8448Config(fx, groups: rfc8448Groups3, ticket: true), random: { rnd.next($0) })
    c.start()
    t.equal(c.takeOutput(), fx.get("s3.client.send_handshake_record.complete_record"), "ClientHello record")
    t.check(rnd.calls == [32, 32], "randomness: client random and x25519 key only", "\(rnd.calls)")

    c.feed(fx.get("s3.server.send_handshake_record.complete_record"))
    t.check(c.state == .handshaking && c.takeOutput().isEmpty, "ServerHello accepted", "\(c.error?.description ?? "")")
    t.equal(c.secrets.sharedSecret, fx.get("s3.server.extract_secret_handshake.ikm"), "ECDHE shared secret")
    t.equal(c.secrets.earlySecret, fx.get("s3.server.extract_secret_early.secret"), "early secret")
    t.equal(c.secrets.handshakeSecret, fx.get("s3.server.extract_secret_handshake.secret"), "handshake secret")
    t.equal(c.secrets.clientHandshakeTraffic, fx.get("s3.server.derive_secret_tls13_c_hs_traffic.expanded"), "c hs traffic")
    t.equal(c.secrets.serverHandshakeTraffic, fx.get("s3.server.derive_secret_tls13_s_hs_traffic.expanded"), "s hs traffic")
    t.equal(c.secrets.masterSecret, fx.get("s3.server.extract_secret_master.secret"), "master secret")

    c.feed(fx.get("s3.server.send_handshake_record.complete_record.1"))
    t.check(c.state == .connected, "server flight accepted", c.error?.description ?? "")
    t.equal(c.secrets.clientApplicationTraffic, fx.get("s3.server.derive_secret_tls13_c_ap_traffic.expanded"), "c ap traffic")
    t.equal(c.secrets.serverApplicationTraffic, fx.get("s3.server.derive_secret_tls13_s_ap_traffic.expanded"), "s ap traffic")
    t.equal(c.takeOutput(), fx.get("s3.client.send_handshake_record.complete_record.1"), "client Finished record")
    t.check(c.signatureScheme == TLSConst.rsaPSSRSAESHA256, "rsa_pss_rsae_sha256 CertificateVerify")
    t.check(c.cipherSuite == TLSConst.aes128GCMSHA256 && c.keyExchangeGroup == TLSConst.x25519, "suite and group")
    t.equal(c.peerCertificates.first?.subject.commonName ?? "", "rsa", "server certificate")

    c.feed(fx.get("s3.server.send_handshake_record.complete_record.2"))
    t.check(c.state == .connected && c.takeOutput().isEmpty, "NewSessionTicket ignored")
    let payload = fx.get("s3.client.send_application_data_record.payload")
    t.check(c.write(payload), "write")
    t.equal(c.takeOutput(), fx.get("s3.client.send_application_data_record.complete_record"), "client application data record")
    c.feed(fx.get("s3.server.send_application_data_record.complete_record"))
    t.equal(c.read(), fx.get("s3.server.send_application_data_record.payload"), "server application data")
    c.close()
    t.equal(c.takeOutput(), fx.get("s3.client.send_alert_record.complete_record"), "client close_notify record")
    c.feed(fx.get("s3.server.send_alert_record.complete_record"))
    t.check(c.state == .closed && c.peerClosed && c.error == nil, "server close_notify")
    t.check(!c.write([1]), "no writes after close")

    // The whole server side in one feed, and one byte at a time.
    for chunk in [100000, 1, 7] {
        let d = rfc8448Client(fx)
        let all = fx.get("s3.server.send_handshake_record.complete_record") + fx.get("s3.server.send_handshake_record.complete_record.1")
            + fx.get("s3.server.send_handshake_record.complete_record.2") + fx.get("s3.server.send_application_data_record.complete_record")
        var i = 0
        while i < all.count { d.feed(Array(all[i..<min(all.count, i + chunk)])); i += chunk }
        t.check(d.state == .connected, "fed in \(chunk)-byte chunks", d.error?.description ?? "")
        t.equal(d.takeOutput(), fx.get("s3.client.send_handshake_record.complete_record.1"), "Finished (\(chunk)-byte chunks)")
        t.equal(d.read(), fx.get("s3.server.send_application_data_record.payload"), "data (\(chunk)-byte chunks)")
    }
}

func rfc8448HelloRetry(_ t: Tests, _ fx: RFC8448) {
    t.section("RFC 8448 HelloRetryRequest")
    let ch = fx.get("s5.client.construct_a_clienthello_handshake_message.clienthello")
    let rnd = TLSFixedRandom([Array(ch.count >= 38 ? ch[6..<38] : []),
                              fx.get("s5.client.create_an_ephemeral_x25519_key_pair.private_key"),
                              fx.get("s5.client.create_an_ephemeral_p_256_key_pair.private_key")])
    let c = TLSClient(config: rfc8448Config(fx, groups: [0x001d, 0x0017, 0x0018], ticket: false), random: { rnd.next($0) })
    c.start()
    t.equal(c.takeOutput(), fx.get("s5.client.send_handshake_record.complete_record"), "ClientHello 1")
    c.feed(fx.get("s5.server.send_handshake_record.complete_record"))
    t.check(c.didHelloRetry && c.state == .handshaking, "HelloRetryRequest accepted", c.error?.description ?? "")
    t.equal(c.takeOutput(), fx.get("s5.client.send_handshake_record.complete_record.1"), "ClientHello 2 (P-256 share, cookie, padding)")
    c.feed(fx.get("s5.server.send_handshake_record.complete_record.1"))
    t.check(c.keyExchangeGroup == TLSConst.secp256r1, "P-256 ServerHello", c.error?.description ?? "")
    t.equal(c.secrets.handshakeSecret, fx.get("s5.server.extract_secret_handshake.secret"), "handshake secret")
    t.equal(c.secrets.clientHandshakeTraffic, fx.get("s5.server.derive_secret_tls13_c_hs_traffic.expanded"), "c hs traffic")
    c.feed(fx.get("s5.server.send_handshake_record.complete_record.2"))
    t.check(c.state == .connected, "server flight accepted", c.error?.description ?? "")
    t.equal(c.secrets.serverApplicationTraffic, fx.get("s5.server.derive_secret_tls13_s_ap_traffic.expanded"), "s ap traffic")
    t.equal(c.takeOutput(), fx.get("s5.client.send_handshake_record.complete_record.2"), "client Finished record")
    c.close()
    t.equal(c.takeOutput(), fx.get("s5.client.send_alert_record.complete_record"), "close_notify")
    c.feed(fx.get("s5.server.send_alert_record.complete_record"))
    t.check(c.state == .closed, "closed")
}

/// A "server" record layer writing with the RFC 8448 section 3 server
/// handshake keys, to send altered encrypted flights.
func rfc8448ServerWriter(_ fx: RFC8448) -> TLSRecordLayer {
    var w = TLSRecordLayer()
    w.writeState = TLSCipherSuite(TLSConst.aes128GCMSHA256)?.cipherState(
        secret: fx.get("s3.server.derive_secret_tls13_s_hs_traffic.expanded"))
    return w
}

/// The plaintext of the section 3 server flight (EE, Certificate, CV, Finished).
func rfc8448Flight(_ fx: RFC8448) -> [UInt8] { fx.get("s3.server.send_handshake_record.payload.1") }

func tlsExpectFailure(_ t: Tests, _ c: TLSClient, alert: UInt8?, _ label: String) {
    let detail = c.error?.description ?? "state \(c.state)"
    t.check(c.state == .failed && c.error?.alertSent == alert, label, detail)
}

func tlsErrorTests(_ t: Tests, _ fx: RFC8448) {
    t.section("TLS errors")
    let sh = fx.get("s3.server.send_handshake_record.complete_record")
    let flight = fx.get("s3.server.send_handshake_record.complete_record.1")

    var c = rfc8448Client(fx)
    c.feed([0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x28])
    t.check(c.state == .failed && c.error == .peerAlert(TLSAlert.handshakeFailure), "server alert reported")
    t.equal(c.error?.description ?? "", "TLS: server sent alert handshake_failure", "alert description")
    t.check(c.takeOutput().isEmpty, "no alert answers an alert")

    c = rfc8448Client(fx)
    c.transportClosed()
    t.check(c.error == .truncated, "EOF during the handshake")

    // A TLS 1.2 ServerHello (no supported_versions) with and without the
    // downgrade sentinel.
    func tls12Hello(_ sentinel: Bool) -> [UInt8] {
        var body: [UInt8] = [0x03, 0x03]
        var rand = [UInt8](repeating: 0x11, count: 32)
        if sentinel { rand.replaceSubrange(24..<32, with: TLSConst.downgradePrefix + [1]) }
        body += rand + [0, 0x13, 0x01, 0]
        let msg = tlsHandshakeMessage(TLSConst.serverHello, body)
        return [0x16, 0x03, 0x03, 0, UInt8(msg.count)] + msg
    }
    c = rfc8448Client(fx); c.feed(tls12Hello(false))
    tlsExpectFailure(t, c, alert: TLSAlert.protocolVersion, "TLS 1.2 server refused")
    t.equal(c.takeOutput(), [0x15, 0x03, 0x03, 0x00, 0x02, 0x02, TLSAlert.protocolVersion], "plaintext alert sent")
    c = rfc8448Client(fx); c.feed(tls12Hello(true))
    tlsExpectFailure(t, c, alert: TLSAlert.illegalParameter, "downgrade sentinel")

    // ServerHello alterations (plaintext): suite not offered, unsolicited
    // extension, wrong session id.
    func alteredHello(_ f: (inout [UInt8]) -> Void) -> [UInt8] { var s = sh; f(&s); return s }
    c = rfc8448Client(fx); c.feed(alteredHello { $0[5 + 4 + 2 + 32 + 1 + 1] = 0x05 })   // suite 0x1305
    tlsExpectFailure(t, c, alert: TLSAlert.illegalParameter, "cipher suite not offered")
    c = rfc8448Client(fx); c.feed(alteredHello { s in
        // supported_versions (00 2b) -> 00 2c (cookie): unexpected in a ServerHello
        if let i = tlsIndexOf(s, [0x00, 0x2b, 0x00, 0x02]) { s[i + 1] = 0x2c }
    })
    tlsExpectFailure(t, c, alert: TLSAlert.protocolVersion, "no supported_versions")
    c = rfc8448Client(fx); c.feed(alteredHello { s in
        if let i = tlsIndexOf(s, [0x00, 0x33, 0x00, 0x24]) { s[i + 1] = 0x34 }
    })
    tlsExpectFailure(t, c, alert: TLSAlert.unsupportedExtension, "unknown ServerHello extension")
    c = rfc8448Client(fx); c.feed(alteredHello { s in
        if let i = tlsIndexOf(s, [0x00, 0x1d, 0x00, 0x20]) { s[i + 1] = 0x17 }
    })
    tlsExpectFailure(t, c, alert: TLSAlert.illegalParameter, "key share for another group")

    // Encrypted record tampering.
    c = rfc8448Client(fx); c.feed(sh)
    var bad = flight; bad[bad.count - 1] ^= 1
    c.feed(bad)
    tlsExpectFailure(t, c, alert: TLSAlert.badRecordMAC, "tampered record")
    t.check(c.takeOutput().count == 5 + 2 + 1 + 16, "alert sent encrypted")

    // Altered plaintext flights, re-encrypted with the server's keys.
    let plain = rfc8448Flight(fx)
    func flightWith(_ f: (inout [UInt8]) -> Void) -> TLSClient {
        let d = rfc8448Client(fx)
        d.feed(sh)
        var p = plain; f(&p)
        var w = rfc8448ServerWriter(fx)
        d.feed(w.encode(TLSConst.handshake, p))
        return d
    }
    c = flightWith { $0[$0.count - 1] ^= 1 }
    tlsExpectFailure(t, c, alert: TLSAlert.decryptError, "bad server Finished")
    c = flightWith { p in if let i = tlsIndexOf(p, [0x0f, 0x00, 0x00, 0x84]) { p[i + 20] ^= 1 } }
    tlsExpectFailure(t, c, alert: TLSAlert.decryptError, "bad CertificateVerify signature")
    c = flightWith { p in if let i = tlsIndexOf(p, [0x0f, 0x00, 0x00, 0x84, 0x08, 0x04]) { p[i + 5] = 0x09 } }
    tlsExpectFailure(t, c, alert: TLSAlert.illegalParameter, "CertificateVerify scheme not offered")
    c = flightWith { p in if let i = tlsIndexOf(p, [0x00, 0x1c, 0x00, 0x02]) { p[i + 1] = 0x1e } }
    tlsExpectFailure(t, c, alert: TLSAlert.unsupportedExtension, "unsolicited EncryptedExtensions extension")
    c = flightWith { p in p = Array(p[40...]) }   // no EncryptedExtensions
    tlsExpectFailure(t, c, alert: TLSAlert.unexpectedMessage, "missing EncryptedExtensions")
    c = flightWith { p in p.insert(contentsOf: [0x14, 0x00, 0x00, 0x00], at: 0) }
    tlsExpectFailure(t, c, alert: TLSAlert.unexpectedMessage, "Finished out of order")
    c = flightWith { p in p[1] = 0x7f }   // EE length 8 MiB
    tlsExpectFailure(t, c, alert: TLSAlert.unexpectedMessage, "oversized handshake message")

    // Certificate checks with real validation: the RFC 8448 cert is
    // self-signed, so a root store without it says unknown_ca, and a pin
    // mismatch the same.
    var cfg = rfc8448Config(fx, groups: rfc8448Groups3, ticket: true)
    cfg.trust = .roots(X509TrustStore())
    let ch = fx.get("s3.client.construct_a_clienthello_handshake_message.clienthello")
    let rnd = TLSFixedRandom([Array(ch.count >= 38 ? ch[6..<38] : []),
                              fx.get("s3.client.create_an_ephemeral_x25519_key_pair.private_key")])
    c = TLSClient(config: cfg, random: { rnd.next($0) })
    c.start(); _ = c.takeOutput()
    c.feed(sh); c.feed(flight)
    t.check(c.error == .certificate(.untrustedRoot), "untrusted server certificate", c.error?.description ?? "")
    t.check(c.error?.alertSent == TLSAlert.unknownCA, "unknown_ca sent")

    // Plaintext application data and stray change_cipher_spec.
    c = rfc8448Client(fx); c.feed([0x17, 0x03, 0x03, 0x00, 0x01, 0x00])
    tlsExpectFailure(t, c, alert: TLSAlert.unexpectedMessage, "plaintext application data")
    c = rfc8448Client(fx); c.feed([0x14, 0x03, 0x03, 0x00, 0x01, 0x01])
    tlsExpectFailure(t, c, alert: TLSAlert.unexpectedMessage, "CCS before ServerHello")
    c = rfc8448Client(fx); c.feed(sh + [0x14, 0x03, 0x03, 0x00, 0x01, 0x01] + flight)
    t.check(c.state == .connected, "CCS after ServerHello ignored", c.error?.description ?? "")
    c = rfc8448Client(fx); c.feed([0x16, 0x03, 0x03, 0x40, 0x01] + [UInt8](repeating: 0, count: 0x4001))
    tlsExpectFailure(t, c, alert: TLSAlert.recordOverflow, "record too long")
    c = rfc8448Client(fx); c.feed([0x16, 0x03, 0x03, 0x00, 0x00])
    tlsExpectFailure(t, c, alert: TLSAlert.unexpectedMessage, "empty handshake record")
    c = rfc8448Client(fx); c.feed([0x47, 0x45, 0x54, 0x20, 0x2f, 0x20])
    tlsExpectFailure(t, c, alert: TLSAlert.unexpectedMessage, "not TLS")
}

func tlsIndexOf(_ a: [UInt8], _ needle: [UInt8]) -> Int? {
    guard a.count >= needle.count, !needle.isEmpty else { return nil }
    for i in 0...(a.count - needle.count) where Array(a[i..<(i + needle.count)]) == needle { return i }
    return nil
}

func tlsKeyUpdateTests(_ t: Tests, _ fx: RFC8448) {
    t.section("KeyUpdate")
    let c = rfc8448Client(fx)
    c.feed(fx.get("s3.server.send_handshake_record.complete_record") + fx.get("s3.server.send_handshake_record.complete_record.1"))
    _ = c.takeOutput()
    guard let suite = TLSCipherSuite(TLSConst.aes128GCMSHA256) else { return }
    let h = suite.hash
    var server = TLSRecordLayer()
    var sSecret = fx.get("s3.server.derive_secret_tls13_s_ap_traffic.expanded")
    var cSecret = fx.get("s3.server.derive_secret_tls13_c_ap_traffic.expanded")
    server.writeState = suite.cipherState(secret: sSecret)
    server.readState = suite.cipherState(secret: cSecret)
    // Server: KeyUpdate(update_requested), then data under the new key.
    c.feed(server.encode(TLSConst.handshake, tlsHandshakeMessage(TLSConst.keyUpdate, [1])))
    sSecret = h.expandLabel(sSecret, "traffic upd", [], 32)
    server.writeState = suite.cipherState(secret: sSecret)
    c.feed(server.encode(TLSConst.applicationData, Array("after update".utf8)))
    t.equal(String(decoding: c.read(), as: UTF8.self), "after update", "data under the updated server key")
    // The client answered with KeyUpdate(update_not_requested) under its old key...
    server.append(c.takeOutput())
    do throws(TLSError) {
        let rec = try server.next()
        t.check(rec?.type == TLSConst.handshake && rec?.payload == [TLSConst.keyUpdate, 0, 0, 1, 0], "client KeyUpdate response")
    } catch { t.check(false, "client KeyUpdate response", error.description) }
    // ...and writes under the new one.
    cSecret = h.expandLabel(cSecret, "traffic upd", [], 32)
    server.readState = suite.cipherState(secret: cSecret)
    c.write(Array("hello".utf8))
    server.append(c.takeOutput())
    do throws(TLSError) {
        let rec = try server.next()
        t.check(rec?.payload == Array("hello".utf8), "client data under its updated key")
    } catch { t.check(false, "client data under its updated key", error.description) }
    c.feed(server.encode(TLSConst.handshake, tlsHandshakeMessage(TLSConst.keyUpdate, [2])))
    tlsExpectFailure(t, c, alert: TLSAlert.illegalParameter, "bad KeyUpdate value")

    // Large writes are split into 2^14-byte records.
    let d = rfc8448Client(fx)
    d.feed(fx.get("s3.server.send_handshake_record.complete_record") + fx.get("s3.server.send_handshake_record.complete_record.1"))
    _ = d.takeOutput()
    d.write([UInt8](repeating: 0x61, count: 40000))
    let out = d.takeOutput()
    t.equal(out.count, 40000 + 3 * (5 + 1 + 16), "40000 bytes in three records")
}

func tlsFuzzTests(_ t: Tests, _ fx: RFC8448) {
    t.section("fuzz")
    let sh = fx.get("s3.server.send_handshake_record.complete_record")
    let rest = fx.get("s3.server.send_handshake_record.complete_record.1") + fx.get("s3.server.send_handshake_record.complete_record.2")
        + fx.get("s3.server.send_application_data_record.complete_record") + fx.get("s3.server.send_alert_record.complete_record")
    // 1. Raw server bytes (records, mostly failing at the MAC).
    t.fuzz("TLS records", seeds: [sh + rest, sh, fx.get("s5.server.send_handshake_record.complete_record")], iterations: 3000) { data in
        let c = rfc8448Client(fx)
        c.feed(data)
        _ = c.takeOutput(); _ = c.read()
    }
    // 2. The plaintext ServerHello message.
    let shMsg = Array(sh[5...])
    t.fuzz("ServerHello", seeds: [shMsg, fx.get("s5.server.send_handshake_record.payload")], iterations: 3000) { m in
        let c = rfc8448Client(fx)
        c.feed([0x16, 0x03, 0x03, UInt8(truncatingIfNeeded: m.count >> 8), UInt8(truncatingIfNeeded: m.count)] + m)
        _ = c.takeOutput()
    }
    // 3. The encrypted flight's plaintext (EE, Certificate, CertificateVerify,
    // Finished), mutated and re-encrypted so the parsers see it.
    let plain = rfc8448Flight(fx)
    var accepted = 0
    t.fuzz("server flight", seeds: [plain], iterations: 4000) { m in
        let c = rfc8448Client(fx)
        c.feed(sh)
        var w = rfc8448ServerWriter(fx)
        var off = 0
        while off < m.count || off == 0 {   // also split across records
            let n = min(m.count - off, 300)
            c.feed(w.encode(TLSConst.handshake, Array(m[off..<(off + n)])))
            off += max(n, 1)
            if m.isEmpty { break }
        }
        _ = c.takeOutput()
        if c.state == .connected && m != plain { accepted += 1 }
    }
    t.equal(accepted, 0, "no mutated flight is accepted")
}
