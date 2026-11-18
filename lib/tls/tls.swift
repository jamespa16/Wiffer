// lib/tls: a TLS 1.3 client (RFC 8446) in pure Swift, I/O-free (ROADMAP
// Phase 8A). The caller owns the socket:
//
//   var cfg = TLSClientConfig(serverName: "example.com",
//                             trust: .roots(X509TrustStore(concatenatedDER: rootsFile)),
//                             now: rtcUnixSeconds)
//   let tls = TLSClient(config: cfg, random: { n in drbg.generate(n) })
//   tls.start()                                   // queues the ClientHello
//   loop {
//       let out = tls.takeOutput(); if !out.isEmpty { send(socket, out) }
//       if tls.state == .failed { report(tls.error!); break }
//       if tls.state == .closed { break }
//       let got = recv(socket)                    // non-blocking is fine
//       if got.isEmpty /* EOF */ { tls.transportClosed() } else { tls.feed(got) }
//       let data = tls.read()                     // decrypted application data
//       ... tls.write(request) ...                // queued until connected
//   }
//   tls.close()                                   // close_notify; send takeOutput()
//
// See client.swift for the state machine and record.swift for the record
// layer. Supported: TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384,
// TLS_CHACHA20_POLY1305_SHA256; X25519 key share (P-256 / P-384 after a
// HelloRetryRequest); ECDSA P-256/P-384 and RSA-PSS CertificateVerify; SNI;
// ALPN; middlebox compatibility mode; KeyUpdate. No client certificates
// (an empty Certificate answers a CertificateRequest), no 0-RTT, no
// resumption (NewSessionTicket is ignored), no TLS 1.2.

enum TLSConst {
    static let aes128GCMSHA256: UInt16 = 0x1301
    static let aes256GCMSHA384: UInt16 = 0x1302
    static let chacha20Poly1305SHA256: UInt16 = 0x1303

    static let x25519: UInt16 = 0x001d
    static let secp256r1: UInt16 = 0x0017
    static let secp384r1: UInt16 = 0x0018

    static let ecdsaSecp256r1SHA256: UInt16 = 0x0403
    static let ecdsaSecp384r1SHA384: UInt16 = 0x0503
    static let rsaPSSRSAESHA256: UInt16 = 0x0804
    static let rsaPSSRSAESHA384: UInt16 = 0x0805
    static let rsaPSSRSAESHA512: UInt16 = 0x0806
    static let rsaPKCS1SHA256: UInt16 = 0x0401
    static let rsaPKCS1SHA384: UInt16 = 0x0501
    static let rsaPKCS1SHA512: UInt16 = 0x0601

    // Content types
    static let changeCipherSpec: UInt8 = 20
    static let alert: UInt8 = 21
    static let handshake: UInt8 = 22
    static let applicationData: UInt8 = 23

    // Handshake types
    static let clientHello: UInt8 = 1
    static let serverHello: UInt8 = 2
    static let newSessionTicket: UInt8 = 4
    static let encryptedExtensions: UInt8 = 8
    static let certificate: UInt8 = 11
    static let certificateRequest: UInt8 = 13
    static let certificateVerify: UInt8 = 15
    static let finished: UInt8 = 20
    static let keyUpdate: UInt8 = 24
    static let messageHash: UInt8 = 254

    // Extensions
    static let extServerName: UInt16 = 0
    static let extMaxFragmentLength: UInt16 = 1
    static let extStatusRequest: UInt16 = 5
    static let extSupportedGroups: UInt16 = 10
    static let extSignatureAlgorithms: UInt16 = 13
    static let extALPN: UInt16 = 16
    static let extSCT: UInt16 = 18
    static let extPadding: UInt16 = 21
    static let extRecordSizeLimit: UInt16 = 28
    static let extSessionTicket: UInt16 = 35
    static let extPreSharedKey: UInt16 = 41
    static let extEarlyData: UInt16 = 42
    static let extSupportedVersions: UInt16 = 43
    static let extCookie: UInt16 = 44
    static let extPSKModes: UInt16 = 45
    static let extCertificateAuthorities: UInt16 = 47
    static let extSignatureAlgorithmsCert: UInt16 = 50
    static let extKeyShare: UInt16 = 51
    static let extRenegotiationInfo: UInt16 = 0xff01

