// X.509 v1/v3 certificates (RFC 5280), parsed from DER.
//
//   let cert = try X509Certificate(der: bytes)      // throws(X509Error)
//   cert.tbs                 the signed TBSCertificate bytes
//   cert.signatureAlgorithm  X509SignatureAlgorithm (.rsaPKCS1(.sha256), ...)
//   cert.signature           signature BIT STRING contents
//   cert.issuer / .subject   X509Name: raw DER, attributes, description
//   cert.notBefore/notAfter  Unix seconds
//   cert.publicKey           X509PublicKey (.rsa / .ecP256 / .ecP384 / ...)
//   cert.isCA, pathLength, keyUsage, extendedKeyUsage, dnsNames,
//   ipAddresses, authorityKeyID, subjectKeyID, nameConstraints
//   cert.verifySignature(of: other) / X509Certificate.verify(...)
//
// Algorithms that we can't verify (SHA-1, MD5, P-521, Ed25519 ...) still
// parse, as `.unsupported(oid)`: plenty of trust anchors are self-signed
// with SHA-1, and an anchor's own signature is never checked.

enum X509Error: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unsupportedAlgorithm(String)
    case badSignature
    case expired
    case notYetValid
    case hostnameMismatch
    case untrustedRoot
    case notCA                 // an issuer without basicConstraints cA
    case keyUsage              // an issuer without keyCertSign, or a leaf
                               // without digitalSignature
    case extendedKeyUsage      // the leaf isn't for serverAuth
    case pathLength            // an issuer's pathLenConstraint exceeded
    case nameConstraints       // a name outside an issuer's constraints
    case unknownCriticalExtension(String)
    case chainTooLong
    case emptyChain

    var description: String {
        switch self {
        case .malformed(let why): return "malformed certificate (\(why))"
        case .unsupportedAlgorithm(let a): return "unsupported algorithm \(a)"
        case .badSignature: return "certificate signature does not verify"
        case .expired: return "certificate has expired"
        case .notYetValid: return "certificate is not yet valid"
        case .hostnameMismatch: return "certificate is not valid for this host name"
        case .untrustedRoot: return "certificate is not issued by a trusted root"
        case .notCA: return "issuing certificate is not a CA"
        case .keyUsage: return "certificate key usage does not allow this use"
        case .extendedKeyUsage: return "certificate is not for TLS server authentication"
        case .pathLength: return "certificate chain exceeds an issuer's path length limit"
        case .nameConstraints: return "certificate name violates an issuer's name constraints"
        case .unknownCriticalExtension(let o): return "certificate has an unknown critical extension \(o)"
        case .chainTooLong: return "certificate chain is too long"
        case .emptyChain: return "server sent no certificate"
        }
    }
}

enum X509SignatureAlgorithm: Equatable {
    case rsaPKCS1(CryptoHashAlgorithm)
    case rsaPSS(CryptoHashAlgorithm, saltLength: Int)
    case ecdsa(CryptoHashAlgorithm)
    case ed25519
    case unsupported(String)

    var name: String {
        switch self {
        case .rsaPKCS1(let h): return "\(x509HashName(h))WithRSAEncryption"
        case .rsaPSS(let h, let s): return "RSASSA-PSS(\(x509HashName(h)), salt \(s))"
        case .ecdsa(let h): return "ecdsa-with-\(x509HashName(h).uppercased())"
        case .ed25519: return "Ed25519"
        case .unsupported(let o): return o
        }
    }
}

func x509HashName(_ h: CryptoHashAlgorithm) -> String {
    switch h {
    case .sha256: return "sha256"
    case .sha384: return "sha384"
    case .sha512: return "sha512"
    }
}

enum X509PublicKey: Equatable {
    case rsa(modulus: [UInt8], exponent: [UInt8])
    case ecP256([UInt8])          // SEC 1 uncompressed point
    case ecP384([UInt8])
    case ed25519([UInt8])
    case unsupported(String)

    var name: String {
        switch self {
        case .rsa(let n, _): return "RSA-\(x509BitLength(n))"
        case .ecP256: return "ECDSA P-256"
        case .ecP384: return "ECDSA P-384"
        case .ed25519: return "Ed25519"
        case .unsupported(let o): return "unsupported key \(o)"
        }
    }
}

