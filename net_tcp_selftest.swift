// Part 7 (Phase 7D) selftests: TCP over LinkPair with virtual time, so every
// run is the same (seeded wire, seeded ISNs and ports). Bulk transfers check
// FNV-1a hashes of 1 MiB each way at 0, 5 and 20% loss with reordering and
// duplication; the rest walk the state machine (simultaneous open and close,
// RST in every state, RFC 5961 challenges), flow control (zero window and
// recovery), errors (closed port, ICMP, timeouts) and hostile segments.

let tcpTestSmall = TCPOptions(recvBuffer: 16384, sendBuffer: 16384, windowScale: true, noDelay: false)

/// A rig whose TCP layers use seeded ISNs and ports.
func tcpTestRig(seed: UInt64) -> NetRig {
    let rig = NetRig(seed: seed)
    rig.a.tcp.rng = NetRNG(seed: seed &* 31 &+ 7)
    rig.b.tcp.rng = NetRNG(seed: seed &* 17 &+ 3)
    return rig
}

/// Listen on b:port, connect from a, run until both ends are established.
/// (client on a, server on b, the listener)
func tcpTestPair(_ rig: NetRig, port: UInt16, client: TCPOptions = tcpTestSmall, server: TCPOptions = tcpTestSmall,
                 limit: Int = 3000) -> (TCPConnection, TCPConnection, TCPConnection)? {
    guard let l = rig.b.tcp.listener(port: port) ?? TCPConnection.listen(rig.b, port: port, backlog: 4, options: server),
          let c = TCPConnection.connect(rig.a, to: NetRig.ipB, port: port, options: client) else { return nil }
    var s: TCPConnection? = nil
    rig.run(until: {
        if s == nil { s = l.accept() }
        return s != nil && c.state == .established
    }, limit: limit)
    guard let s else { return nil }
    return (c, s, l)
}

/// A TCP segment as bytes, checksummed for src -> dst.
func netTestTCP(src: IPv4Addr, dst: IPv4Addr, sport: UInt16, dport: UInt16, seq: UInt32, ack: UInt32, flags: UInt8,
                window: UInt16 = 8192, options: [UInt8] = [], data: [UInt8] = [], goodChecksum: Bool = true) -> [UInt8] {
    let hl = 20 + options.count
    var s: [UInt8] = [UInt8(sport >> 8), UInt8(sport & 255), UInt8(dport >> 8), UInt8(dport & 255)]
    s += netTestWord(seq) + netTestWord(ack)
    s += [UInt8((hl / 4) << 4), flags, UInt8(window >> 8), UInt8(window & 255), 0, 0, 0, 0]
    s += options + data
    let c = csumFold(csumAdd(pseudoHeaderSum(src: src, dst: dst, proto: 6, length: s.count), s, 0, s.count)) ^ (goodChecksum ? 0 : 0x5A5A)
    s[16] = UInt8(c >> 8)
    s[17] = UInt8(c & 255)
    return s
}

/// Hand a raw IPv4 datagram to `target` as if its rig peer had sent it
/// (bypassing the wire, so it works while the link drops everything).
func tcpTestDeliver(_ rig: NetRig, to target: NetStack, src: IPv4Addr, _ segment: [UInt8]) {
    let peerMAC = target === rig.a ? rig.pair.b.mac : rig.pair.a.mac
    let ip = netTestIPv4(proto: 6, src: src, dst: target.ip, payload: segment)
    if let p = Packet.received(netTestFrame(dst: target.dev.mac, src: peerMAC, type: 0x0800, ip)) { target.receive(p) }
}

/// A segment from `conn`'s peer to `conn`.
func tcpTestInject(_ rig: NetRig, _ conn: TCPConnection, seq: UInt32, ack: UInt32 = 0, flags: UInt8, data: [UInt8] = []) {
    let seg = netTestTCP(src: conn.remoteIP, dst: conn.localIP, sport: conn.remotePort, dport: conn.localPort,
                         seq: seq, ack: ack, flags: flags, data: data)
    tcpTestDeliver(rig, to: conn.stack, src: conn.remoteIP, seg)
}

/// One direction of a test transfer: sends `data` then shuts down, and
/// hashes whatever arrives.
final class TCPTestStream {
    let conn: TCPConnection
    let data: [UInt8]
    var sent = 0
    var shut = false
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    var got = 0
    var buf = [UInt8](repeating: 0, count: 32768)
    /// Don't read (a stalled application).
    var paused = false

    init(_ conn: TCPConnection, _ data: [UInt8]) {
        self.conn = conn
        self.data = data
    }

