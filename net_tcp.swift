// Part 7 (Phase 7D): TCP (RFC 9293), the layer and the kernel API.
//
// `TCPLayer` (one per NetStack, `stack.tcp`) owns the connection table, the
// listeners, a single stack timer for every connection's deadlines, initial
// sequence numbers, ephemeral ports and resets for segments nobody wants.
// `TCPConnection` (net_tcp_conn.swift) is one endpoint: the state machine,
// buffers, retransmission and congestion control.
//
// Kernel API (used by the shell's tcpget/tcplisten and by 7E's sockets):
//
//   TCPConnection.connect(stack, to: ip, port: p) -> TCPConnection?
//   TCPConnection.listen(stack, port: p, backlog: n) -> TCPConnection?
//   listener.accept() -> TCPConnection?
//   c.send([UInt8]) / c.send(UnsafeRawBufferPointer) -> Int  (bytes queued; -1: can't send)
//   c.receive(max:) -> [UInt8] / c.receive(into:) -> Int     (0: nothing yet, see eof)
//   c.shutdown()  half close: FIN after the queued data, keep receiving
//   c.close()     full close: FIN after the queued data, no more reading
//                 (unread or later data resets the connection, RFC 2525)
//   c.abort()     RST now
//
// Readiness: `readable` (data, EOF, an error, or for a listener a connection
// to accept), `writable` (send space while sending is allowed, or an error),
// `isClosed` (nothing more will happen: CLOSED or TIME_WAIT), `error`
// (refused, reset, timed out, unreachable). `onEvent` is called from netd (or
// at the end of an API call) whenever any of those may have changed; it is a
// hint, so re-check the flags. Callbacks never run in the middle of segment
// processing, so they may call any API.
//
// Everything runs on CPU 0, unlocked: netd's poll, shell commands and (7E)
// syscalls hopped to CPU 0. Time is the stack's tick (100 Hz).
//
// Bounds: `maxConnections` table entries, a per-listener backlog (SYN_RECEIVED
// plus not yet accepted), per-connection send and receive buffers (allocated
// when established, so a SYN flood costs no buffers), and an out-of-order
// queue capped in segments and bytes. Every received byte is hostile: header
// fields are bounds-checked, options parsed defensively, sequence and
// acknowledgment numbers checked per RFC 9293 and RFC 5961.

enum TCPState: Equatable {
    case closed, listen, synSent, synReceived, established, finWait1, finWait2, closeWait, closing, lastAck, timeWait

    var name: String {
        switch self {
        case .closed: return "CLOSED"
        case .listen: return "LISTEN"
        case .synSent: return "SYN_SENT"
        case .synReceived: return "SYN_RECEIVED"
        case .established: return "ESTABLISHED"
        case .finWait1: return "FIN_WAIT_1"
        case .finWait2: return "FIN_WAIT_2"
        case .closeWait: return "CLOSE_WAIT"
        case .closing: return "CLOSING"
        case .lastAck: return "LAST_ACK"
        case .timeWait: return "TIME_WAIT"
        }
    }
}

enum TCPError: Equatable {
    /// RST in answer to our SYN.
    case refused
    /// RST on a synchronized connection.
    case reset
    /// No answer to (re)transmissions.
    case timedOut
    /// ICMP destination unreachable while connecting.
    case unreachable
    /// We aborted it (abort(), or close() with unread data).
    case aborted

    var message: String {
        switch self {
        case .refused: return "connection refused"
        case .reset: return "connection reset by peer"
        case .timedOut: return "connection timed out"
        case .unreachable: return "destination unreachable"
        case .aborted: return "connection aborted"
        }
    }
}

/// Per-connection settings (a listener's are inherited by what it accepts).
struct TCPOptions {
    var recvBuffer = 128 * 1024
    var sendBuffer = 64 * 1024
    /// Offer window scaling (RFC 7323) in our SYN.
    var windowScale = true
    /// Turn Nagle's algorithm off.
    var noDelay = false
}

enum TCPFlag {
    static let fin: UInt8 = 0x01
    static let syn: UInt8 = 0x02
    static let rst: UInt8 = 0x04
    static let psh: UInt8 = 0x08
    static let ack: UInt8 = 0x10
    static let urg: UInt8 = 0x20
}

// Sequence-space comparisons (mod 2^32).
@inline(__always) func tcpLT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
@inline(__always) func tcpLEQ(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) <= 0 }
@inline(__always) func tcpGT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }
@inline(__always) func tcpGEQ(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) >= 0 }