func x509BitLength(_ be: [UInt8]) -> Int {
    var i = 0
    while i < be.count && be[i] == 0 { i += 1 }
    guard i < be.count else { return 0 }
    var top = be[i], bits = 0
    while top != 0 { bits += 1; top >>= 1 }
    return (be.count - i - 1) * 8 + bits
}

/// A distinguished name: the DER (for issuer/subject matching) and its
/// attributes in order, for display and normalized comparison.
struct X509Name: Equatable {
    struct Attribute: Equatable {
        let oid: ASN1OID
        let value: String
        let rdnIndex: Int
    }
    let der: [UInt8]
    let attributes: [Attribute]

    var commonName: String? {
        for a in attributes.reversed() where a.oid == X509OID.commonName { return a.value }
        return nil
    }

    /// "CN=example.com, O=Example, C=US" (most specific first, as RFC 4514).
    var description: String {
        var parts: [String] = []
        for a in attributes.reversed() { parts.append("\(x509AttributeName(a.oid))=\(a.value)") }
        return parts.joined(separator: ", ")
    }

    /// RFC 5280 7.1 name matching: identical DER, or the same attributes
    /// with values equal after ASCII case folding and whitespace collapsing
    /// (covers PrintableString vs UTF8String encodings of the same name).
    func matches(_ other: X509Name) -> Bool {
        if der == other.der { return true }
        guard attributes.count == other.attributes.count, !attributes.isEmpty else { return false }
        for i in 0..<attributes.count {
            let a = attributes[i], b = other.attributes[i]
            guard a.oid == b.oid, a.rdnIndex == b.rdnIndex,
                  x509FoldName(a.value) == x509FoldName(b.value) else { return false }
        }
        return true
    }
}

func x509FoldName(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var space = false
    for b in s.utf8 {
        if b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d {
            space = !out.isEmpty
            continue
        }
        if space { out.append(0x20); space = false }
        out.append(b >= 0x41 && b <= 0x5a ? b + 0x20 : b)
    }
    return out
}

func x509AttributeName(_ oid: ASN1OID) -> String {
    if oid == X509OID.commonName { return "CN" }
    if oid == X509OID.organization { return "O" }
    if oid == X509OID.organizationalUnit { return "OU" }
    if oid == X509OID.country { return "C" }
    if oid == X509OID.locality { return "L" }
    if oid == X509OID.stateOrProvince { return "ST" }
    if oid == X509OID.serialNumberAttr { return "serialNumber" }
    if oid == X509OID.domainComponent { return "DC" }
    if oid == X509OID.emailAddress { return "emailAddress" }
    return oid.dotted
}

/// Name constraints (RFC 5280 4.2.1.10), the forms we enforce: dNSName and
/// iPAddress. Other forms are kept only as counts (and not enforced).
struct X509NameConstraints: Equatable {
    var permittedDNS: [String] = []
    var excludedDNS: [String] = []
    var permittedIP: [[UInt8]] = []     // address || mask (8 or 32 bytes)
    var excludedIP: [[UInt8]] = []
    var otherForms = 0
}

enum X509OID {
    static let commonName = ASN1OID(arcs: [2, 5, 4, 3])
    static let serialNumberAttr = ASN1OID(arcs: [2, 5, 4, 5])
    static let country = ASN1OID(arcs: [2, 5, 4, 6])
    static let locality = ASN1OID(arcs: [2, 5, 4, 7])
    static let stateOrProvince = ASN1OID(arcs: [2, 5, 4, 8])
    static let organization = ASN1OID(arcs: [2, 5, 4, 10])
    static let organizationalUnit = ASN1OID(arcs: [2, 5, 4, 11])
    static let domainComponent = ASN1OID(arcs: [0, 9, 2342, 19200300, 100, 1, 25])
    static let emailAddress = ASN1OID(arcs: [1, 2, 840, 113549, 1, 9, 1])