    static let helloRetryRandom: [UInt8] = [
        0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
        0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c]
    /// "DOWNGRD" + 01 (TLS 1.2) / 00 (TLS 1.1 and below), RFC 8446 4.1.3.
    static let downgradePrefix: [UInt8] = [0x44, 0x4f, 0x57, 0x4e, 0x47, 0x52, 0x44]
}

/// Alert descriptions (RFC 8446 6), with readable names.
enum TLSAlert {
    static let closeNotify: UInt8 = 0
    static let unexpectedMessage: UInt8 = 10
    static let badRecordMAC: UInt8 = 20
    static let recordOverflow: UInt8 = 22
    static let handshakeFailure: UInt8 = 40
    static let badCertificate: UInt8 = 42
    static let unsupportedCertificate: UInt8 = 43
    static let certificateRevoked: UInt8 = 44
    static let certificateExpired: UInt8 = 45
    static let certificateUnknown: UInt8 = 46
    static let illegalParameter: UInt8 = 47
    static let unknownCA: UInt8 = 48
    static let accessDenied: UInt8 = 49
    static let decodeError: UInt8 = 50
    static let decryptError: UInt8 = 51
    static let protocolVersion: UInt8 = 70
    static let insufficientSecurity: UInt8 = 71
    static let internalError: UInt8 = 80
    static let inappropriateFallback: UInt8 = 86
    static let userCanceled: UInt8 = 90
    static let missingExtension: UInt8 = 109
    static let unsupportedExtension: UInt8 = 110
    static let unrecognizedName: UInt8 = 112
    static let badCertificateStatusResponse: UInt8 = 113
    static let unknownPSKIdentity: UInt8 = 115
    static let certificateRequired: UInt8 = 116
    static let noApplicationProtocol: UInt8 = 120

    static func name(_ a: UInt8) -> String {
        switch a {
        case 0: return "close_notify"
        case 10: return "unexpected_message"
        case 20: return "bad_record_mac"
        case 22: return "record_overflow"
        case 40: return "handshake_failure"
        case 42: return "bad_certificate"
        case 43: return "unsupported_certificate"
        case 44: return "certificate_revoked"
        case 45: return "certificate_expired"
        case 46: return "certificate_unknown"
        case 47: return "illegal_parameter"
        case 48: return "unknown_ca"
        case 49: return "access_denied"
        case 50: return "decode_error"
        case 51: return "decrypt_error"
        case 70: return "protocol_version"
        case 71: return "insufficient_security"
        case 80: return "internal_error"
        case 86: return "inappropriate_fallback"
        case 90: return "user_canceled"
        case 109: return "missing_extension"
        case 110: return "unsupported_extension"
        case 112: return "unrecognized_name"
        case 113: return "bad_certificate_status_response"
        case 115: return "unknown_psk_identity"
        case 116: return "certificate_required"
        case 120: return "no_application_protocol"
        default: return "alert \(a)"
        }
    }
}

enum TLSError: Error, Equatable, CustomStringConvertible {
    /// The server sent a fatal alert.
    case peerAlert(UInt8)
    /// We found a protocol error; `alert` was sent to the server.
    case protocolError(alert: UInt8, reason: String)
    /// The server's certificate was refused (a matching alert was sent).
    case certificate(X509Error)
    /// The transport closed during the handshake (or before close_notify
    /// when the caller asked for that to be an error).
    case truncated
    /// write() after close() or after the peer's close_notify.
    case closed

    /// The alert we send for this error (nil if none is sent).
    var alertSent: UInt8? {
        switch self {
        case .protocolError(let a, _): return a
        case .certificate(let e): return TLSError.alertFor(e)
        default: return nil
        }
    }

    static func alertFor(_ e: X509Error) -> UInt8 {
        switch e {
        case .expired, .notYetValid: return TLSAlert.certificateExpired
        case .untrustedRoot: return TLSAlert.unknownCA
        case .unsupportedAlgorithm: return TLSAlert.unsupportedCertificate
        case .emptyChain: return TLSAlert.decodeError
        case .hostnameMismatch, .notCA, .keyUsage, .extendedKeyUsage, .pathLength, .nameConstraints,
             .chainTooLong: return TLSAlert.certificateUnknown
        default: return TLSAlert.badCertificate
        }
    }

