// Part 7 (Phase 7C3): DNS resolver (RFC 1035): A queries over UDP, CNAME
// chains, retries, and a cache that honours TTLs.
//
// Every reply is hostile. `parseDNS` reads through a bounds-checked
// ByteReader, never trusts a length or an offset, and gives up (nil) on
// anything malformed. Name compression pointers must point strictly backward
// (so a loop is impossible) and at most 16 are followed per name; labels are
// at most 63 bytes and a name 255. Only the question and answer sections are
// parsed. A reply is accepted only from the server and port we asked, with
// our id and the question we sent, so a stray or spoofed packet is ignored
// and the query keeps waiting.

struct DNSQuestion {
    var name: [UInt8] // dotted, lower case
    var type: UInt16
    var cls: UInt16
}

enum DNSRData {
    case a(IPv4Addr)
    case cname([UInt8])
    case other
}

struct DNSRecord {
    var name: [UInt8]
    var type: UInt16
    var cls: UInt16
    var ttl: UInt32
    var data: DNSRData
}

struct DNSMessage {
    var id: UInt16
    var flags: UInt16
    var questions: [DNSQuestion]
    var answers: [DNSRecord]

    var isResponse: Bool { flags & 0x8000 != 0 }
    var opcode: UInt16 { (flags >> 11) & 0xF }
    var truncated: Bool { flags & 0x0200 != 0 }
    var rcode: UInt16 { flags & 0xF }
}

/// Decode a possibly compressed name starting at `start`. Returns the dotted
/// lower-case name and the offset just past it in the original position (past
/// the first pointer, if any). nil if malformed.
func dnsReadName(_ b: [UInt8], _ start: Int) -> (name: [UInt8], end: Int)? {
    var pos = start
    var end = -1
    var jumps = 0
    var out: [UInt8] = []
    var wire = 0
    while true {
        guard pos >= 0, pos < b.count else { return nil }
        let len = Int(b[pos])
        if len == 0 {
            if end < 0 { end = pos + 1 }
            return (out, end)
        }
        if len & 0xC0 == 0xC0 {
            guard pos + 1 < b.count else { return nil }
            let target = (len & 0x3F) << 8 | Int(b[pos + 1])
            if end < 0 { end = pos + 2 }
            jumps += 1
            // Strictly backward: a pointer can never revisit a position.
            guard jumps <= 16, target < pos else { return nil }
            pos = target
            continue
        }
        guard len & 0xC0 == 0, len <= 63, pos + 1 + len <= b.count else { return nil }
        wire += len + 1
        guard wire < 255 else { return nil }
        if !out.isEmpty { out.append(0x2E) }
        for i in 0..<len {
            let c = b[pos + 1 + i]
            out.append(c >= 0x41 && c <= 0x5A ? c + 32 : c)
        }
        pos += 1 + len
    }
}

/// Parse a DNS message (header, questions, answers). nil if malformed.
func parseDNS(_ b: [UInt8]) -> DNSMessage? {
    var r = ByteReader(b)
    guard let id = r.u16(), let flags = r.u16(), let qd = r.u16(), let an = r.u16(), r.skip(4),
          qd <= 16, an <= 256
    else { return nil }
    var m = DNSMessage(id: id, flags: flags, questions: [], answers: [])
    for _ in 0..<Int(qd) {
        guard let n = dnsReadName(b, r.offset), r.seek(n.end), let t = r.u16(), let c = r.u16() else { return nil }
        m.questions.append(DNSQuestion(name: n.name, type: t, cls: c))
    }
    for _ in 0..<Int(an) {
        guard let n = dnsReadName(b, r.offset), r.seek(n.end), let t = r.u16(), let c = r.u16(), let ttl = r.u32(),
              let rdlen = r.u16()
        else { return nil }
        let rdStart = r.offset
        guard r.skip(Int(rdlen)) else { return nil }
        var data = DNSRData.other
        if c == 1 && t == 1 && rdlen == 4 {
            data = .a(UInt32(b[rdStart]) << 24 | UInt32(b[rdStart + 1]) << 16 | UInt32(b[rdStart + 2]) << 8 | UInt32(b[rdStart + 3]))
        } else if c == 1 && t == 5 {
            guard let target = dnsReadName(b, rdStart), target.end <= rdStart + Int(rdlen) else { return nil }
            data = .cname(target.name)
        }
        m.answers.append(DNSRecord(name: n.name, type: t, cls: c, ttl: ttl, data: data))
    }
    return m
}