    static let rsaEncryption = ASN1OID(arcs: [1, 2, 840, 113549, 1, 1, 1])
    static let sha1WithRSA = ASN1OID(arcs: [1, 2, 840, 113549, 1, 1, 5])
    static let rsassaPSS = ASN1OID(arcs: [1, 2, 840, 113549, 1, 1, 10])
    static let sha256WithRSA = ASN1OID(arcs: [1, 2, 840, 113549, 1, 1, 11])
    static let sha384WithRSA = ASN1OID(arcs: [1, 2, 840, 113549, 1, 1, 12])
    static let sha512WithRSA = ASN1OID(arcs: [1, 2, 840, 113549, 1, 1, 13])
    static let mgf1 = ASN1OID(arcs: [1, 2, 840, 113549, 1, 1, 8])
    static let sha1 = ASN1OID(arcs: [1, 3, 14, 3, 2, 26])
    static let sha256 = ASN1OID(arcs: [2, 16, 840, 1, 101, 3, 4, 2, 1])
    static let sha384 = ASN1OID(arcs: [2, 16, 840, 1, 101, 3, 4, 2, 2])
    static let sha512 = ASN1OID(arcs: [2, 16, 840, 1, 101, 3, 4, 2, 3])
    static let ecPublicKey = ASN1OID(arcs: [1, 2, 840, 10045, 2, 1])
    static let prime256v1 = ASN1OID(arcs: [1, 2, 840, 10045, 3, 1, 7])
    static let secp384r1 = ASN1OID(arcs: [1, 3, 132, 0, 34])
    static let secp521r1 = ASN1OID(arcs: [1, 3, 132, 0, 35])
    static let ecdsaSHA256 = ASN1OID(arcs: [1, 2, 840, 10045, 4, 3, 2])
    static let ecdsaSHA384 = ASN1OID(arcs: [1, 2, 840, 10045, 4, 3, 3])
    static let ecdsaSHA512 = ASN1OID(arcs: [1, 2, 840, 10045, 4, 3, 4])
    static let ed25519 = ASN1OID(arcs: [1, 3, 101, 112])

    static let subjectKeyIdentifier = ASN1OID(arcs: [2, 5, 29, 14])
    static let keyUsage = ASN1OID(arcs: [2, 5, 29, 15])
    static let subjectAltName = ASN1OID(arcs: [2, 5, 29, 17])
    static let basicConstraints = ASN1OID(arcs: [2, 5, 29, 19])
    static let nameConstraints = ASN1OID(arcs: [2, 5, 29, 30])
    static let certificatePolicies = ASN1OID(arcs: [2, 5, 29, 32])
    static let policyMappings = ASN1OID(arcs: [2, 5, 29, 33])
    static let authorityKeyIdentifier = ASN1OID(arcs: [2, 5, 29, 35])
    static let policyConstraints = ASN1OID(arcs: [2, 5, 29, 36])
    static let extKeyUsage = ASN1OID(arcs: [2, 5, 29, 37])
    static let inhibitAnyPolicy = ASN1OID(arcs: [2, 5, 29, 54])
    static let anyExtendedKeyUsage = ASN1OID(arcs: [2, 5, 29, 37, 0])
    static let serverAuth = ASN1OID(arcs: [1, 3, 6, 1, 5, 5, 7, 3, 1])
}

/// keyUsage bits (RFC 5280 4.2.1.3), as `1 << bit`.
enum X509KeyUsage {
    static let digitalSignature: UInt16 = 1 << 0
    static let keyEncipherment: UInt16 = 1 << 2
    static let keyAgreement: UInt16 = 1 << 4
    static let keyCertSign: UInt16 = 1 << 5
    static let cRLSign: UInt16 = 1 << 6
}

struct X509Certificate {
    /// Certificates bigger than this are refused (real ones are < 8 KiB).
    static let maxSize = 64 * 1024
    static let maxExtensions = 64
    static let maxNames = 512

    let der: [UInt8]
    let tbs: [UInt8]
    let version: Int                  // 1, 2 or 3
    let serial: [UInt8]
    let signatureAlgorithm: X509SignatureAlgorithm
    let signature: [UInt8]
    let issuer: X509Name
    let subject: X509Name
    let notBefore: Int64
    let notAfter: Int64
    let spki: [UInt8]                 // SubjectPublicKeyInfo DER
    let publicKey: X509PublicKey

    private(set) var isCA = false
    private(set) var hasBasicConstraints = false
    private(set) var pathLength: Int? = nil
    private(set) var keyUsage: UInt16? = nil
    /// nil if there is no extKeyUsage extension (any use is fine).
    private(set) var extendedKeyUsage: [ASN1OID]? = nil
    private(set) var dnsNames: [String] = []
    private(set) var ipAddresses: [[UInt8]] = []
    private(set) var hasSubjectAltName = false
    private(set) var authorityKeyID: [UInt8]? = nil
    private(set) var subjectKeyID: [UInt8]? = nil
    private(set) var nameConstraints: X509NameConstraints? = nil
    /// The OID of the first critical extension we don't understand.
    private(set) var unknownCriticalExtension: String? = nil