    func pump() {
        while sent < data.count {
            let n = conn.send(data, from: sent)
            if n <= 0 { break }
            sent += n
        }
        if sent == data.count && !shut {
            shut = true
            conn.shutdown()
        }
        while !paused {
            let n = buf.withUnsafeMutableBytes { conn.receive(into: $0) }
            if n == 0 { break }
            hash = fnv1a64(buf[0..<n], hash)
            got += n
        }
    }

    var done: Bool { shut && conn.eof }
}

struct TCPBulkResult {
    var ok = false
    var virtualTicks = 0
    var realMs: UInt64 = 0
    var retransmits: UInt64 = 0
    var fastRetransmits: UInt64 = 0
    var timeouts: UInt64 = 0
    var closedClean = false
    var scalesOK = false
}

/// `size` bytes each way over one connection on a lossy wire.
func tcpTestBulk(seed: UInt64, loss: Int, reorder: Int, dup: Int, up: [UInt8], down: [UInt8],
                 isnA: UInt32? = nil, isnB: UInt32? = nil, limit: Int = 400_000) -> TCPBulkResult {
    var r = TCPBulkResult()
    let rig = tcpTestRig(seed: seed)
    rig.pair.delay = 1
    rig.a.tcp.mslTicks = 100
    rig.b.tcp.mslTicks = 100
    rig.a.tcp.nextISN = isnA
    rig.b.tcp.nextISN = isnB
    let opts = TCPOptions()
    let begin = ticks
    rig.pair.lossPct = loss
    rig.pair.reorderPct = reorder
    rig.pair.dupPct = dup
    guard let (c, s, l) = tcpTestPair(rig, port: 80, client: opts, server: opts, limit: 5000) else { return r }
    r.scalesOK = c.sndScale == s.rcvScale && s.sndScale == c.rcvScale && c.rcvScale == 2 && c.mss == 1460 && s.mss == 1460
    l.close()
    let x = TCPTestStream(c, up)
    let y = TCPTestStream(s, down)
    let start = rig.now
    rig.run(until: {
        x.pump()
        y.pump()
        return x.done && y.done && c.isClosed && s.isClosed
    }, limit: limit)
    r.virtualTicks = Int(rig.now - start)
    r.ok = x.got == down.count && y.got == up.count && x.hash == fnv1a64(down) && y.hash == fnv1a64(up)
        && c.error == nil && s.error == nil
    if !r.ok {
        print("  tcp: stuck at \(rig.now): up \(y.got) down \(x.got)")
        print("    " + c.debugLine)
        print("    " + s.debugLine)
    }
    r.retransmits = c.stats.retransmits + s.stats.retransmits
    r.fastRetransmits = c.stats.fastRetransmits + s.stats.fastRetransmits
    r.timeouts = c.stats.timeouts + s.stats.timeouts
    rig.run(until: { rig.a.tcp.connections.isEmpty && rig.b.tcp.connections.isEmpty }, limit: 2000)
    r.closedClean = rig.a.tcp.connections.isEmpty && rig.b.tcp.connections.isEmpty
    r.realMs = (ticks &- begin) * 10
    rig.a.tcp.reset()
    rig.b.tcp.reset()
    return r
}

func tcpTests(_ t: inout SelfTest) {
    tcpUnitTests(&t)
    tcpBulkTests(&t)
    tcpHandshakeTests(&t)
    tcpResetTests(&t)
    tcpFlowTests(&t)
    tcpErrorTests(&t)
    tcpHostileTests(&t)
}