/// A parsed segment header. `dataStart` is relative to the packet's start.
struct TCPSegment {
    var srcPort: UInt16 = 0
    var dstPort: UInt16 = 0
    var seq: UInt32 = 0
    var ack: UInt32 = 0
    var flags: UInt8 = 0
    var window: UInt16 = 0
    var dataStart = 20
    var dataLen = 0
    /// SYN options (nil when absent).
    var mss: Int? = nil
    var wscale: Int? = nil

    var syn: Bool { flags & TCPFlag.syn != 0 }
    var fin: Bool { flags & TCPFlag.fin != 0 }
    var rst: Bool { flags & TCPFlag.rst != 0 }
    var hasAck: Bool { flags & TCPFlag.ack != 0 }
    /// Sequence space used: data plus SYN and FIN.
    var seqLen: Int { dataLen + (syn ? 1 : 0) + (fin ? 1 : 0) }
}

/// Parse a TCP header at `p.start` (the whole segment, trimmed to the IP
/// length). nil when it can't be a segment. Options are read only from SYNs;
/// a malformed option ends option parsing (the segment is still used).
func parseTCPSegment(_ p: Packet) -> TCPSegment? {
    guard let sport = p.u16(0), let dport = p.u16(2), let seq = p.u32(4), let ack = p.u32(8),
          let off = p.u8(12), let flags = p.u8(13), let window = p.u16(14) else { return nil }
    let hl = Int(off >> 4) * 4
    guard hl >= 20, hl <= p.length else { return nil }
    var s = TCPSegment()
    s.srcPort = sport
    s.dstPort = dport
    s.seq = seq
    s.ack = ack
    s.flags = flags & 0x3F
    s.window = window
    s.dataStart = hl
    s.dataLen = p.length - hl
    if s.syn {
        var i = 20
        while i < hl, let kind = p.u8(i) {
            if kind == 0 { break }
            if kind == 1 { i += 1; continue }
            guard i + 1 < hl, let len = p.u8(i + 1), len >= 2, i + Int(len) <= hl else { break }
            if kind == 2 && len == 4, let v = p.u16(i + 2) { s.mss = Int(v) }
            if kind == 3 && len == 3, let v = p.u8(i + 2) { s.wscale = min(Int(v), 14) } // RFC 7323 2.3
            i += Int(len)
        }
    }
    return s
}

struct TCPStats {
    var segsIn: UInt64 = 0
    var segsOut: UInt64 = 0
    var badHeader: UInt64 = 0
    var badChecksum: UInt64 = 0
    /// Segments for no connection or listener (answered with RST).
    var noPort: UInt64 = 0
    var resetsSent: UInt64 = 0
    var resetsReceived: UInt64 = 0
    /// SYNs dropped: backlog full or the table full.
    var synDropped: UInt64 = 0
    var challengeAcks: UInt64 = 0
    var challengeAcksLimited: UInt64 = 0
    var retransmits: UInt64 = 0
    var fastRetransmits: UInt64 = 0
    var timeouts: UInt64 = 0
    var probes: UInt64 = 0
    var delayedAcks: UInt64 = 0
    var outOfOrder: UInt64 = 0
    var outOfOrderDropped: UInt64 = 0
    var activeOpens: UInt64 = 0
    var passiveOpens: UInt64 = 0
}

final class TCPLayer {
    let stack: NetStack
    /// Every connection in the demultiplexing table (not the listeners).
    var connections: [TCPConnection] = []
    var listeners: [TCPConnection] = []
    var stats = TCPStats()

    // Tunables (ticks unless noted); tests shorten some of them.
    var maxConnections = 64
    var maxBacklog = 64
    /// Maximum segment lifetime: TIME_WAIT lasts two of these.
    var mslTicks: UInt64 = 1000
    var initialRTO: UInt64 = 100
    /// RFC 6298 says 1 s; like most stacks we allow 200 ms.
    var minRTO: UInt64 = 20
    var maxRTO: UInt64 = 6000
    /// Retransmissions of one segment before the connection times out.
    var maxRetries = 12
    var maxSynRetries = 5
    var delayedAckTicks: UInt64 = 4
    /// An orphaned (close()d) connection waits this long in FIN_WAIT_2.
    var finWait2Ticks: UInt64 = 6000
    var persistMin: UInt64 = 50
    var persistMax: UInt64 = 6000
    var oooMaxSegments = 64
    /// Challenge ACKs (RFC 5961 7) per second.
    var challengeAckLimit = 10