    var isSelfIssued: Bool { subject.matches(issuer) }

    init(der: [UInt8]) throws(X509Error) {
        guard der.count <= X509Certificate.maxSize else { throw .malformed("too large") }
        var top = ASN1Reader(der)
        guard let certEl = top.expect(ASN1.sequence), top.atEnd, !top.failed else {
            throw .malformed("not a DER SEQUENCE")
        }
        guard var cert = certEl.children(),
              let tbsEl = cert.expect(ASN1.sequence),
              let sigAlgEl = cert.expect(ASN1.sequence),
              let sigEl = cert.expect(ASN1.bitString), cert.atEnd, !cert.failed else {
            throw .malformed("Certificate structure")
        }
        guard let sig = sigEl.bitString() else { throw .malformed("signature bits") }
        self.der = der
        self.tbs = tbsEl.encoded
        self.signature = sig
        self.signatureAlgorithm = try x509ParseSignatureAlgorithm(sigAlgEl)

        guard var t = tbsEl.children() else { throw .malformed("TBSCertificate") }
        var version = 1
        if let v = t.optional(context: 0) {
            guard var vr = v.children(), let vi = vr.expect(ASN1.integer)?.smallInt(), vr.atEnd,
                  vi <= 2 else { throw .malformed("version") }
            guard vi != 0 else { throw .malformed("explicit v1 version") }  // DER: DEFAULT omitted
            version = vi + 1
        }
        self.version = version
        // Serial numbers are leniently parsed (some anchors carry negative or
        // over-long ones); they only identify the certificate.
        guard let serialEl = t.expect(ASN1.integer), serialEl.length >= 1, serialEl.length <= 64 else {
            throw .malformed("serial")
        }
        self.serial = serialEl.contentBytes
        guard let innerAlg = t.expect(ASN1.sequence) else { throw .malformed("tbs signature") }
        guard innerAlg.encoded == sigAlgEl.encoded else { throw .malformed("signature algorithm mismatch") }
        guard let issuerEl = t.expect(ASN1.sequence) else { throw .malformed("issuer") }
        self.issuer = try x509ParseName(issuerEl)
        guard let validity = t.expect(ASN1.sequence), var vr = validity.children(),
              let nb = vr.next()?.time(), let na = vr.next()?.time(), vr.atEnd, !vr.failed else {
            throw .malformed("validity")
        }
        self.notBefore = nb
        self.notAfter = na
        guard let subjectEl = t.expect(ASN1.sequence) else { throw .malformed("subject") }
        self.subject = try x509ParseName(subjectEl)
        guard let spkiEl = t.expect(ASN1.sequence) else { throw .malformed("subjectPublicKeyInfo") }
        self.spki = spkiEl.encoded
        self.publicKey = try x509ParsePublicKey(spkiEl)
        if version >= 2 {
            _ = t.optional(context: 1, constructed: false)   // issuerUniqueID
            _ = t.optional(context: 2, constructed: false)   // subjectUniqueID
        }
        if let extWrap = t.optional(context: 3) {
            guard version == 3 else { throw .malformed("extensions in a v1/v2 certificate") }
            guard var w = extWrap.children(), let exts = w.expect(ASN1.sequence), w.atEnd else {
                throw .malformed("extensions")
            }
            try parseExtensions(exts)
        }
        guard t.atEnd, !t.failed else { throw .malformed("trailing TBSCertificate data") }
    }

