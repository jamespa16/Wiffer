// TLSClient: the TLS 1.3 client state machine (RFC 8446), I/O-free.
//
//   let c = TLSClient(config: cfg, random: { n in bytes })   // see tls.swift
//   c.start()                  ClientHello queued
//   c.feed(bytes)              process whatever the server sent (any split)
//   c.takeOutput() -> [UInt8]  bytes to send now (records)
//   c.write(data) -> Bool      application data (buffered until connected)
//   c.read() -> [UInt8]        decrypted application data received so far
//   c.close()                  send close_notify
//   c.transportClosed()        the TCP connection ended
//   c.state                    .idle / .handshaking / .connected / .closed / .failed
//   c.error                    TLSError when .failed
//   c.peerClosed               the server sent close_notify
//   c.alpnProtocol, c.cipherSuite, c.keyExchangeGroup, c.signatureScheme,
//   c.peerCertificates (validated path, leaf first), c.didHelloRetry,
//   c.secrets (TLSSecrets, for tests)
//
// `random(n)` must return n bytes from a CSPRNG (getrandom / ChaChaDRBG);
// it is called for the client random, the legacy_session_id and each key
// share's private key, in that order (tests inject fixed values).
//
// Every malformed or unexpected input ends the connection with the right
// alert; nothing traps. Handshake messages are capped at 64 KiB and the
// certificate list at 16 entries.

enum TLSClientState: Equatable {
    case idle, handshaking, connected, closed, failed
}

final class TLSClient {
    static let maxHandshakeMessage = 65536
    static let maxCertificates = 16

    enum Wait { case serverHello, encryptedExtensions, certificateOrRequest, certificate, certificateVerify, finished, done }

    let config: TLSClientConfig
    private let random: (Int) -> [UInt8]

    private(set) var state: TLSClientState = .idle
    private(set) var error: TLSError? = nil
    private(set) var peerClosed = false
    private(set) var alpnProtocol: String? = nil
    private(set) var cipherSuite: UInt16? = nil
    private(set) var keyExchangeGroup: UInt16? = nil
    private(set) var signatureScheme: UInt16? = nil
    private(set) var peerCertificates: [X509Certificate] = []
    private(set) var didHelloRetry = false
    private(set) var secrets = TLSSecrets()

    private var records = TLSRecordLayer()
    private var output: [UInt8] = []
    private var appIn: [UInt8] = []
    private var pendingWrites: [[UInt8]] = []
    private var sentClose = false

    private var wait = Wait.serverHello
    private var hsBuffer: [UInt8] = []
    private var transcript = TLSTranscript()
    private var suite: TLSCipherSuite? = nil
    private var clientRandom: [UInt8] = []
    private var sessionID: [UInt8] = []
    private var shares: [(group: UInt16, priv: [UInt8], pub: [UInt8])] = []
    private var cookie: [UInt8]? = nil
    private var sentCCS = false
    private var certificateRequestContext: [UInt8]? = nil
    private var leafKey: X509PublicKey? = nil
    private var serverRecordSizeLimit: Int? = nil
    private var clientAppSecret: [UInt8] = []
    private var serverAppSecret: [UInt8] = []

    init(config: TLSClientConfig, random: @escaping (Int) -> [UInt8]) {
        self.config = config
        self.random = random
    }

    var isConnected: Bool { state == .connected }

    // MARK: Caller API

    func start() {
        guard state == .idle else { return }
        state = .handshaking
        clientRandom = randomBytes(32)
        sessionID = config.middleboxCompatibility ? randomBytes(32) : []
        for g in config.keyShareGroups {
            guard let s = makeShare(g) else {
                return fail(.protocolError(alert: TLSAlert.internalError, reason: "can't make a key share for group \(g)"))
            }
            shares.append(s)
        }
        guard !shares.isEmpty else {
            return fail(.protocolError(alert: TLSAlert.internalError, reason: "no key share groups"))
        }
        sendHandshake(buildClientHello())
        records.plaintextVersion = 0x0303
    }

    func feed(_ bytes: [UInt8]) {
        guard state == .handshaking || state == .connected else { return }
        records.append(bytes)
        while state == .handshaking || state == .connected {
            do throws(TLSError) {
                guard let rec = try records.next() else { return }
                try handleRecord(rec)
            } catch {
                return fail(error)
            }
        }
    }