    var description: String {
        switch self {
        case .peerAlert(let a): return "TLS: server sent alert \(TLSAlert.name(a))"
        case .protocolError(let a, let r): return "TLS: \(r) (sent \(TLSAlert.name(a)))"
        case .certificate(let e): return "TLS: \(e.description)"
        case .truncated: return "TLS: connection closed during the handshake"
        case .closed: return "TLS: connection is closed"
        }
    }
}

/// How the server's certificate is checked.
enum TLSTrust {
    /// Build a path to one of these roots (the normal case).
    case roots(X509TrustStore)
    /// Accept exactly this leaf certificate (DER), whatever its dates, names
    /// or issuer: for test servers and RFC 8448's self-signed "rsa" cert.
    case pinned([UInt8])
    /// Accept any certificate (`fetch -k`; testing only). The signature in
    /// CertificateVerify is still checked against the leaf's key.
    case insecureAcceptAny
}

struct TLSClientConfig {
    /// SNI and the name checked against the certificate. An IP literal is
    /// checked against iPAddress SANs and not sent as SNI. nil: no SNI and
    /// no hostname check (only sensible with .pinned).
    var serverName: String?
    var trust: TLSTrust
    /// Unix seconds (from the RTC) for certificate validity.
    var now: Int64
    /// ALPN protocols to offer (empty: no ALPN extension).
    var alpn: [String] = ["http/1.1"]
    /// Preference order. ChaCha20 first: AES here is table-based software.
    var cipherSuites: [UInt16] = [TLSConst.chacha20Poly1305SHA256, TLSConst.aes128GCMSHA256, TLSConst.aes256GCMSHA384]
    /// Groups to send a key share for in the first ClientHello.
    var keyShareGroups: [UInt16] = [TLSConst.x25519]
    /// Groups advertised in supported_groups (a HelloRetryRequest may pick
    /// any of these that we implement: x25519, secp256r1, secp384r1).
    var supportedGroups: [UInt16] = [TLSConst.x25519, TLSConst.secp256r1, TLSConst.secp384r1]
    /// signature_algorithms. The PKCS#1 entries are for certificates only;
    /// CertificateVerify must use ECDSA or RSA-PSS (RFC 8446 4.2.3).
    var signatureAlgorithms: [UInt16] = [
        TLSConst.ecdsaSecp256r1SHA256, TLSConst.ecdsaSecp384r1SHA384,
        TLSConst.rsaPSSRSAESHA256, TLSConst.rsaPSSRSAESHA384, TLSConst.rsaPSSRSAESHA512,
        TLSConst.rsaPKCS1SHA256, TLSConst.rsaPKCS1SHA384, TLSConst.rsaPKCS1SHA512]
    /// Middlebox compatibility mode (RFC 8446 D.4): a 32-byte
    /// legacy_session_id and a dummy change_cipher_spec before the second
    /// flight. Real servers and middleboxes expect it.
    var middleboxCompatibility = true
    /// Pad ClientHellos of 256..511 bytes to 512 (RFC 7685; avoids an old
    /// F5 bug, as NSS and BoringSSL do).
    var padClientHello = true

    // Extensions that change nothing for us; set to reproduce other
    // clients' ClientHellos byte for byte (the RFC 8448 traces).
    var sendRenegotiationInfo = false
    var sendSessionTicket = false
    var sendPSKModes = false
    var recordSizeLimit: UInt16? = nil

    init(serverName: String?, trust: TLSTrust, now: Int64) {
        self.serverName = serverName
        self.trust = trust
        self.now = now
    }
}

// MARK: - Hash, HKDF and AEAD chosen at run time

enum TLSHash {
    case sha256, sha384

    var size: Int { self == .sha256 ? 32 : 48 }

    func hash(_ d: [UInt8]) -> [UInt8] { self == .sha256 ? SHA256.hash(d) : SHA384.hash(d) }

    func hmac(key: [UInt8], _ m: [UInt8]) -> [UInt8] {
        self == .sha256 ? HMAC<SHA256>.mac(key: key, message: m) : HMAC<SHA384>.mac(key: key, message: m)
    }