func tcpUnitTests(_ t: inout SelfTest) {
    t.check("tcp: sequence comparisons wrap", tcpLT(0xFFFF_FFF0, 0x10) && tcpGT(0x10, 0xFFFF_FFF0) && tcpLEQ(5, 5) && !tcpLT(5, 5))
    var ring = TCPRing(capacity: 8)
    let a: [UInt8] = [1, 2, 3, 4, 5, 6]
    let w1 = a.withUnsafeBytes { ring.write($0) }
    var out = [UInt8](repeating: 0, count: 4)
    let r1 = out.withUnsafeMutableBytes { ring.read(into: $0) }
    let w2 = a.withUnsafeBytes { ring.write($0) } // wraps; only 6 of 6 fit (2 left + 4 read)
    var all = [UInt8](repeating: 0, count: 16)
    let r2 = all.withUnsafeMutableBytes { ring.read(into: $0) }
    t.check("tcp: the byte ring wraps and caps", w1 == 6 && r1 == 4 && out == [1, 2, 3, 4] && w2 == 6 && r2 == 8
            && Array(all[0..<8]) == [5, 6, 1, 2, 3, 4, 5, 6] && ring.count == 0)
    let syn = Packet.make()
    syn.append(netTestTCP(src: 1, dst: 2, sport: 1, dport: 2, seq: 9, ack: 0, flags: TCPFlag.syn,
                          options: [1, 2, 4, 5, 0xB4, 1, 3, 3, 30, 4, 2, 8, 10, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0]))
    let seg = parseTCPSegment(syn)
    t.check("tcp: SYN options parse (MSS, window scale clamped to 14, others skipped)",
            seg?.mss == 1460 && seg?.wscale == 14 && seg?.dataLen == 0 && seg?.seqLen == 1)
    let bad = Packet.make()
    bad.append(netTestTCP(src: 1, dst: 2, sport: 1, dport: 2, seq: 9, ack: 0, flags: TCPFlag.syn, options: [2, 0, 3, 3, 8, 1, 2, 255]))
    let segBad = parseTCPSegment(bad)
    t.check("tcp: malformed options stop parsing, not the segment", segBad != nil && segBad?.mss == nil && segBad?.wscale == nil)
    let short = Packet.make()
    short.append([0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0xF0, 2, 0, 0, 0, 0, 0, 0])
    t.check("tcp: a header longer than the segment is rejected", parseTCPSegment(short) == nil)
    syn.release(); bad.release(); short.release()
}

func tcpBulkTests(_ t: inout SelfTest) {
    let up = netTestBytes(1 << 20, seed: 0x7D01)
    let down = netTestBytes(1 << 20, seed: 0x7D02)
    let r0 = tcpTestBulk(seed: 101, loss: 0, reorder: 0, dup: 0, up: up, down: down)
    print("  tcp: 1 MiB each way, clean: \(r0.virtualTicks) ticks virtual, \(r0.realMs) ms real, \(r0.retransmits) retransmits")
    t.check("tcp: 1 MiB both ways on a clean wire, hashes match", r0.ok)
    t.check("tcp: clean wire needs no retransmissions", r0.retransmits == 0 && r0.timeouts == 0)
    t.check("tcp: MSS 1460 and window scale 2 negotiated both ways", r0.scalesOK)
    t.check("tcp: both ends close and leave the table after TIME_WAIT", r0.closedClean)
    let r5 = tcpTestBulk(seed: 105, loss: 5, reorder: 5, dup: 2, up: up, down: down)
    print("  tcp: 1 MiB each way, 5% loss: \(r5.virtualTicks) ticks virtual, \(r5.realMs) ms real, \(r5.retransmits) retransmits (\(r5.fastRetransmits) fast, \(r5.timeouts) timeouts)")
    t.check("tcp: 1 MiB both ways at 5% loss, reordering, duplication", r5.ok && r5.closedClean)
    t.check("tcp: 5% loss is repaired by fast retransmit too", r5.fastRetransmits > 0 && r5.retransmits > 0)
    let r20 = tcpTestBulk(seed: 120, loss: 20, reorder: 10, dup: 5, up: up, down: down)
    print("  tcp: 1 MiB each way, 20% loss: \(r20.virtualTicks) ticks virtual, \(r20.realMs) ms real, \(r20.retransmits) retransmits (\(r20.fastRetransmits) fast, \(r20.timeouts) timeouts)")
    t.check("tcp: 1 MiB both ways at 20% loss, reordering, duplication", r20.ok && r20.closedClean)
    // Sequence numbers that wrap during the transfer.
    let w = tcpTestBulk(seed: 130, loss: 5, reorder: 5, dup: 2, up: Array(up[0..<(256 * 1024)]), down: Array(down[0..<(256 * 1024)]),
                        isnA: 0xFFFF_FF00, isnB: 0xFFFE_0000)
    t.check("tcp: 256 KiB each way across sequence-number wraparound", w.ok && w.closedClean)
}