    private mutating func parseExtensions(_ exts: ASN1Element) throws(X509Error) {
        guard var r = exts.children() else { throw .malformed("extensions") }
        var seen: [ASN1OID] = []
        while let ext = r.next() {
            guard seen.count < X509Certificate.maxExtensions else { throw .malformed("too many extensions") }
            guard ext.is(ASN1.sequence), var e = ext.children(),
                  let oid = e.expect(ASN1.objectIdentifier)?.oid() else { throw .malformed("extension") }
            var critical = false
            if let c = e.optional(ASN1.boolean) {
                guard let v = c.boolean(), v else { throw .malformed("extension critical flag") }  // DER: FALSE omitted
                critical = v
            }
            guard let value = e.expect(ASN1.octetString), e.atEnd, !e.failed else {
                throw .malformed("extension value")
            }
            for s in seen where s == oid { throw .malformed("duplicate extension \(oid.dotted)") }
            seen.append(oid)
            guard var v = value.contentReader() else { throw .malformed("extension nesting") }
            if oid == X509OID.basicConstraints {
                try parseBasicConstraints(&v)
            } else if oid == X509OID.keyUsage {
                guard let ku = v.expect(ASN1.bitString)?.bitStringBits(), v.atEnd, !ku.bytes.isEmpty else {
                    throw .malformed("keyUsage")
                }
                var bits: UInt16 = 0
                for i in 0..<min(ku.bytes.count * 8, 16) where ku.bytes[i / 8] & (0x80 >> UInt8(i % 8)) != 0 {
                    bits |= 1 << UInt16(i)
                }
                keyUsage = bits
            } else if oid == X509OID.extKeyUsage {
                guard let seq = v.expect(ASN1.sequence), v.atEnd, var kr = seq.children() else {
                    throw .malformed("extKeyUsage")
                }
                var list: [ASN1OID] = []
                while let k = kr.next() {
                    guard let o = k.oid(), list.count < 64 else { throw .malformed("extKeyUsage purpose") }
                    list.append(o)
                }
                guard !kr.failed, !list.isEmpty else { throw .malformed("extKeyUsage") }
                extendedKeyUsage = list
            } else if oid == X509OID.subjectAltName {
                try parseSubjectAltName(&v)
            } else if oid == X509OID.subjectKeyIdentifier {
                guard let k = v.expect(ASN1.octetString)?.octetString(), v.atEnd else {
                    throw .malformed("subjectKeyIdentifier")
                }
                subjectKeyID = k
            } else if oid == X509OID.authorityKeyIdentifier {
                guard let seq = v.expect(ASN1.sequence), v.atEnd, var ar = seq.children() else {
                    throw .malformed("authorityKeyIdentifier")
                }
                if let k = ar.optional(context: 0, constructed: false) { authorityKeyID = k.contentBytes }
                _ = ar.optional(context: 1)
                _ = ar.optional(context: 2, constructed: false)
                guard ar.atEnd, !ar.failed else { throw .malformed("authorityKeyIdentifier") }
            } else if oid == X509OID.nameConstraints {
                try parseNameConstraints(&v)
            } else if critical {
                // Policy extensions are understood well enough to ignore: we
                // do no policy processing (like browsers without EV UI).
                if !(oid == X509OID.certificatePolicies || oid == X509OID.policyConstraints
                     || oid == X509OID.policyMappings || oid == X509OID.inhibitAnyPolicy)
                    && unknownCriticalExtension == nil {
                    unknownCriticalExtension = oid.dotted
                }
            }
            guard !v.failed else { throw .malformed("extension \(oid.dotted)") }
        }
        guard !r.failed else { throw .malformed("extensions") }
    }

    private mutating func parseBasicConstraints(_ v: inout ASN1Reader) throws(X509Error) {
        guard let seq = v.expect(ASN1.sequence), v.atEnd, var b = seq.children() else {
            throw .malformed("basicConstraints")
        }
        hasBasicConstraints = true
        if let c = b.optional(ASN1.boolean) {
            guard let ca = c.boolean() else { throw .malformed("basicConstraints cA") }
            isCA = ca   // DER would omit FALSE; tolerated (common in the wild)
        }
        if let p = b.optional(ASN1.integer) {
            guard let n = p.smallInt(), n <= 255 else { throw .malformed("pathLenConstraint") }
            pathLength = n
        }
        guard b.atEnd, !b.failed else { throw .malformed("basicConstraints") }
    }