/// A host name as a normalized dotted lower-case byte string: labels of 1-63
/// letters, digits, '-' or '_', at most 253 bytes; one trailing dot allowed.
func dnsNormalize(_ s: String) -> [UInt8]? {
    var bytes = Array(s.utf8)
    if bytes.last == 0x2E { bytes.removeLast() }
    guard !bytes.isEmpty, bytes.count <= 253 else { return nil }
    var labelLength = 0
    for i in 0..<bytes.count {
        let c = bytes[i]
        if c == 0x2E {
            guard labelLength > 0 else { return nil }
            labelLength = 0
            continue
        }
        let ok = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x2D || c == 0x5F
        guard ok else { return nil }
        if c >= 0x41 && c <= 0x5A { bytes[i] = c + 32 }
        labelLength += 1
        guard labelLength <= 63 else { return nil }
    }
    return labelLength > 0 ? bytes : nil
}

/// Wire format query for an A record.
func dnsBuildQuery(id: UInt16, name: [UInt8]) -> [UInt8] {
    var q: [UInt8] = [UInt8(truncatingIfNeeded: id >> 8), UInt8(truncatingIfNeeded: id), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
    var label: [UInt8] = []
    for c in name + [0x2E] {
        if c == 0x2E {
            q.append(UInt8(label.count))
            q.append(contentsOf: label)
            label.removeAll(keepingCapacity: true)
        } else {
            label.append(c)
        }
    }
    q.append(0)
    q.append(contentsOf: [0, 1, 0, 1]) // type A, class IN
    return q
}

enum DNSError {
    case badName, noServer, timeout, nxdomain, serverFailure, noAddress, truncated, tooManyCNAMEs, sendFailed

    var message: String {
        switch self {
        case .badName: return "invalid host name"
        case .noServer: return "no DNS server configured"
        case .timeout: return "no answer from the DNS server (timed out)"
        case .nxdomain: return "NXDOMAIN (no such name)"
        case .serverFailure: return "the DNS server reported an error"
        case .noAddress: return "no IPv4 address in the answer"
        case .truncated: return "reply truncated (TCP fallback not supported)"
        case .tooManyCNAMEs: return "too many CNAMEs"
        case .sendFailed: return "could not send the query"
        }
    }
}

enum DNSQueryState { case pending, done, failed }

final class DNSQuery {
    let name: String
    let normalized: [UInt8]
    /// The name being asked now (after following a CNAME to another query).
    var current: [UInt8]
    var server: IPv4Addr
    var port: UInt16
    var state = DNSQueryState.pending
    var addresses: [IPv4Addr] = []
    var error: DNSError?
    var fromCache = false
    var id: UInt16 = 0
    var attempts = 0
    var chain = 0
    var timerGeneration = 0
    var socket: UDPSocket?
    /// CNAME targets followed, in order (for `host`).
    var aliases: [[UInt8]] = []
    /// Called once, from netd, when the query leaves .pending.
    var onFinish: (() -> Void)?

    init(name: String, normalized: [UInt8], server: IPv4Addr, port: UInt16) {
        self.name = name
        self.normalized = normalized
        current = normalized
        self.server = server
        self.port = port
    }
}

struct DNSCacheEntry {
    var name: [UInt8]
    var addresses: [IPv4Addr]
    var expires: UInt64
}

final class DNSResolver {
    let stack: NetStack
    var cache: [DNSCacheEntry] = []
    static let cacheMax = 32
    /// Per attempt, in ticks, and attempts before giving up.
    var timeoutTicks: UInt64 = 200
    var maxAttempts = 3
    var maxChain = 8
    static let maxTTL: UInt32 = 86400
    var queriesSent: UInt64 = 0
    var repliesAccepted: UInt64 = 0
    var repliesIgnored: UInt64 = 0
    var cacheHits: UInt64 = 0

    init(stack: NetStack) { self.stack = stack }

    /// Start resolving `name`. The result is in the returned query once its
    /// state leaves `.pending` (netd drives it; see `netBlock` for waiting).
    /// `server` defaults to the stack's DNS server.
    func start(_ name: String, server: IPv4Addr? = nil, port: UInt16 = 53) -> DNSQuery {
        let normalized = dnsNormalize(name) ?? []
        let q = DNSQuery(name: name, normalized: normalized, server: server ?? stack.dns, port: port)
        guard !normalized.isEmpty else { finish(q, error: .badName); return q }
        if let hit = cached(normalized) {
            cacheHits += 1
            q.addresses = hit
            q.fromCache = true
            q.state = .done
            return q
        }
        guard q.server != 0 else { finish(q, error: .noServer); return q }
        guard let s = stack.udpBind() else { finish(q, error: .sendFailed); return q }
        q.socket = s
        s.onReceive = { [self] in drain(q) }
        attempt(q)
        return q
    }

    func cached(_ name: [UInt8]) -> [IPv4Addr]? {
        var i = 0
        while i < cache.count {
            if cache[i].expires <= stack.now { cache.remove(at: i); continue }
            if cache[i].name == name { return cache[i].addresses }
            i += 1
        }
        return nil
    }

    private func store(_ name: [UInt8], _ addresses: [IPv4Addr], ttl: UInt32) {
        guard ttl > 0, !addresses.isEmpty else { return }
        cache.removeAll(where: { $0.name == name })
        if cache.count >= DNSResolver.cacheMax { cache.removeFirst() }
        cache.append(DNSCacheEntry(name: name, addresses: addresses,
                                   expires: stack.now &+ UInt64(min(ttl, DNSResolver.maxTTL)) * 100))
    }

    private func finish(_ q: DNSQuery, error: DNSError? = nil) {
        guard q.state == .pending else { return }
        q.timerGeneration += 1
        q.error = error
        q.state = error == nil ? .done : .failed
        q.socket?.close()
        q.socket = nil
        q.onFinish?()
    }

    /// Send (or resend) the question for q.current, and arm the timeout.
    private func attempt(_ q: DNSQuery) {
        guard q.state == .pending else { return }
        if q.attempts >= maxAttempts { finish(q, error: .timeout); return }
        q.attempts += 1
        if q.attempts == 1 { q.id = UInt16(truncatingIfNeeded: netRandom()) }
        queriesSent += 1
        guard let s = q.socket, s.send(to: q.server, port: q.port, dnsBuildQuery(id: q.id, name: q.current)) else {
            finish(q, error: .sendFailed)
            return
        }
        q.timerGeneration += 1
        let gen = q.timerGeneration
        stack.schedule(after: timeoutTicks) { [self] in
            guard q.state == .pending, q.timerGeneration == gen else { return }
            attempt(q)
        }
    }

    private func drain(_ q: DNSQuery) {
        guard let s = q.socket else { return }
        while let d = s.receive() {
            guard q.state == .pending else { return }
            handle(q, d)
        }
    }

    /// Process one datagram for `q` (also used directly by the tests).
    func handle(_ q: DNSQuery, _ d: UDPDatagram) {
        guard d.src == q.server, d.srcPort == q.port, let m = parseDNS(d.data), m.id == q.id, m.isResponse,
              m.opcode == 0, m.questions.count == 1, m.questions[0].type == 1, m.questions[0].cls == 1,
              m.questions[0].name == q.current
        else { repliesIgnored += 1; return }
        repliesAccepted += 1
        switch m.rcode {
        case 0: break
        case 3: finish(q, error: .nxdomain); return
        default: finish(q, error: .serverFailure); return
        }
        // Follow the CNAME chain inside the answer.
        var name = q.current
        var hops = 0
        var ttl = UInt32.max
        var addresses: [IPv4Addr] = []
        while true {
            for rec in m.answers where rec.name == name {
                if case .a(let addr) = rec.data, addresses.count < 8 {
                    addresses.append(addr)
                    ttl = min(ttl, rec.ttl)
                }
            }
            if !addresses.isEmpty { break }
            var next: [UInt8]? = nil
            var nextTTL: UInt32 = 0
            for rec in m.answers where rec.name == name {
                if case .cname(let target) = rec.data { next = target; nextTTL = rec.ttl; break }
            }
            guard let target = next, hops + q.chain < maxChain else { break }
            q.aliases.append(target)
            name = target
            ttl = min(ttl, nextTTL)
            hops += 1
        }
        if !addresses.isEmpty {
            q.addresses = addresses
            store(q.normalized, addresses, ttl: ttl)
            finish(q)
        } else if hops > 0 {
            // The chain ended at a name this reply doesn't answer: ask for it.
            q.chain += hops
            guard q.chain < maxChain else { finish(q, error: .tooManyCNAMEs); return }
            q.current = name
            q.attempts = 0
            attempt(q)
        } else if m.truncated {
            finish(q, error: .truncated)
        } else {
            finish(q, error: .noAddress)
        }
    }
}