    /// Tests: a seeded generator for ISNs and ports (deterministic runs).
    var rng: NetRNG? = nil
    /// Tests: the next initial sequence number, once.
    var nextISN: UInt32? = nil

    private var secret0: UInt64 = 0
    private var secret1: UInt64 = 0
    private var timerID = 0
    private var timerAt = UInt64.max
    private var pending: [TCPConnection] = []
    private var flushing = false
    private var challengeStart: UInt64 = 0
    private var challengeTokens = 0

    init(stack: NetStack) {
        self.stack = stack
        secret0 = tcpHardwareRandom()
        secret1 = tcpHardwareRandom()
        stack.registerProtocol(6) { [self] h, p in input(h, p) }
        stack.setErrorHandler(proto: 6) { [self] e in icmpError(e) }
    }

    var now: UInt64 { stack.now }

    // MARK: Lookup

    func find(local: IPv4Addr, localPort: UInt16, remote: IPv4Addr, remotePort: UInt16) -> TCPConnection? {
        for c in connections where c.localPort == localPort && c.remotePort == remotePort && c.remoteIP == remote && c.localIP == local {
            return c
        }
        return nil
    }

    func listener(port: UInt16) -> TCPConnection? {
        listeners.first(where: { $0.localPort == port })
    }

    func portInUse(_ port: UInt16) -> Bool {
        listeners.contains(where: { $0.localPort == port }) || connections.contains(where: { $0.localPort == port })
    }

    /// 49152...65535 from a random start, skipping ports in use.
    func ephemeralPort() -> UInt16? {
        let span = 65536 - 49152
        let start = Int(truncatingIfNeeded: random() >> 40) % span
        for i in 0..<span {
            let p = UInt16(49152 + (start + i) % span)
            if !portInUse(p) { return p }
        }
        return nil
    }

    func random() -> UInt64 {
        if rng != nil { return rng!.next() }
        return netRandom()
    }

    /// RFC 6528: a clock (here the TSC / 4096, monotonic) plus a keyed hash
    /// of the connection's addresses, the key from RDRAND when available.
    func makeISN(local: IPv4Addr, localPort: UInt16, remote: IPv4Addr, remotePort: UInt16) -> UInt32 {
        if let n = nextISN { nextISN = nil; return n }
        if rng != nil { return UInt32(truncatingIfNeeded: rng!.next() >> 7) }
        let a = tcpMix(UInt64(local) << 32 | UInt64(remote) ^ secret0)
        let b = tcpMix(a ^ (UInt64(localPort) << 16 | UInt64(remotePort)) ^ secret1)
        return UInt32(truncatingIfNeeded: b) &+ UInt32(truncatingIfNeeded: rdtsc() >> 12)
    }

    // MARK: Timers

    /// Make sure the layer's timer fires no later than `at`.
    func arm(_ at: UInt64) {
        guard at < timerAt else { return }
        if timerID != 0 { stack.cancel(timerID) }
        timerAt = at
        timerID = stack.schedule(after: at > now ? at - now : 0) { [self] in fire() }
    }

    private func fire() {
        timerID = 0
        timerAt = UInt64.max
        let list = connections
        for c in list where c.nextDeadline <= now { c.runTimers() }
        var next = UInt64.max
        for c in connections where c.nextDeadline < next { next = c.nextDeadline }
        if next != UInt64.max { arm(max(next, now &+ 1)) }
        flushEvents()
    }

    // MARK: Events

    func notify(_ c: TCPConnection) {
        guard !c.notifyQueued, c.onEvent != nil else { return }
        c.notifyQueued = true
        pending.append(c)
    }

    /// Run queued readiness callbacks (outside segment processing).
    func flushEvents() {
        guard !flushing else { return }
        flushing = true
        var rounds = 0
        while !pending.isEmpty && rounds < 8 {
            rounds += 1
            let list = pending
            pending.removeAll()
            for c in list {
                c.notifyQueued = false
                c.onEvent?(c)
            }
        }
        flushing = false
    }

    // MARK: Table

    func add(_ c: TCPConnection) { connections.append(c) }

    func remove(_ c: TCPConnection) {
        if let i = connections.firstIndex(where: { $0 === c }) { connections.remove(at: i) }
        if let i = listeners.firstIndex(where: { $0 === c }) { listeners.remove(at: i) }
    }

    /// RFC 5961 7: a global budget of challenge ACKs per second.
    func challengeAllowed() -> Bool {
        if now &- challengeStart >= 100 { challengeStart = now; challengeTokens = challengeAckLimit }
        guard challengeTokens > 0 else { stats.challengeAcksLimited += 1; return false }
        challengeTokens -= 1
        stats.challengeAcks += 1
        return true
    }