    func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] {
        self == .sha256 ? HKDF<SHA256>.extract(salt: salt, ikm: ikm) : HKDF<SHA384>.extract(salt: salt, ikm: ikm)
    }

    /// HKDF-Expand-Label; lengths here are always small, so never nil.
    func expandLabel(_ secret: [UInt8], _ label: String, _ context: [UInt8], _ length: Int) -> [UInt8] {
        let r = self == .sha256
            ? HKDF<SHA256>.expandLabel(secret: secret, label: label, context: context, length: length)
            : HKDF<SHA384>.expandLabel(secret: secret, label: label, context: context, length: length)
        return r ?? [UInt8](repeating: 0, count: length)
    }

    func deriveSecret(_ secret: [UInt8], _ label: String, _ transcriptHash: [UInt8]) -> [UInt8] {
        expandLabel(secret, label, transcriptHash, size)
    }
}

/// Running transcript hash: both SHA-256 and SHA-384 until the cipher
/// suite is known (they are cheap and the ClientHello precedes the choice).
struct TLSTranscript {
    var s256 = SHA256()
    var s384 = SHA384()

    mutating func add(_ msg: [UInt8]) { s256.update(msg); s384.update(msg) }
    func current(_ h: TLSHash) -> [UInt8] { h == .sha256 ? s256.finalize() : s384.finalize() }

    /// After a HelloRetryRequest: ClientHello1 becomes message_hash.
    mutating func replaceWithMessageHash(_ h: TLSHash) {
        let d = current(h)
        s256 = SHA256(); s384 = SHA384()
        add([TLSConst.messageHash, 0, 0, UInt8(d.count)] + d)
    }
}

enum TLSAEAD {
    case aesGCM(AESGCM)
    case chacha(ChaCha20Poly1305)

    func seal(nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> [UInt8] {
        switch self {
        case .aesGCM(let a): return a.seal(nonce: nonce, aad: aad, plaintext: plaintext)
        case .chacha(let c): return c.seal(nonce: nonce, aad: aad, plaintext: plaintext)
        }
    }

    func open(nonce: [UInt8], aad: [UInt8], ciphertextAndTag: [UInt8]) -> [UInt8]? {
        switch self {
        case .aesGCM(let a): return a.open(nonce: nonce, aad: aad, ciphertextAndTag: ciphertextAndTag)
        case .chacha(let c): return c.open(nonce: nonce, aad: aad, ciphertextAndTag: ciphertextAndTag)
        }
    }
}

struct TLSCipherSuite {
    let id: UInt16
    let hash: TLSHash
    let keyLength: Int

    init?(_ id: UInt16) {
        switch id {
        case TLSConst.aes128GCMSHA256: hash = .sha256; keyLength = 16
        case TLSConst.aes256GCMSHA384: hash = .sha384; keyLength = 32
        case TLSConst.chacha20Poly1305SHA256: hash = .sha256; keyLength = 32
        default: return nil
        }
        self.id = id
    }

    static func name(_ id: UInt16) -> String {
        switch id {
        case TLSConst.aes128GCMSHA256: return "TLS_AES_128_GCM_SHA256"
        case TLSConst.aes256GCMSHA384: return "TLS_AES_256_GCM_SHA384"
        case TLSConst.chacha20Poly1305SHA256: return "TLS_CHACHA20_POLY1305_SHA256"
        default: return "suite \(id)"
        }
    }

    /// Record protection state for one direction from a traffic secret.
    func cipherState(secret: [UInt8]) -> TLSCipherState? {
        let key = hash.expandLabel(secret, "key", [], keyLength)
        let iv = hash.expandLabel(secret, "iv", [], 12)
        let aead: TLSAEAD
        if id == TLSConst.chacha20Poly1305SHA256 {
            guard let c = ChaCha20Poly1305(key: key) else { return nil }
            aead = .chacha(c)
        } else {
            guard let a = AESGCM(key: key) else { return nil }
            aead = .aesGCM(a)
        }
        return TLSCipherState(aead: aead, iv: iv, secret: secret)
    }
}

/// The secrets of one connection (RFC 8446 7.1), kept for tests and key
/// logging. Empty until derived.
struct TLSSecrets {
    var sharedSecret: [UInt8] = []
    var earlySecret: [UInt8] = []
    var handshakeSecret: [UInt8] = []
    var clientHandshakeTraffic: [UInt8] = []
    var serverHandshakeTraffic: [UInt8] = []
    var masterSecret: [UInt8] = []
    var clientApplicationTraffic: [UInt8] = []
    var serverApplicationTraffic: [UInt8] = []
}