    func takeOutput() -> [UInt8] {
        let o = output
        output = []
        return o
    }

    var hasOutput: Bool { !output.isEmpty }

    /// Queue application data; false (and nothing queued) once closed or
    /// failed.
    @discardableResult
    func write(_ data: [UInt8]) -> Bool {
        guard !sentClose, state == .idle || state == .handshaking || state == .connected else { return false }
        if state == .connected {
            if !data.isEmpty { output += records.encode(TLSConst.applicationData, data) }
        } else {
            pendingWrites.append(data)
        }
        return true
    }

    /// Application data received so far (and clears it).
    func read() -> [UInt8] {
        let d = appIn
        appIn = []
        return d
    }

    var hasData: Bool { !appIn.isEmpty }

    /// Send close_notify. Data the server still sends can be read.
    func close() {
        guard !sentClose, state == .connected || state == .handshaking || state == .closed else { return }
        sentClose = true
        output += records.encode(TLSConst.alert, [1, TLSAlert.closeNotify])
        if peerClosed { state = .closed }
    }

    /// The transport reached EOF. During the handshake that is an error;
    /// afterwards the connection is closed (`peerClosed` tells whether the
    /// server said close_notify first, i.e. whether data may be truncated).
    func transportClosed() {
        switch state {
        case .idle, .handshaking: fail(.truncated, sendAlert: false)
        case .connected: state = .closed
        default: break
        }
    }

    // MARK: Records