    // MARK: Input

    /// Protocol 6 handler: `p` is at the TCP header (borrowed).
    func input(_ h: IPv4Header, _ p: Packet) {
        stats.segsIn += 1
        guard !h.broadcast, h.src != 0, !stack.isBroadcast(h.src), !isMulticastIP(h.src) else { stats.badHeader += 1; return }
        guard let seg = parseTCPSegment(p), seg.srcPort != 0, seg.dstPort != 0 else { stats.badHeader += 1; return }
        let sum = csumAdd(pseudoHeaderSum(src: h.src, dst: h.dst, proto: 6, length: p.length), p.buf, p.start, p.length)
        guard csumFold(sum) == 0 else { stats.badChecksum += 1; return }
        if seg.rst { stats.resetsReceived += 1 }
        if let c = find(local: h.dst, localPort: seg.dstPort, remote: h.src, remotePort: seg.srcPort) {
            // A new SYN for a TIME_WAIT pair, above the old sequence space,
            // may start a new incarnation (RFC 9293 3.10.7.4, RFC 6191).
            if c.state == .timeWait && seg.syn && !seg.hasAck && !seg.rst && tcpGT(seg.seq, c.rcvNxt),
               let l = listener(port: seg.dstPort) {
                c.finish()
                l.listenInput(h, seg)
            } else {
                c.segmentArrives(seg, p)
            }
        } else if let l = listener(port: seg.dstPort) {
            l.listenInput(h, seg)
        } else {
            stats.noPort += 1
            sendReset(h, seg)
        }
        flushEvents()
    }

    /// Answer a segment that has no connection (RFC 9293 3.10.7.1).
    func sendReset(_ h: IPv4Header, _ seg: TCPSegment) {
        guard !seg.rst else { return }
        if seg.hasAck {
            sendRaw(src: h.dst, srcPort: seg.dstPort, dst: h.src, dstPort: seg.srcPort, seq: seg.ack, ack: 0, flags: TCPFlag.rst)
        } else {
            sendRaw(src: h.dst, srcPort: seg.dstPort, dst: h.src, dstPort: seg.srcPort, seq: 0,
                    ack: seg.seq &+ UInt32(truncatingIfNeeded: seg.seqLen), flags: TCPFlag.rst | TCPFlag.ack)
        }
    }

    /// A bare segment (resets), not tied to a connection.
    func sendRaw(src: IPv4Addr, srcPort: UInt16, dst: IPv4Addr, dstPort: UInt16, seq: UInt32, ack: UInt32, flags: UInt8,
                 window: UInt16 = 0) {
        let p = Packet.make()
        p.appendU16(srcPort)
        p.appendU16(dstPort)
        p.appendU32(seq)
        p.appendU32(ack)
        p.appendU8(5 << 4)
        p.appendU8(flags)
        p.appendU16(window)
        p.appendU32(0) // checksum, urgent pointer
        p.setU16(16, csumFold(csumAdd(pseudoHeaderSum(src: src, dst: dst, proto: 6, length: p.length), p.buf, p.start, p.length)))
        stats.segsOut += 1
        if flags & TCPFlag.rst != 0 { stats.resetsSent += 1 }
        stack.sendIP(proto: 6, dst: dst, p, src: src)
    }

    /// ICMP errors about our segments (RFC 5927: only if the quoted sequence
    /// number is one we have outstanding).
    func icmpError(_ e: ICMPError) {
        guard let c = find(local: e.originalSrc, localPort: e.srcPort, remote: e.originalDst, remotePort: e.dstPort) else { return }
        guard tcpGEQ(e.seq, c.sndUna), tcpLEQ(e.seq, c.sndMax) else { return }
        c.icmpError(e)
        flushEvents()
    }

    /// Abort every connection and listener (tests, or the stack going away).
    func reset() {
        for c in connections { c.abort() }
        for l in listeners { l.abort() }
        connections.removeAll()
        listeners.removeAll()
        flushEvents()
    }
}

/// splitmix64's finalizer.
func tcpMix(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

/// 64 random bits: RDRAND (CPUID.1:ECX[30]) mixed with the TSC, or the TSC
/// and the stack's xorshift alone without it.
func tcpHardwareRandom() -> UInt64 {
    var v: UInt64 = 0
    if cpuid(1, 0).ecx & (1 << 30) != 0 && rdrand64(&v) != 0 { return v ^ tcpMix(rdtsc()) }
    return tcpMix(rdtsc() ^ netRandom())
}