    private mutating func parseSubjectAltName(_ v: inout ASN1Reader) throws(X509Error) {
        guard let seq = v.expect(ASN1.sequence), v.atEnd, var r = seq.children() else {
            throw .malformed("subjectAltName")
        }
        hasSubjectAltName = true
        var n = 0
        while let g = r.next() {
            n += 1
            guard n <= X509Certificate.maxNames else { throw .malformed("too many subjectAltNames") }
            guard g.tagClass == ASN1.contextSpecific else { throw .malformed("GeneralName") }
            if g.tagNumber == 2 && !g.constructed {            // dNSName IA5String
                guard let s = x509ASCII(g.content) else { throw .malformed("dNSName") }
                dnsNames.append(s)
            } else if g.tagNumber == 7 && !g.constructed {     // iPAddress
                guard g.length == 4 || g.length == 16 else { throw .malformed("iPAddress") }
                ipAddresses.append(g.contentBytes)
            }
        }
        guard !r.failed, n > 0 else { throw .malformed("subjectAltName") }
    }

    private mutating func parseNameConstraints(_ v: inout ASN1Reader) throws(X509Error) {
        guard let seq = v.expect(ASN1.sequence), v.atEnd, var r = seq.children() else {
            throw .malformed("nameConstraints")
        }
        var nc = X509NameConstraints()
        var count = 0
        for which in 0..<2 {
            guard let subtrees = r.optional(context: UInt32(which)) else { continue }
            guard var sr = subtrees.children() else { throw .malformed("nameConstraints") }
            while let st = sr.next() {
                count += 1
                guard count <= X509Certificate.maxNames, st.is(ASN1.sequence), var gr = st.children(),
                      let base = gr.next(), base.tagClass == ASN1.contextSpecific else {
                    throw .malformed("GeneralSubtree")
                }
                if base.tagNumber == 2 && !base.constructed {
                    guard let s = x509ASCII(base.content) else { throw .malformed("nameConstraints dNSName") }
                    if which == 0 { nc.permittedDNS.append(s) } else { nc.excludedDNS.append(s) }
                } else if base.tagNumber == 7 && !base.constructed {
                    guard base.length == 8 || base.length == 32 else { throw .malformed("nameConstraints iPAddress") }
                    if which == 0 { nc.permittedIP.append(base.contentBytes) } else { nc.excludedIP.append(base.contentBytes) }
                } else {
                    nc.otherForms += 1
                }
            }
            guard !sr.failed else { throw .malformed("nameConstraints") }
        }
        guard r.atEnd, !r.failed else { throw .malformed("nameConstraints") }
        nameConstraints = nc
    }

    /// May `issuer` have issued this certificate, judging by names and key
    /// identifiers only (no signature check)?
    func couldBeIssued(by issuerCert: X509Certificate) -> Bool {
        guard issuer.matches(issuerCert.subject) else { return false }
        if let aki = authorityKeyID, let ski = issuerCert.subjectKeyID, aki != ski { return false }
        return true
    }

    /// Does `issuerCert`'s key verify this certificate's signature?
    func isSigned(by issuerCert: X509Certificate) -> X509Error? {
        x509VerifySignature(algorithm: signatureAlgorithm, key: issuerCert.publicKey, message: tbs, signature: signature)
    }
}

/// nil if the signature verifies; otherwise .badSignature or
/// .unsupportedAlgorithm.
func x509VerifySignature(algorithm: X509SignatureAlgorithm, key: X509PublicKey,
                         message: [UInt8], signature: [UInt8]) -> X509Error? {
    switch algorithm {
    case .rsaPKCS1(let h), .rsaPSS(let h, _):
        guard case .rsa(let n, let e) = key else { return .badSignature }
        guard let k = RSAPublicKey(modulus: n, exponent: e) else {
            return .unsupportedAlgorithm("RSA key of \(x509BitLength(n)) bits")
        }
        let digest = h.hash(message)
        if case .rsaPSS(_, let salt) = algorithm {
            return k.verifyPSS(signature: signature, digest: digest, hash: h, saltLength: salt) ? nil : .badSignature
        }
        return k.verifyPKCS1v15(signature: signature, digest: digest, hash: h) ? nil : .badSignature
    case .ecdsa(let h):
        let digest = h.hash(message)
        switch key {
        case .ecP256(let q): return P256.verify(publicKey: q, digest: digest, derSignature: signature) ? nil : .badSignature
        case .ecP384(let q): return P384.verify(publicKey: q, digest: digest, derSignature: signature) ? nil : .badSignature
        case .unsupported(let o): return .unsupportedAlgorithm(o)
        default: return .badSignature
        }
    case .ed25519: return .unsupportedAlgorithm("Ed25519")
    case .unsupported(let o): return .unsupportedAlgorithm(o)
    }
}