func tcpHandshakeTests(_ t: inout SelfTest) {
    let rig = tcpTestRig(seed: 201)
    guard let (c, s, l) = tcpTestPair(rig, port: 80) else { t.check("tcp: handshake through a listener", false); return }
    t.check("tcp: handshake through a listener", c.state == .established && s.state == .established
            && s.remotePort == c.localPort && c.localPort >= 49152 && l.state == .listen && l.acceptQueue.isEmpty)
    t.check("tcp: ISNs come from the layer, ACKs line up", c.rcvNxt == s.iss &+ 1 && s.rcvNxt == c.iss &+ 1)
    t.check("tcp: a second listener on the port is refused", TCPConnection.listen(rig.b, port: 80) == nil)

    // Simultaneous open: both sides connect to each other's fixed port.
    let x = TCPConnection.connect(rig.a, to: NetRig.ipB, port: 7001, localPort: 7002)!
    let y = TCPConnection.connect(rig.b, to: NetRig.ipA, port: 7002, localPort: 7001)!
    var sawSynReceived = false
    rig.run(until: {
        if x.state == .synReceived && y.state == .synReceived { sawSynReceived = true }
        return x.state == .established && y.state == .established
    }, limit: 1000)
    t.check("tcp: simultaneous open goes SYN_SENT -> SYN_RECEIVED -> ESTABLISHED on both", sawSynReceived
            && x.state == .established && y.state == .established && x.rcvNxt == y.sndNxt && y.rcvNxt == x.sndNxt)
    _ = x.send(Array("ping".utf8))
    _ = y.send(Array("pong".utf8))
    rig.run(until: { x.available == 4 && y.available == 4 }, limit: 100)
    t.check("tcp: data flows after a simultaneous open", x.receive() == Array("pong".utf8) && y.receive() == Array("ping".utf8))

    // Simultaneous close: both FINs cross; CLOSING on both, then TIME_WAIT.
    rig.pair.delay = 1 // so each side sees the other's FIN before its ACK
    x.shutdown()
    y.shutdown()
    var xClosing = false
    var yClosing = false
    let bothFW1 = x.state == .finWait1 && y.state == .finWait1
    rig.run(until: {
        if x.state == .closing { xClosing = true }
        if y.state == .closing { yClosing = true }
        return x.state == .timeWait && y.state == .timeWait
    }, limit: 1000)
    rig.pair.delay = 0
    t.check("tcp: simultaneous close goes FIN_WAIT_1 -> CLOSING -> TIME_WAIT on both", bothFW1 && xClosing && yClosing
            && x.state == .timeWait && y.state == .timeWait
            && x.eof && y.eof)

    // Backlog: SYNs beyond it are dropped, not answered.
    let fl = TCPConnection.listen(rig.b, port: 90, backlog: 3)!
    let dropsBefore = rig.b.tcp.stats.synDropped
    for i in 0..<10 {
        tcpTestDeliver(rig, to: rig.b, src: NetRig.ipA, netTestTCP(src: NetRig.ipA, dst: NetRig.ipB, sport: UInt16(30000 + i), dport: 90,
                                                                   seq: UInt32(i * 1000), ack: 0, flags: TCPFlag.syn))
    }
    t.check("tcp: the SYN backlog is bounded and costs no buffers", fl.children.count == 3 && rig.b.tcp.stats.synDropped == dropsBefore + 7
            && fl.children.allSatisfy { $0.state == .synReceived && $0.rcvBuf.capacity == 0 && $0.sendBuf.capacity == 0 })
    fl.close()
    t.check("tcp: closing a listener drops its half-open children", fl.children.isEmpty && rig.b.tcp.listener(port: 90) == nil
            && !rig.b.tcp.connections.contains(where: { $0.localPort == 90 }))

    // Connection table limit.
    rig.a.tcp.maxConnections = rig.a.tcp.connections.count
    t.check("tcp: the connection table is bounded", TCPConnection.connect(rig.a, to: NetRig.ipB, port: 80) == nil)
    rig.a.tcp.maxConnections = 64

    // Without window scaling on one side, neither scales.
    let ns = TCPOptions(recvBuffer: 128 * 1024, sendBuffer: 16384, windowScale: false, noDelay: false)
    if let (c2, s2, _) = tcpTestPair(rig, port: 80, client: ns, server: TCPOptions()) {
        t.check("tcp: window scaling needs both SYNs", c2.sndScale == 0 && c2.rcvScale == 0 && s2.sndScale == 0 && s2.rcvScale == 0
                && c2.sndWnd <= 65535 && s2.sndWnd <= 65535)
    } else {
        t.check("tcp: window scaling needs both SYNs", false)
    }
    _ = c; _ = s
    rig.a.tcp.reset()
    rig.b.tcp.reset()
}