    private func handleRecord(_ rec: TLSRecord) throws(TLSError) {
        switch rec.type {
        case TLSConst.changeCipherSpec:
            // Middlebox compatibility: one byte 0x01, only during the
            // handshake, never encrypted; otherwise unexpected.
            guard state == .handshaking, !rec.encrypted, rec.payload == [1], wait != .serverHello || didHelloRetry else {
                throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "unexpected change_cipher_spec")
            }
        case TLSConst.alert:
            guard rec.payload.count == 2 else {
                throw .protocolError(alert: TLSAlert.decodeError, reason: "bad alert record")
            }
            guard rec.encrypted || state == .handshaking else {
                throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "plaintext alert after the handshake")
            }
            let desc = rec.payload[1]
            if desc == TLSAlert.closeNotify {
                peerClosed = true
                if state == .handshaking { fail(.peerAlert(desc), sendAlert: false); return }
                if !sentClose { sentClose = true; output += records.encode(TLSConst.alert, [1, TLSAlert.closeNotify]) }
                state = .closed
                return
            }
            if desc == TLSAlert.userCanceled { return }   // a close_notify follows
            fail(.peerAlert(desc), sendAlert: false)
        case TLSConst.handshake:
            // Before the server's handshake keys only ServerHello (and HRR)
            // may be plaintext; after them everything must be encrypted.
            guard rec.encrypted == (records.readState != nil) else {
                throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "handshake record with the wrong protection")
            }
            guard hsBuffer.count + rec.payload.count <= TLSClient.maxHandshakeMessage + 4 else {
                throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "handshake message too large")
            }
            hsBuffer += rec.payload
            try drainHandshake()
        case TLSConst.applicationData:
            guard state == .connected, wait == .done else {
                throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "application data during the handshake")
            }
            if !peerClosed { appIn += rec.payload }
        default:
            throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "unexpected record")
        }
    }

    private func drainHandshake() throws(TLSError) {
        while hsBuffer.count >= 4 && (state == .handshaking || state == .connected) {
            let len = Int(hsBuffer[1]) << 16 | Int(hsBuffer[2]) << 8 | Int(hsBuffer[3])
            guard len <= TLSClient.maxHandshakeMessage else {
                throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "handshake message too large")
            }
            guard hsBuffer.count >= 4 + len else { return }
            let msg = Array(hsBuffer[0..<(4 + len)])
            hsBuffer.removeFirst(4 + len)
            try handleHandshake(type: msg[0], body: Array(msg[4...]), whole: msg)
        }
    }

    /// Key changes must fall on a record boundary (RFC 8446 5.1).
    private func requireRecordBoundary() throws(TLSError) {
        guard hsBuffer.isEmpty else {
            throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "handshake data across a key change")
        }
    }

    private func handleHandshake(type: UInt8, body: [UInt8], whole: [UInt8]) throws(TLSError) {
        switch (wait, type) {
        case (.serverHello, TLSConst.serverHello):
            try handleServerHello(body, whole)
        case (.encryptedExtensions, TLSConst.encryptedExtensions):
            try handleEncryptedExtensions(body)
            transcript.add(whole)
            wait = .certificateOrRequest
        case (.certificateOrRequest, TLSConst.certificateRequest):
            try handleCertificateRequest(body)
            transcript.add(whole)
            wait = .certificate
        case (.certificateOrRequest, TLSConst.certificate), (.certificate, TLSConst.certificate):
            try handleCertificate(body)
            transcript.add(whole)
            wait = .certificateVerify
        case (.certificateVerify, TLSConst.certificateVerify):
            try handleCertificateVerify(body)
            transcript.add(whole)
            wait = .finished
        case (.finished, TLSConst.finished):
            try handleFinished(body, whole)
        case (.done, TLSConst.newSessionTicket):
            break   // no resumption: ignored
        case (.done, TLSConst.keyUpdate):
            try handleKeyUpdate(body)
        default:
            throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "unexpected handshake message \(type)")
        }
    }

    // MARK: ClientHello

    private func randomBytes(_ n: Int) -> [UInt8] {
        let r = random(n)
        if r.count == n { return r }
        var out = Array(r.prefix(n))   // a short generator: pad (never in practice)
        while out.count < n { out.append(0) }
        return out
    }

    private func makeShare(_ g: UInt16) -> (group: UInt16, priv: [UInt8], pub: [UInt8])? {
        for _ in 0..<8 {
            switch g {
            case TLSConst.x25519:
                let k = randomBytes(32)
                guard let p = X25519.publicKey(privateKey: k) else { return nil }
                return (g, k, p)
            case TLSConst.secp256r1:
                let k = randomBytes(32)
                if let p = P256.publicKey(privateKey: k) { return (g, k, p) }
            case TLSConst.secp384r1:
                let k = randomBytes(48)
                if let p = P384.publicKey(privateKey: k) { return (g, k, p) }
            default: return nil
            }
        }
        return nil
    }

    private func isIPLiteral(_ s: String) -> Bool { x509ParseIP(s) != nil }

    private func buildClientHello() -> [UInt8] {
        var b: [UInt8] = [0x03, 0x03]
        b += clientRandom
        b.append(UInt8(sessionID.count)); b += sessionID
        tlsPut16(&b, config.cipherSuites.count * 2)
        for s in config.cipherSuites { tlsPut16(&b, Int(s)) }
        b += [1, 0]   // compression: null
        var ext: [UInt8] = []
        if let name = config.serverName, !isIPLiteral(name) {
            var host = Array(name.utf8)
            if host.last == 0x2e { host.removeLast() }
            var sni: [UInt8] = []
            tlsPut16(&sni, host.count + 3)
            sni.append(0)                       // host_name
            tlsPut16(&sni, host.count); sni += host
            tlsExtension(&ext, TLSConst.extServerName, sni)
        }
        if config.sendRenegotiationInfo { tlsExtension(&ext, TLSConst.extRenegotiationInfo, [0]) }
        var groups: [UInt8] = []
        tlsPut16(&groups, config.supportedGroups.count * 2)
        for g in config.supportedGroups { tlsPut16(&groups, Int(g)) }
        tlsExtension(&ext, TLSConst.extSupportedGroups, groups)
        if config.sendSessionTicket { tlsExtension(&ext, TLSConst.extSessionTicket, []) }
        if !config.alpn.isEmpty {
            var list: [UInt8] = []
            for p in config.alpn where !p.utf8.isEmpty && p.utf8.count < 256 {
                list.append(UInt8(p.utf8.count)); list += Array(p.utf8)
            }
            var a: [UInt8] = []
            tlsPut16(&a, list.count); a += list
            tlsExtension(&ext, TLSConst.extALPN, a)
        }
        var ks: [UInt8] = []
        for s in shares { tlsPut16(&ks, Int(s.group)); tlsPut16(&ks, s.pub.count); ks += s.pub }
        var ksExt: [UInt8] = []
        tlsPut16(&ksExt, ks.count); ksExt += ks
        tlsExtension(&ext, TLSConst.extKeyShare, ksExt)
        tlsExtension(&ext, TLSConst.extSupportedVersions, [2, 0x03, 0x04])
        var sa: [UInt8] = []
        tlsPut16(&sa, config.signatureAlgorithms.count * 2)
        for s in config.signatureAlgorithms { tlsPut16(&sa, Int(s)) }
        tlsExtension(&ext, TLSConst.extSignatureAlgorithms, sa)
        if let c = cookie {
            var ce: [UInt8] = []
            tlsPut16(&ce, c.count); ce += c
            tlsExtension(&ext, TLSConst.extCookie, ce)
        }
        if config.sendPSKModes { tlsExtension(&ext, TLSConst.extPSKModes, [1, 1]) }   // psk_dhe_ke
        if let l = config.recordSizeLimit {
            var v: [UInt8] = []
            tlsPut16(&v, Int(l))
            tlsExtension(&ext, TLSConst.extRecordSizeLimit, v)
        }
        if config.padClientHello {
            let unpadded = 4 + b.count + 2 + ext.count
            if unpadded >= 256 && unpadded < 512 {
                let pad = max(1, 512 - unpadded - 4)
                tlsExtension(&ext, TLSConst.extPadding, [UInt8](repeating: 0, count: pad))
            }
        }
        tlsPut16(&b, ext.count); b += ext
        return tlsHandshakeMessage(TLSConst.clientHello, b)
    }

    private func sendHandshake(_ msg: [UInt8]) {
        transcript.add(msg)
        output += records.encode(TLSConst.handshake, msg)
    }

    private func sendCCSOnce() {
        guard config.middleboxCompatibility, !sentCCS else { return }
        sentCCS = true
        output += records.encodePlain(TLSConst.changeCipherSpec, [1])
    }

    // MARK: ServerHello / HelloRetryRequest

    private func handleServerHello(_ body: [UInt8], _ whole: [UInt8]) throws(TLSError) {
        var r = ByteReader(body)
        guard let version = r.u16(), let random = r.bytes(32), let sidLen = r.u8(),
              let sid = r.bytes(Int(sidLen)), let suiteID = r.u16(), let compression = r.u8() else {
            throw .protocolError(alert: TLSAlert.decodeError, reason: "short ServerHello")
        }
        let isHRR = random == TLSConst.helloRetryRandom
        // Extensions (absent only in TLS 1.2-and-older ServerHellos).
        var exts: [(UInt16, [UInt8])] = []
        if !r.atEnd {
            exts = try tlsParseExtensions(&r)
        }
        guard r.atEnd else { throw .protocolError(alert: TLSAlert.decodeError, reason: "trailing ServerHello data") }
        guard let sv = tlsFind(exts, TLSConst.extSupportedVersions) else {
            let tail = Array(random[24..<31])
            if tail == TLSConst.downgradePrefix && (random[31] == 0 || random[31] == 1) {
                throw .protocolError(alert: TLSAlert.illegalParameter, reason: "downgrade to an older TLS detected")
            }
            throw .protocolError(alert: TLSAlert.protocolVersion, reason: "server does not support TLS 1.3")
        }
        guard sv == [0x03, 0x04] else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "server selected an unsupported version")
        }
        guard version == 0x0303 else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "bad legacy_version")
        }
        guard sid == sessionID else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "session id not echoed")
        }
        guard compression == 0 else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "compression selected")
        }
        guard config.cipherSuites.contains(suiteID), let cs = TLSCipherSuite(suiteID) else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "server chose a cipher suite we did not offer")
        }
        if let prev = suite, prev.id != suiteID {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "cipher suite changed after HelloRetryRequest")
        }
        let allowed: [UInt16] = isHRR ? [TLSConst.extSupportedVersions, TLSConst.extKeyShare, TLSConst.extCookie]
                                      : [TLSConst.extSupportedVersions, TLSConst.extKeyShare]
        for (t, _) in exts where !allowed.contains(t) {
            throw .protocolError(alert: TLSAlert.unsupportedExtension, reason: "unexpected extension \(t) in ServerHello")
        }
        suite = cs
        cipherSuite = suiteID

        if isHRR {
            try handleHelloRetry(exts, whole, cs)
            return
        }

        // Key share: one of ours.
        guard let ksData = tlsFind(exts, TLSConst.extKeyShare) else {
            throw .protocolError(alert: TLSAlert.missingExtension, reason: "no key_share in ServerHello")
        }
        var kr = ByteReader(ksData)
        guard let group = kr.u16(), let klen = kr.u16(), let peer = kr.bytes(Int(klen)), kr.atEnd else {
            throw .protocolError(alert: TLSAlert.decodeError, reason: "bad key_share")
        }
        var shared: [UInt8]? = nil
        var found = false
        for s in shares where s.group == group {
            found = true
            switch group {
            case TLSConst.x25519:
                if peer.count == 32 { shared = X25519.sharedSecret(privateKey: s.priv, peerPublicKey: peer) }
            case TLSConst.secp256r1:
                if peer.count == 65 { shared = P256.sharedSecret(privateKey: s.priv, peerPublicKey: peer) }
            case TLSConst.secp384r1:
                if peer.count == 97 { shared = P384.sharedSecret(privateKey: s.priv, peerPublicKey: peer) }
            default: break
            }
        }
        guard found else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "key share for a group we did not offer")
        }
        guard let ecdhe = shared else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "invalid server key share")
        }
        keyExchangeGroup = group
        try requireRecordBoundary()
        transcript.add(whole)

        // Key schedule up to the handshake traffic secrets.
        let h = cs.hash
        let zeros = [UInt8](repeating: 0, count: h.size)
        let early = h.extract(salt: [], ikm: zeros)
        let derived = h.deriveSecret(early, "derived", h.hash([]))
        let hs = h.extract(salt: derived, ikm: ecdhe)
        let th = transcript.current(h)
        let chs = h.deriveSecret(hs, "c hs traffic", th)
        let shs = h.deriveSecret(hs, "s hs traffic", th)
        let master = h.extract(salt: h.deriveSecret(hs, "derived", h.hash([])), ikm: zeros)
        secrets.sharedSecret = ecdhe
        secrets.earlySecret = early
        secrets.handshakeSecret = hs
        secrets.clientHandshakeTraffic = chs
        secrets.serverHandshakeTraffic = shs
        secrets.masterSecret = master
        guard let rs = cs.cipherState(secret: shs), let ws = cs.cipherState(secret: chs) else {
            throw .protocolError(alert: TLSAlert.internalError, reason: "key setup failed")
        }
        records.readState = rs
        records.writeState = ws   // alerts from here on are encrypted
        shares = []               // ephemeral keys are no longer needed
        wait = .encryptedExtensions
    }

    private func handleHelloRetry(_ exts: [(UInt16, [UInt8])], _ whole: [UInt8], _ cs: TLSCipherSuite) throws(TLSError) {
        guard !didHelloRetry else {
            throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "second HelloRetryRequest")
        }
        didHelloRetry = true
        var newGroup: UInt16? = nil
        if let ks = tlsFind(exts, TLSConst.extKeyShare) {
            guard ks.count == 2 else { throw .protocolError(alert: TLSAlert.decodeError, reason: "bad HRR key_share") }
            let g = UInt16(ks[0]) << 8 | UInt16(ks[1])
            guard config.supportedGroups.contains(g), !shares.contains(where: { $0.group == g }) else {
                throw .protocolError(alert: TLSAlert.illegalParameter, reason: "HelloRetryRequest for an unusable group")
            }
            newGroup = g
        }
        if let c = tlsFind(exts, TLSConst.extCookie) {
            var cr = ByteReader(c)
            guard let n = cr.u16(), n > 0, let v = cr.bytes(Int(n)), cr.atEnd else {
                throw .protocolError(alert: TLSAlert.decodeError, reason: "bad cookie")
            }
            cookie = v
        }
        guard newGroup != nil || cookie != nil else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "HelloRetryRequest that changes nothing")
        }
        try requireRecordBoundary()
        if let g = newGroup {
            guard let s = makeShare(g) else {
                throw .protocolError(alert: TLSAlert.handshakeFailure, reason: "HelloRetryRequest for unsupported group \(g)")
            }
            shares = [s]
        }
        transcript.replaceWithMessageHash(cs.hash)
        transcript.add(whole)
        sendCCSOnce()
        sendHandshake(buildClientHello())
    }

    // MARK: Encrypted handshake

    private func handleEncryptedExtensions(_ body: [UInt8]) throws(TLSError) {
        var r = ByteReader(body)
        let exts = try tlsParseExtensions(&r)
        guard r.atEnd else { throw .protocolError(alert: TLSAlert.decodeError, reason: "trailing EncryptedExtensions data") }
        for (t, data) in exts {
            switch t {
            case TLSConst.extServerName:
                guard data.isEmpty, config.serverName != nil else {
                    throw .protocolError(alert: TLSAlert.illegalParameter, reason: "bad server_name response")
                }
            case TLSConst.extSupportedGroups:
                break   // the server's preferences; informational
            case TLSConst.extALPN:
                var ar = ByteReader(data)
                guard let n = ar.u16(), var list = ar.sub(Int(n)), ar.atEnd, let pl = list.u8(), pl > 0,
                      let p = list.bytes(Int(pl)), list.atEnd else {
                    throw .protocolError(alert: TLSAlert.decodeError, reason: "bad ALPN response")
                }
                let proto = String(decoding: p, as: UTF8.self)
                guard config.alpn.contains(proto) else {
                    throw .protocolError(alert: TLSAlert.illegalParameter, reason: "server chose an ALPN protocol we did not offer")
                }
                alpnProtocol = proto
            case TLSConst.extRecordSizeLimit:
                guard config.recordSizeLimit != nil else {
                    throw .protocolError(alert: TLSAlert.unsupportedExtension, reason: "unsolicited record_size_limit")
                }
                guard data.count == 2 else { throw .protocolError(alert: TLSAlert.decodeError, reason: "bad record_size_limit") }
                let v = Int(data[0]) << 8 | Int(data[1])
                guard v >= 64 else { throw .protocolError(alert: TLSAlert.illegalParameter, reason: "record_size_limit too small") }
                serverRecordSizeLimit = v
            default:
                throw .protocolError(alert: TLSAlert.unsupportedExtension, reason: "unexpected extension \(t) in EncryptedExtensions")
            }
        }
    }

    private func handleCertificateRequest(_ body: [UInt8]) throws(TLSError) {
        var r = ByteReader(body)
        guard let cl = r.u8(), let ctx = r.bytes(Int(cl)) else {
            throw .protocolError(alert: TLSAlert.decodeError, reason: "bad CertificateRequest")
        }
        let exts = try tlsParseExtensions(&r)
        guard r.atEnd, tlsFind(exts, TLSConst.extSignatureAlgorithms) != nil else {
            throw .protocolError(alert: TLSAlert.decodeError, reason: "bad CertificateRequest")
        }
        certificateRequestContext = ctx
    }

    private func handleCertificate(_ body: [UInt8]) throws(TLSError) {
        var r = ByteReader(body)
        guard let cl = r.u8(), cl == 0, let listLen = r.u24(), var list = r.sub(Int(listLen)), r.atEnd else {
            throw .protocolError(alert: TLSAlert.decodeError, reason: "bad Certificate message")
        }
        var ders: [[UInt8]] = []
        while !list.atEnd {
            guard let n = list.u24(), n > 0, let der = list.bytes(Int(n)), let el = list.u16(),
                  let entryExts = list.bytes(Int(el)) else {
                throw .protocolError(alert: TLSAlert.decodeError, reason: "bad CertificateEntry")
            }
            guard ders.count < TLSClient.maxCertificates else {
                throw .certificate(.chainTooLong)
            }
            // We requested no status_request or SCTs: entries carry none.
            var er = ByteReader(entryExts)
            let ee = try tlsParseExtensions(&er, prefixed: false)
            if let first = ee.first {
                throw .protocolError(alert: TLSAlert.unsupportedExtension, reason: "unexpected extension \(first.0) in Certificate")
            }
            ders.append(der)
        }
        guard list.ok else { throw .protocolError(alert: TLSAlert.decodeError, reason: "bad certificate list") }
        guard !ders.isEmpty else { throw .certificate(.emptyChain) }

        switch config.trust {
        case .roots(let store):
            do throws(X509Error) {
                let path = try X509Validator.validate(chain: ders, hostname: config.serverName, now: config.now, roots: store)
                peerCertificates = path
            } catch {
                throw .certificate(error)
            }
        case .pinned(let pin):
            guard ders[0] == pin else { throw .certificate(.untrustedRoot) }
            do throws(X509Error) { peerCertificates = [try X509Certificate(der: ders[0])] } catch { throw .certificate(error) }
        case .insecureAcceptAny:
            do throws(X509Error) { peerCertificates = [try X509Certificate(der: ders[0])] } catch { throw .certificate(error) }
        }
        leafKey = peerCertificates.first?.publicKey
    }

    private func handleCertificateVerify(_ body: [UInt8]) throws(TLSError) {
        var r = ByteReader(body)
        guard let scheme = r.u16(), let sl = r.u16(), let sig = r.bytes(Int(sl)), r.atEnd, let h = suite?.hash,
              let key = leafKey else {
            throw .protocolError(alert: TLSAlert.decodeError, reason: "bad CertificateVerify")
        }
        guard config.signatureAlgorithms.contains(scheme) else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "signature scheme we did not offer")
        }
        var content = [UInt8](repeating: 0x20, count: 64)
        content += Array("TLS 1.3, server CertificateVerify".utf8)
        content.append(0)
        content += transcript.current(h)
        var ok = false
        switch (scheme, key) {
        case (TLSConst.ecdsaSecp256r1SHA256, .ecP256(let q)):
            ok = P256.verify(publicKey: q, digest: SHA256.hash(content), derSignature: sig)
        case (TLSConst.ecdsaSecp384r1SHA384, .ecP384(let q)):
            ok = P384.verify(publicKey: q, digest: SHA384.hash(content), derSignature: sig)
        case (TLSConst.rsaPSSRSAESHA256, .rsa(let n, let e)), (TLSConst.rsaPSSRSAESHA384, .rsa(let n, let e)),
             (TLSConst.rsaPSSRSAESHA512, .rsa(let n, let e)):
            let alg: CryptoHashAlgorithm = scheme == TLSConst.rsaPSSRSAESHA256 ? .sha256
                : scheme == TLSConst.rsaPSSRSAESHA384 ? .sha384 : .sha512
            guard let k = RSAPublicKey(modulus: n, exponent: e) else {
                throw .protocolError(alert: TLSAlert.unsupportedCertificate, reason: "unsupported RSA key size")
            }
            ok = k.verifyPSS(signature: sig, digest: alg.hash(content), hash: alg, saltLength: nil)
        default:
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "signature scheme does not fit the certificate key")
        }
        guard ok else {
            throw .protocolError(alert: TLSAlert.decryptError, reason: "CertificateVerify signature does not verify")
        }
        signatureScheme = scheme
    }

    private func handleFinished(_ body: [UInt8], _ whole: [UInt8]) throws(TLSError) {
        guard let cs = suite else { throw .protocolError(alert: TLSAlert.internalError, reason: "no suite") }
        let h = cs.hash
        let key = h.expandLabel(secrets.serverHandshakeTraffic, "finished", [], h.size)
        let expect = h.hmac(key: key, transcript.current(h))
        guard body.count == h.size, cryptoEqual(body, expect) else {
            throw .protocolError(alert: TLSAlert.decryptError, reason: "server Finished does not verify")
        }
        try requireRecordBoundary()
        transcript.add(whole)
        let th = transcript.current(h)
        clientAppSecret = h.deriveSecret(secrets.masterSecret, "c ap traffic", th)
        serverAppSecret = h.deriveSecret(secrets.masterSecret, "s ap traffic", th)
        secrets.clientApplicationTraffic = clientAppSecret
        secrets.serverApplicationTraffic = serverAppSecret
        guard let rs = cs.cipherState(secret: serverAppSecret), let ws = cs.cipherState(secret: clientAppSecret) else {
            throw .protocolError(alert: TLSAlert.internalError, reason: "key setup failed")
        }
        records.readState = rs

        // Our second flight: [CCS] [empty Certificate] Finished.
        sendCCSOnce()
        if let ctx = certificateRequestContext {
            var c: [UInt8] = [UInt8(ctx.count)] + ctx
            c += [0, 0, 0]   // empty certificate_list
            sendHandshake(tlsHandshakeMessage(TLSConst.certificate, c))
        }
        let ckey = h.expandLabel(secrets.clientHandshakeTraffic, "finished", [], h.size)
        sendHandshake(tlsHandshakeMessage(TLSConst.finished, h.hmac(key: ckey, transcript.current(h))))
        records.writeState = ws
        if let l = serverRecordSizeLimit { records.maxSendFragment = min(TLSRecordLayer.maxPlaintext, l - 1) }
        wait = .done
        state = .connected
        for w in pendingWrites where !w.isEmpty { output += records.encode(TLSConst.applicationData, w) }
        pendingWrites = []
    }

    private func handleKeyUpdate(_ body: [UInt8]) throws(TLSError) {
        guard body.count == 1, body[0] <= 1, let cs = suite else {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "bad KeyUpdate")
        }
        try requireRecordBoundary()
        let h = cs.hash
        serverAppSecret = h.expandLabel(serverAppSecret, "traffic upd", [], h.size)
        guard let rs = cs.cipherState(secret: serverAppSecret) else {
            throw .protocolError(alert: TLSAlert.internalError, reason: "key update failed")
        }
        records.readState = rs
        if body[0] == 1 && !sentClose {
            output += records.encode(TLSConst.handshake, tlsHandshakeMessage(TLSConst.keyUpdate, [0]))
            clientAppSecret = h.expandLabel(clientAppSecret, "traffic upd", [], h.size)
            guard let ws = cs.cipherState(secret: clientAppSecret) else {
                throw .protocolError(alert: TLSAlert.internalError, reason: "key update failed")
            }
            records.writeState = ws
        }
    }

    // MARK: Errors

    private func fail(_ e: TLSError, sendAlert: Bool = true) {
        guard state != .failed else { return }
        error = e
        if sendAlert, let a = e.alertSent, !sentClose {
            output += records.encode(TLSConst.alert, [2, a])
        }
        state = .failed
        appIn = []
        pendingWrites = []
    }
}

