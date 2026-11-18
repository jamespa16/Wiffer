// TLS 1.3 record layer (RFC 8446 5).
//
//   var rl = TLSRecordLayer()
//   rl.append(received)                       // bytes from the transport
//   while let rec = try rl.next() { ... }     // (type, payload), decrypted
//                                             // once a read key is set
//   rl.readState = suite.cipherState(secret:) // key changes
//   out += rl.encode(type, payload)           // fragments, encrypts once a
//                                             // write key is set
//
// Ciphertext records: outer type application_data, version 0x0303, AAD =
// the 5-byte header, nonce = iv XOR the 64-bit sequence number. The inner
// plaintext is content || type || zero padding; padding is stripped on
// receipt (we send none). Limits: 2^14 bytes of plaintext, 2^14 + 256 of
// ciphertext; anything larger is record_overflow.

struct TLSCipherState {
    let aead: TLSAEAD
    let iv: [UInt8]
    let secret: [UInt8]          // the traffic secret (for KeyUpdate)
    var sequence: UInt64 = 0

    init(aead: TLSAEAD, iv: [UInt8], secret: [UInt8]) {
        self.aead = aead; self.iv = iv; self.secret = secret
    }

    func nonce() -> [UInt8] {
        var n = iv
        for i in 0..<8 { n[n.count - 1 - i] ^= UInt8(truncatingIfNeeded: sequence >> (UInt64(i) * 8)) }
        return n
    }
}

struct TLSRecord {
    let type: UInt8
    let payload: [UInt8]
    /// Was it protected (decrypted with the read key)?
    let encrypted: Bool
}

struct TLSRecordLayer {
    static let maxPlaintext = 1 << 14
    static let maxCiphertext = (1 << 14) + 256
    static let headerSize = 5

    var readState: TLSCipherState? = nil
    var writeState: TLSCipherState? = nil
    /// Largest plaintext fragment we send (lowered by record_size_limit).
    var maxSendFragment = maxPlaintext
    /// legacy_record_version of plaintext records we send: 0x0301 for the
    /// first ClientHello, 0x0303 afterwards (RFC 8446 5.1).
    var plaintextVersion: UInt16 = 0x0301

    private var input: [UInt8] = []
    private var inputPos = 0

    /// Bytes received but not yet consumed as whole records.
    var bufferedInput: Int { input.count - inputPos }

    mutating func append(_ bytes: [UInt8]) {
        if inputPos > 0 && inputPos >= input.count / 2 {
            input.removeFirst(inputPos)
            inputPos = 0
        }
        input.append(contentsOf: bytes)
    }

    /// The next complete record, nil if more bytes are needed.
    mutating func next() throws(TLSError) -> TLSRecord? {
        guard input.count - inputPos >= TLSRecordLayer.headerSize else { return nil }
        let p = inputPos
        let type = input[p]
        let length = Int(input[p + 3]) << 8 | Int(input[p + 4])
        guard type == TLSConst.changeCipherSpec || type == TLSConst.alert || type == TLSConst.handshake
                || type == TLSConst.applicationData else {
            throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "unknown record type \(type)")
        }
        // The version field is ignored (RFC 8446 5.1) beyond a sanity check
        // that this looks like TLS at all.
        guard input[p + 1] == 0x03 else {
            throw .protocolError(alert: TLSAlert.decodeError, reason: "not a TLS record")
        }
        let protected = readState != nil && type == TLSConst.applicationData
        guard length <= (protected ? TLSRecordLayer.maxCiphertext : TLSRecordLayer.maxPlaintext) else {
            throw .protocolError(alert: TLSAlert.recordOverflow, reason: "record too long")
        }
        guard input.count - p - TLSRecordLayer.headerSize >= length else { return nil }
        let header = Array(input[p..<(p + 5)])
        let body = Array(input[(p + 5)..<(p + 5 + length)])
        inputPos = p + 5 + length
        if inputPos == input.count { input.removeAll(keepingCapacity: true); inputPos = 0 }

        guard protected, var st = readState else {
            if type == TLSConst.applicationData {
                throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "application data before keys")
            }
            if length == 0 && type != TLSConst.applicationData {
                throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "empty record")
            }
            return TLSRecord(type: type, payload: body, encrypted: false)
        }
        guard length >= cryptoAEADTagSize + 1 else {
            throw .protocolError(alert: TLSAlert.badRecordMAC, reason: "record too short to decrypt")
        }
        guard let plain = st.aead.open(nonce: st.nonce(), aad: header, ciphertextAndTag: body) else {
            throw .protocolError(alert: TLSAlert.badRecordMAC, reason: "record failed to decrypt")
        }
        guard st.sequence < UInt64.max else {
            throw .protocolError(alert: TLSAlert.internalError, reason: "sequence number exhausted")
        }
        st.sequence += 1
        readState = st
        guard plain.count <= TLSRecordLayer.maxPlaintext + 1 else {
            throw .protocolError(alert: TLSAlert.recordOverflow, reason: "decrypted record too long")
        }
        // Strip the zero padding; the last non-zero byte is the real type.
        var end = plain.count
        while end > 0 && plain[end - 1] == 0 { end -= 1 }
        guard end > 0 else {
            throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "record with no content type")
        }
        let inner = plain[end - 1]
        guard inner == TLSConst.alert || inner == TLSConst.handshake || inner == TLSConst.applicationData else {
            throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "bad inner content type \(inner)")
        }
        if end - 1 == 0 && inner != TLSConst.applicationData {
            throw .protocolError(alert: TLSAlert.unexpectedMessage, reason: "empty record")
        }
        return TLSRecord(type: inner, payload: Array(plain[0..<(end - 1)]), encrypted: true)
    }

    /// Records carrying `payload` (split into fragments), encrypted if a
    /// write key is set.
    mutating func encode(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var off = 0
        repeat {
            let n = min(maxSendFragment, payload.count - off)
            let frag = Array(payload[off..<(off + n)])
            off += n
            if var st = writeState {
                let inner = frag + [type]
                let len = inner.count + cryptoAEADTagSize
                let header: [UInt8] = [TLSConst.applicationData, 0x03, 0x03, UInt8(len >> 8), UInt8(len & 0xff)]
                out += header
                out += st.aead.seal(nonce: st.nonce(), aad: header, plaintext: inner)
                st.sequence &+= 1
                writeState = st
            } else {
                out += [type, UInt8(plaintextVersion >> 8), UInt8(plaintextVersion & 0xff), UInt8(n >> 8), UInt8(n & 0xff)]
                out += frag
            }
        } while off < payload.count
        return out
    }

    /// A plaintext record regardless of keys (change_cipher_spec).
    func encodePlain(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [type, 0x03, 0x03, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)] + payload
    }
}