func tcpResetTests(_ t: inout SelfTest) {
    let rig = tcpTestRig(seed: 301)
    func freeze() { rig.pair.lossPct = 100 }
    func thaw() { rig.pair.lossPct = 0 }
    guard let (c, s, l) = tcpTestPair(rig, port: 80) else { t.check("tcp: reset tests set up", false); return }

    // ESTABLISHED: RFC 5961 blind-reset checks, then a real reset.
    let challenges = s.stats.challengeAcks
    tcpTestInject(rig, s, seq: s.rcvNxt &+ 100, flags: TCPFlag.rst)
    t.check("tcp: an in-window RST with the wrong seq gets a challenge ACK", s.state == .established && s.stats.challengeAcks == challenges + 1)
    tcpTestInject(rig, s, seq: s.rcvNxt &+ 0x4000_0000, flags: TCPFlag.rst)
    t.check("tcp: an out-of-window RST is ignored silently", s.state == .established && s.stats.challengeAcks == challenges + 1)
    tcpTestInject(rig, s, seq: s.rcvNxt &+ 10, flags: TCPFlag.syn)
    t.check("tcp: a SYN on an established connection gets a challenge ACK", s.state == .established && s.stats.challengeAcks == challenges + 2)
    tcpTestInject(rig, s, seq: s.rcvNxt, ack: s.sndMax &+ 5000, flags: TCPFlag.ack, data: [1, 2, 3])
    t.check("tcp: an ACK for data never sent is dropped with its data", s.state == .established && s.available == 0)
    tcpTestInject(rig, s, seq: s.rcvNxt, flags: TCPFlag.rst)
    t.check("tcp: RST in ESTABLISHED (exact seq) resets", s.state == .closed && s.error == .reset)
    _ = c.send([1, 2, 3])
    rig.run(until: { c.error != nil }, limit: 200)
    t.check("tcp: the peer of a vanished connection is reset", c.state == .closed && c.error == .reset)

    // LISTEN: RSTs are ignored, ACKs answered with RST.
    let rstBefore = rig.b.tcp.stats.resetsSent
    tcpTestDeliver(rig, to: rig.b, src: NetRig.ipA, netTestTCP(src: NetRig.ipA, dst: NetRig.ipB, sport: 4444, dport: 80, seq: 1, ack: 0, flags: TCPFlag.rst))
    tcpTestDeliver(rig, to: rig.b, src: NetRig.ipA, netTestTCP(src: NetRig.ipA, dst: NetRig.ipB, sport: 4444, dport: 80, seq: 1, ack: 77, flags: TCPFlag.ack))
    t.check("tcp: RST in LISTEN is ignored, a stray ACK gets RST", l.state == .listen && l.children.isEmpty
            && rig.b.tcp.stats.resetsSent == rstBefore + 1)

    // SYN_SENT.
    freeze()
    let ss = TCPConnection.connect(rig.a, to: NetRig.ipB, port: 80)!
    rig.run(2)
    tcpTestInject(rig, ss, seq: 0, flags: TCPFlag.rst)
    tcpTestInject(rig, ss, seq: 0, ack: ss.iss &+ 9, flags: TCPFlag.rst | TCPFlag.ack)
    t.check("tcp: in SYN_SENT a RST without an acceptable ACK is ignored", ss.state == .synSent && ss.error == nil)
    tcpTestInject(rig, ss, seq: 0, ack: ss.iss &+ 1, flags: TCPFlag.rst | TCPFlag.ack)
    t.check("tcp: RST in SYN_SENT refuses the connection", ss.state == .closed && ss.error == .refused)

    // SYN_RECEIVED (passive): the child goes, the listener stays.
    thaw()
    let half = TCPConnection.connect(rig.a, to: NetRig.ipB, port: 80)!
    freeze()
    rig.run(2)
    let child = l.children.first
    t.check("tcp: a lost SYN-ACK leaves the child in SYN_RECEIVED", child?.state == .synReceived && half.state == .synSent)
    if let child { tcpTestInject(rig, child, seq: child.rcvNxt, flags: TCPFlag.rst) }
    t.check("tcp: RST in SYN_RECEIVED (passive) drops the child only", l.children.isEmpty && child?.state == .closed
            && l.state == .listen && l.acceptQueue.isEmpty)
    half.abort()

    // SYN_RECEIVED (active, simultaneous open).
    thaw()
    let p = TCPConnection.connect(rig.a, to: NetRig.ipB, port: 7101, localPort: 7102)!
    let q = TCPConnection.connect(rig.b, to: NetRig.ipA, port: 7102, localPort: 7101)!
    freeze()
    rig.run(2)
    let bothSR = p.state == .synReceived && q.state == .synReceived
    tcpTestInject(rig, p, seq: p.rcvNxt, flags: TCPFlag.rst)
    t.check("tcp: RST in SYN_RECEIVED (active) refuses the connection", bothSR && p.state == .closed && p.error == .refused)
    q.abort()

    // FIN_WAIT_1.
    thaw()
    if let (c1, _, _) = tcpTestPair(rig, port: 80) {
        freeze()
        c1.shutdown()
        let fw1 = c1.state == .finWait1
        tcpTestInject(rig, c1, seq: c1.rcvNxt, flags: TCPFlag.rst)
        t.check("tcp: RST in FIN_WAIT_1 resets", fw1 && c1.state == .closed && c1.error == .reset)
    } else { t.check("tcp: RST in FIN_WAIT_1 resets", false) }

    // FIN_WAIT_2 and CLOSE_WAIT.
    thaw()
    if let (c2, s2, _) = tcpTestPair(rig, port: 80) {
        c2.shutdown()
        rig.run(until: { c2.state == .finWait2 && s2.state == .closeWait }, limit: 200)
        let ok = c2.state == .finWait2 && s2.state == .closeWait && s2.eof
        freeze()
        tcpTestInject(rig, c2, seq: c2.rcvNxt, flags: TCPFlag.rst)
        tcpTestInject(rig, s2, seq: s2.rcvNxt, flags: TCPFlag.rst)
        t.check("tcp: RST in FIN_WAIT_2 and in CLOSE_WAIT resets", ok && c2.state == .closed && c2.error == .reset
                && s2.state == .closed && s2.error == .reset)
    } else { t.check("tcp: RST in FIN_WAIT_2 and in CLOSE_WAIT resets", false) }

    // CLOSING.
    thaw()
    if let (c3, s3, _) = tcpTestPair(rig, port: 80) {
        c3.shutdown()
        s3.shutdown()
        freeze()
        rig.run(until: { c3.state == .closing && s3.state == .closing }, limit: 10)
        let ok = c3.state == .closing && s3.state == .closing
        tcpTestInject(rig, c3, seq: c3.rcvNxt, flags: TCPFlag.rst)
        t.check("tcp: RST in CLOSING closes", ok && c3.state == .closed)
        s3.abort()
    } else { t.check("tcp: RST in CLOSING closes", false) }

    // LAST_ACK.
    thaw()
    if let (c4, s4, _) = tcpTestPair(rig, port: 80) {
        c4.shutdown()
        rig.run(until: { s4.state == .closeWait && c4.state == .finWait2 }, limit: 200)
        freeze()
        s4.close()
        let ok = s4.state == .lastAck
        tcpTestInject(rig, s4, seq: s4.rcvNxt, flags: TCPFlag.rst)
        t.check("tcp: RST in LAST_ACK closes", ok && s4.state == .closed)
        c4.abort()
    } else { t.check("tcp: RST in LAST_ACK closes", false) }

    // TIME_WAIT.
    thaw()
    if let (c5, s5, _) = tcpTestPair(rig, port: 80) {
        c5.shutdown()
        rig.run(until: { s5.state == .closeWait }, limit: 200)
        s5.close()
        rig.run(until: { c5.state == .timeWait && s5.state == .closed }, limit: 200)
        let ok = c5.state == .timeWait && rig.a.tcp.connections.contains(where: { $0 === c5 })
        tcpTestInject(rig, c5, seq: c5.rcvNxt, flags: TCPFlag.rst)
        t.check("tcp: RST in TIME_WAIT is ignored (RFC 1337)", ok && c5.state == .timeWait
                && rig.a.tcp.connections.contains(where: { $0 === c5 }))
        let outBefore = c5.stats.segsOut
        let lingerBefore = c5.lingerAt
        rig.run(5)
        tcpTestInject(rig, c5, seq: c5.rcvNxt &- 1, ack: c5.sndMax, flags: TCPFlag.fin | TCPFlag.ack)
        t.check("tcp: a retransmitted FIN in TIME_WAIT is ACKed and restarts 2 MSL", c5.state == .timeWait
                && c5.stats.segsOut == outBefore + 1 && c5.lingerAt == lingerBefore + 5)
    } else { t.check("tcp: RST in TIME_WAIT is ignored (RFC 1337)", false) }
    rig.a.tcp.reset()
    rig.b.tcp.reset()
}