func x509ASCII(_ b: ArraySlice<UInt8>) -> String? {
    for c in b where c < 0x20 || c > 0x7e { return nil }
    return String(decoding: b, as: UTF8.self)
}

func x509ParseName(_ el: ASN1Element) throws(X509Error) -> X509Name {
    guard var r = el.children() else { throw .malformed("Name") }
    var attrs: [X509Name.Attribute] = []
    var rdn = 0
    while let set = r.next() {
        guard set.is(ASN1.set), var sr = set.children() else { throw .malformed("RelativeDistinguishedName") }
        var n = 0
        while let atv = sr.next() {
            n += 1
            guard attrs.count < 64, atv.is(ASN1.sequence), var ar = atv.children(),
                  let oid = ar.expect(ASN1.objectIdentifier)?.oid(), let value = ar.next(), ar.atEnd, !ar.failed else {
                throw .malformed("AttributeTypeAndValue")
            }
            // Unknown value types (rare, non-string) display as "#hex".
            var text = value.string() ?? ""
            if value.string() == nil {
                let digits: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
                text = "#"
                for b in value.encoded.prefix(32) { text.append(digits[Int(b >> 4)]); text.append(digits[Int(b & 15)]) }
            }
            attrs.append(X509Name.Attribute(oid: oid, value: text, rdnIndex: rdn))
        }
        guard !sr.failed, n > 0 else { throw .malformed("RelativeDistinguishedName") }
        rdn += 1
    }
    guard !r.failed else { throw .malformed("Name") }
    return X509Name(der: el.encoded, attributes: attrs)
}

func x509HashForOID(_ o: ASN1OID) -> CryptoHashAlgorithm? {
    if o == X509OID.sha256 { return .sha256 }
    if o == X509OID.sha384 { return .sha384 }
    if o == X509OID.sha512 { return .sha512 }
    return nil
}

/// AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters ANY OPTIONAL }
func x509ParseSignatureAlgorithm(_ el: ASN1Element) throws(X509Error) -> X509SignatureAlgorithm {
    guard var r = el.children(), let oid = r.expect(ASN1.objectIdentifier)?.oid() else {
        throw .malformed("AlgorithmIdentifier")
    }
    let params = r.next()
    guard r.atEnd, !r.failed else { throw .malformed("AlgorithmIdentifier") }
    let nullOrAbsent = params.map { $0.null() } ?? true
    if oid == X509OID.sha256WithRSA || oid == X509OID.sha384WithRSA || oid == X509OID.sha512WithRSA {
        guard nullOrAbsent else { throw .malformed("RSA signature parameters") }
        return .rsaPKCS1(oid == X509OID.sha256WithRSA ? .sha256 : oid == X509OID.sha384WithRSA ? .sha384 : .sha512)
    }
    if oid == X509OID.ecdsaSHA256 || oid == X509OID.ecdsaSHA384 || oid == X509OID.ecdsaSHA512 {
        guard params == nil else { throw .malformed("ECDSA signature parameters") }
        return .ecdsa(oid == X509OID.ecdsaSHA256 ? .sha256 : oid == X509OID.ecdsaSHA384 ? .sha384 : .sha512)
    }
    if oid == X509OID.ed25519 {
        guard params == nil else { throw .malformed("Ed25519 parameters") }
        return .ed25519
    }
    if oid == X509OID.rsassaPSS {
        guard let p = params, p.is(ASN1.sequence) else { throw .malformed("RSASSA-PSS parameters") }
        return try x509ParsePSSParams(p)
    }
    if oid == X509OID.sha1WithRSA { return .unsupported("sha1WithRSAEncryption") }
    return .unsupported(oid.dotted)
}