// MARK: - Encoding helpers

func tlsPut16(_ b: inout [UInt8], _ v: Int) {
    b.append(UInt8(truncatingIfNeeded: v >> 8)); b.append(UInt8(truncatingIfNeeded: v))
}

func tlsExtension(_ b: inout [UInt8], _ type: UInt16, _ data: [UInt8]) {
    tlsPut16(&b, Int(type)); tlsPut16(&b, data.count); b += data
}

func tlsHandshakeMessage(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
    [type, UInt8(truncatingIfNeeded: body.count >> 16), UInt8(truncatingIfNeeded: body.count >> 8),
     UInt8(truncatingIfNeeded: body.count)] + body
}

/// An extensions block (2-byte length, then type/length/data entries;
/// with prefixed: false the reader holds just the entries). Duplicates are
/// illegal_parameter (RFC 8446 4.2); at most 64 entries.
func tlsParseExtensions(_ r: inout ByteReader, prefixed: Bool = true) throws(TLSError) -> [(UInt16, [UInt8])] {
    var list: ByteReader
    if prefixed {
        guard let n = r.u16(), let l = r.sub(Int(n)) else {
            throw .protocolError(alert: TLSAlert.decodeError, reason: "bad extensions block")
        }
        list = l
    } else {
        list = r
        _ = r.skip(r.remaining)
    }
    var out: [(UInt16, [UInt8])] = []
    while !list.atEnd {
        guard let t = list.u16(), let n = list.u16(), let d = list.bytes(Int(n)), out.count < 64 else {
            throw .protocolError(alert: TLSAlert.decodeError, reason: "bad extension")
        }
        for (u, _) in out where u == t {
            throw .protocolError(alert: TLSAlert.illegalParameter, reason: "duplicate extension \(t)")
        }
        out.append((t, d))
    }
    return out
}

func tlsFind(_ exts: [(UInt16, [UInt8])], _ t: UInt16) -> [UInt8]? {
    for (u, d) in exts where u == t { return d }
    return nil
}