func tcpFlowTests(_ t: inout SelfTest) {
    // Half close: the client stops sending, the server answers, then closes.
    let rig = tcpTestRig(seed: 401)
    guard let (c, s, _) = tcpTestPair(rig, port: 80) else { t.check("tcp: half close", false); return }
    let request = netTestBytes(1000, seed: 1)
    let reply = netTestBytes(40000, seed: 2)
    _ = c.send(request)
    c.shutdown()
    var gotRequest: [UInt8] = []
    rig.run(until: {
        gotRequest += s.receive()
        return s.eof && c.state == .finWait2
    }, limit: 500)
    t.check("tcp: half close: the server reads the request and EOF", gotRequest == request && s.state == .closeWait && c.state == .finWait2)
    let replyStream = TCPTestStream(s, reply)
    let clientStream = TCPTestStream(c, [])
    clientStream.shut = true
    rig.run(until: {
        replyStream.pump()
        clientStream.pump()
        return c.eof && s.state == .closed
    }, limit: 2000)
    t.check("tcp: half close: the reply still flows and both close", clientStream.got == reply.count && clientStream.hash == fnv1a64(reply)
            && c.state == .timeWait && s.state == .closed && c.error == nil && s.error == nil)
    rig.run(1990)
    let stillThere = rig.a.tcp.connections.contains(where: { $0 === c }) && c.state == .timeWait
    rig.run(20)
    t.check("tcp: TIME_WAIT lasts 2 x 10 s MSL", stillThere && !rig.a.tcp.connections.contains(where: { $0 === c }) && c.state == .closed)

    // Nagle: small writes coalesce while one is unacknowledged; noDelay sends each.
    guard let (n1, ns1, _) = tcpTestPair(rig, port: 80) else { t.check("tcp: Nagle", false); return }
    let delayedBefore = rig.b.tcp.stats.delayedAcks
    let segsBefore = n1.stats.dataSegsOut
    for i in 0..<10 { _ = n1.send([UInt8(i)]) }
    rig.run(until: { ns1.available == 10 && n1.sndUna == n1.sndMax }, limit: 200)
    t.check("tcp: Nagle coalesces small writes (10 bytes, 2 segments)", n1.stats.dataSegsOut - segsBefore == 2 && ns1.receive() == (0..<10).map { UInt8($0) })
    t.check("tcp: a lone small segment is ACKed late (delayed ACK)", rig.b.tcp.stats.delayedAcks > delayedBefore)
    n1.noDelay = true
    let segs2 = n1.stats.dataSegsOut
    for i in 0..<10 { _ = n1.send([UInt8(i)]) }
    rig.run(until: { ns1.available == 10 }, limit: 200)
    t.check("tcp: noDelay sends each small write", n1.stats.dataSegsOut - segs2 == 10)

    // Zero window: the server stops reading.
    let zrig = tcpTestRig(seed: 402)
    let tiny = TCPOptions(recvBuffer: 8192, sendBuffer: 16384, windowScale: true, noDelay: false)
    guard let (zc, zs, _) = tcpTestPair(zrig, port: 80, server: tiny) else { t.check("tcp: zero window", false); return }
    let payload = netTestBytes(65536, seed: 3)
    let sender = TCPTestStream(zc, payload)
    let reader = TCPTestStream(zs, [])
    reader.shut = true
    reader.paused = true
    zrig.run(until: { sender.pump(); return false }, limit: 3000) // 30 s with nobody reading
    let probes = zc.stats.probes
    t.check("tcp: a full receiver advertises a zero window", zs.available == 8192 && zc.sndWnd == 0 && zc.sendBuf.count > 0)
    t.check("tcp: the sender probes with backoff and does not give up", probes >= 3 && probes <= 12 && zc.state == .established
            && zc.error == nil && zc.stats.timeouts == 0)
    // The reader wakes up, but its window update is lost: a probe recovers.
    reader.paused = false
    zrig.pair.lossPct = 100
    reader.pump()
    zrig.step()
    zrig.pair.lossPct = 0
    zrig.run(until: { sender.pump(); reader.pump(); return reader.got == payload.count }, limit: 10000)
    t.check("tcp: after a lost window update a probe restarts the transfer", reader.got == payload.count && reader.hash == fnv1a64(payload)
            && zc.stats.probes > probes)
    zrig.a.tcp.reset()
    zrig.b.tcp.reset()
    rig.a.tcp.reset()
    rig.b.tcp.reset()
}