/// RSASSA-PSS-params (RFC 4055): hash, MGF1 with the same hash, salt length;
/// SHA-1 defaults are unsupported.
func x509ParsePSSParams(_ p: ASN1Element) throws(X509Error) -> X509SignatureAlgorithm {
    guard var r = p.children() else { throw .malformed("RSASSA-PSS parameters") }
    var hash: CryptoHashAlgorithm? = nil
    var mgfHash: CryptoHashAlgorithm? = nil
    var salt = 20
    func hashAlg(_ el: ASN1Element) -> (known: Bool, hash: CryptoHashAlgorithm?) {
        guard var ar = el.children(), let o = ar.expect(ASN1.objectIdentifier)?.oid() else { return (false, nil) }
        if let n = ar.next() { guard n.null(), ar.atEnd else { return (false, nil) } }
        guard !ar.failed else { return (false, nil) }
        return (true, x509HashForOID(o))
    }
    if let h0 = r.optional(context: 0) {
        guard var hr = h0.children(), let a = hr.expect(ASN1.sequence), hr.atEnd else { throw .malformed("PSS hash") }
        let h = hashAlg(a)
        guard h.known else { throw .malformed("PSS hash") }
        guard let hh = h.hash else { return .unsupported("RSASSA-PSS with SHA-1") }
        hash = hh
    }
    if let m1 = r.optional(context: 1) {
        guard var mr = m1.children(), let a = mr.expect(ASN1.sequence), mr.atEnd, var ar = a.children(),
              let o = ar.expect(ASN1.objectIdentifier)?.oid(), let inner = ar.expect(ASN1.sequence), ar.atEnd else {
            throw .malformed("PSS mask generation")
        }
        guard o == X509OID.mgf1 else { return .unsupported("RSASSA-PSS mask \(o.dotted)") }
        let h = hashAlg(inner)
        guard h.known else { throw .malformed("PSS MGF1 hash") }
        mgfHash = h.hash
    }
    if let s2 = r.optional(context: 2) {
        guard var sr = s2.children(), let n = sr.expect(ASN1.integer)?.smallInt(), sr.atEnd, n <= 512 else {
            throw .malformed("PSS salt length")
        }
        salt = n
    }
    if let t3 = r.optional(context: 3) {
        guard var tr = t3.children(), tr.expect(ASN1.integer)?.smallInt() == 1, tr.atEnd else {
            throw .malformed("PSS trailer")
        }
    }
    guard r.atEnd, !r.failed else { throw .malformed("RSASSA-PSS parameters") }
    guard let h = hash, let mh = mgfHash, h == mh else { return .unsupported("RSASSA-PSS with SHA-1 or mixed hashes") }
    return .rsaPSS(h, saltLength: salt)
}

func x509ParsePublicKey(_ spki: ASN1Element) throws(X509Error) -> X509PublicKey {
    guard var r = spki.children(), let alg = r.expect(ASN1.sequence),
          let keyBits = r.expect(ASN1.bitString), r.atEnd, !r.failed,
          var ar = alg.children(), let oid = ar.expect(ASN1.objectIdentifier)?.oid() else {
        throw .malformed("SubjectPublicKeyInfo")
    }
    let params = ar.next()
    guard ar.atEnd, !ar.failed else { throw .malformed("SubjectPublicKeyInfo algorithm") }
    guard let key = keyBits.bitString() else { throw .malformed("public key bits") }
    if oid == X509OID.rsaEncryption || oid == X509OID.rsassaPSS {
        if oid == X509OID.rsaEncryption, let p = params, !p.null() { throw .malformed("RSA key parameters") }
        var kr = ASN1Reader(key)
        guard let seq = kr.expect(ASN1.sequence), kr.atEnd, var sr = seq.children(),
              let n = sr.expect(ASN1.integer)?.unsignedInteger(), let e = sr.expect(ASN1.integer)?.unsignedInteger(),
              sr.atEnd, !sr.failed else { throw .malformed("RSAPublicKey") }
        guard n.count <= 1024, e.count <= 64 else { return .unsupported("RSA key too large") }
        return .rsa(modulus: n, exponent: e)
    }
    if oid == X509OID.ecPublicKey {
        guard let p = params, let curve = p.oid() else { throw .malformed("EC key parameters") }
        if curve == X509OID.prime256v1 {
            guard key.count == 65, key[0] == 4 else { return .unsupported("compressed P-256 key") }
            return .ecP256(key)
        }
        if curve == X509OID.secp384r1 {
            guard key.count == 97, key[0] == 4 else { return .unsupported("compressed P-384 key") }
            return .ecP384(key)
        }
        if curve == X509OID.secp521r1 { return .unsupported("P-521") }
        return .unsupported("EC curve \(curve.dotted)")
    }
    if oid == X509OID.ed25519 {
        guard params == nil, key.count == 32 else { throw .malformed("Ed25519 key") }
        return .ed25519(key)
    }
    return .unsupported(oid.dotted)
}