func tcpErrorTests(_ t: inout SelfTest) {
    let rig = tcpTestRig(seed: 501)
    // A closed port answers RST: the connection is refused, the callback fires.
    let c = TCPConnection.connect(rig.a, to: NetRig.ipB, port: 9999)!
    var events = 0
    c.onEvent = { _ in events += 1 }
    rig.run(until: { c.error != nil }, limit: 300)
    t.check("tcp: connecting to a closed port is refused (RST)", c.error == .refused && c.state == .closed && c.readable && c.writable
            && events >= 1 && rig.b.tcp.stats.noPort == 1)
    t.check("tcp: a refused connection can't send", c.send([1]) == -1)

    // Retransmission gives up.
    guard let (d, _, _) = tcpTestPair(rig, port: 80) else { t.check("tcp: timeouts", false); return }
    rig.a.tcp.maxRetries = 3
    rig.pair.lossPct = 100
    _ = d.send(netTestBytes(3000, seed: 9))
    rig.run(until: { d.error != nil }, limit: 30000)
    t.check("tcp: unacknowledged data times out after backed-off retries", d.error == .timedOut && d.stats.timeouts == 4)
    rig.a.tcp.maxSynRetries = 2
    let e = TCPConnection.connect(rig.a, to: NetRig.ipB, port: 80)!
    let start = rig.now
    rig.run(until: { e.error != nil }, limit: 30000)
    t.check("tcp: an unanswered SYN times out (1 + 2 + 4 s)", e.error == .timedOut && rig.now - start >= 700 && rig.now - start <= 800)
    rig.pair.lossPct = 0

    // ICMP protocol unreachable while connecting.
    rig.b.unregisterProtocol(6)
    let u = TCPConnection.connect(rig.a, to: NetRig.ipB, port: 80)!
    rig.run(until: { u.error != nil }, limit: 300)
    t.check("tcp: ICMP unreachable fails a connect", u.error == .unreachable)
    rig.a.tcp.reset()
    rig.b.tcp.reset()
}

func tcpHostileTests(_ t: inout SelfTest) {
    let rig = tcpTestRig(seed: 601)
    guard let (c, s, l) = tcpTestPair(rig, port: 80) else { t.check("tcp: hostile segments", false); return }
    var rng = NetRNG(seed: 6060)
    let badBefore = rig.b.tcp.stats.badChecksum + rig.b.tcp.stats.badHeader
    for i in 0..<3000 {
        let flags = UInt8(truncatingIfNeeded: rng.next()) & 0x3F
        var opts: [UInt8] = []
        if i % 3 == 0 { opts = (0..<(4 * rng.below(10))).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }
        let data = (0..<rng.below(64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        var seg: [UInt8]
        if i % 2 == 0 {
            // At the connection, always outside its receive window.
            seg = netTestTCP(src: NetRig.ipA, dst: NetRig.ipB, sport: c.localPort, dport: 80,
                             seq: s.rcvNxt &+ 0x1000_0000 &+ UInt32(truncatingIfNeeded: rng.next() >> 36),
                             ack: UInt32(truncatingIfNeeded: rng.next()), flags: flags, window: UInt16(truncatingIfNeeded: rng.next()),
                             options: opts, data: data, goodChecksum: i % 7 != 0)
        } else {
            // At the listener from random ports.
            seg = netTestTCP(src: NetRig.ipA, dst: NetRig.ipB, sport: UInt16(1 + rng.below(60000)), dport: 80,
                             seq: UInt32(truncatingIfNeeded: rng.next()), ack: UInt32(truncatingIfNeeded: rng.next()), flags: flags,
                             window: UInt16(truncatingIfNeeded: rng.next()), options: opts, data: data, goodChecksum: i % 7 != 0)
        }
        if i % 10 == 4 {
            // An in-window RST that isn't exact: a (rate-limited) challenge ACK.
            seg = netTestTCP(src: NetRig.ipA, dst: NetRig.ipB, sport: c.localPort, dport: 80,
                             seq: s.rcvNxt &+ 1 &+ UInt32(rng.below(1000)), ack: 0, flags: TCPFlag.rst)
        }
        if i % 11 == 0 { seg = Array(seg[0..<rng.below(seg.count + 1)]) } // truncated
        if i % 13 == 0 && seg.count > 12 { seg[12] = UInt8(truncatingIfNeeded: rng.next()) } // bogus data offset
        tcpTestDeliver(rig, to: rig.b, src: NetRig.ipA, seg)
        if i % 50 == 0 { rig.step() }
    }
    t.check("tcp: 3000 hostile segments did not trap the stack", rig.b.tcp.stats.badChecksum + rig.b.tcp.stats.badHeader > badBefore + 300)
    t.check("tcp: ... the connection survived them", s.state == .established && c.state == .established && s.available == 0)
    t.check("tcp: ... and the listener's backlog held", l.children.count + l.acceptQueue.count <= l.backlog
            && rig.b.tcp.connections.count <= rig.b.tcp.maxConnections)
    let data = netTestBytes(65536, seed: 4)
    let x = TCPTestStream(c, data)
    let y = TCPTestStream(s, [])
    y.shut = true
    rig.run(until: { x.pump(); y.pump(); return y.got == data.count }, limit: 3000)
    t.check("tcp: ... and still carries data intact", y.got == data.count && y.hash == fnv1a64(data))
    t.check("tcp: challenge ACKs are rate limited", rig.b.tcp.stats.challengeAcksLimited > 0)
    rig.a.tcp.reset()
    rig.b.tcp.reset()
}
