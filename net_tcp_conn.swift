// Part 7 (Phase 7D): one TCP endpoint. See net_tcp.swift for the API summary.
//
// Send side: `sendBuf` holds every byte from `sndBase` (the first unacked
// data byte) on; `sndNxt` is the next sequence number to send and `sndMax`
// the highest sent (an RTO rewinds sndNxt to sndUna, go-back-N). A queued FIN
// sits at `finSeq`, just after the data. Retransmission follows RFC 6298
// (Karn's rule, exponential backoff); congestion control is RFC 5681 slow
// start and congestion avoidance with fast retransmit and NewReno recovery
// (RFC 6582). Nagle (RFC 896) unless `noDelay`; sender SWS avoidance; a
// persist timer probes a zero window (a byte-less segment below sndUna, as
// Linux does, which any receiver answers with its window).
//
// Receive side: in-order data goes to `rcvBuf`; segments beyond rcvNxt wait in
// a bounded out-of-order queue. The advertised right edge never moves back,
// grows in steps of min(buffer/2, MSS) (receiver SWS avoidance), and is scaled
// by `rcvScale` (RFC 7323). ACKs are delayed (every second full segment, or
// `delayedAckTicks`) except for out-of-order data, holes filled, and FINs.

/// A fixed-capacity byte FIFO.
struct ByteRing {
    private(set) var storage: [UInt8] = []
    private(set) var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        if capacity > 0 { storage = [UInt8](repeating: 0, count: capacity) }
    }

    var capacity: Int { storage.count }
    var free: Int { storage.count - count }

    /// Append as much of `src` as fits; the number of bytes taken.
    mutating func write(_ src: UnsafeRawBufferPointer) -> Int {
        let n = min(src.count, free)
        guard n > 0, let base = src.baseAddress else { return 0 }
        let cap = storage.count
        var tail = head + count
        if tail >= cap { tail -= cap }
        let first = min(n, cap - tail)
        storage.withUnsafeMutableBytes { dst in
            (dst.baseAddress! + tail).copyMemory(from: base, byteCount: first)
            if n > first { dst.baseAddress!.copyMemory(from: base + first, byteCount: n - first) }
        }
        count += n
        return n
    }

    /// Copy `n` bytes starting `offset` bytes in (the caller checks the range).
    func copy(offset: Int, count n: Int, to dst: UnsafeMutableRawPointer) {
        guard n > 0 else { return }
        let cap = storage.count
        var s = head + offset
        if s >= cap { s -= cap }
        let first = min(n, cap - s)
        storage.withUnsafeBytes { src in
            dst.copyMemory(from: src.baseAddress! + s, byteCount: first)
            if n > first { (dst + first).copyMemory(from: src.baseAddress!, byteCount: n - first) }
        }
    }

    mutating func read(into dst: UnsafeMutableRawBufferPointer) -> Int {
        let n = min(dst.count, count)
        guard n > 0, let base = dst.baseAddress else { return 0 }
        copy(offset: 0, count: n, to: base)
        discard(n)
        return n
    }

    mutating func discard(_ n: Int) {
        let k = min(max(n, 0), count)
        head += k
        if head >= storage.count { head -= storage.count }
        count -= k
        if count == 0 { head = 0 }
    }

    /// Drop everything, including the storage.
    mutating func release() {
        storage = []
        head = 0
        count = 0
    }
}

struct TCPConnStats {
    var segsIn: UInt64 = 0
    var segsOut: UInt64 = 0
    var dataSegsOut: UInt64 = 0
    var bytesOut: UInt64 = 0
    var bytesIn: UInt64 = 0
    var retransmits: UInt64 = 0
    var fastRetransmits: UInt64 = 0
    var timeouts: UInt64 = 0
    var probes: UInt64 = 0
    var dupAcksIn: UInt64 = 0
    var outOfOrder: UInt64 = 0
    var challengeAcks: UInt64 = 0
}

struct TCPOutOfOrder {
    var seq: UInt32
    var data: [UInt8]
}

final class TCPConnection {
    let layer: TCPLayer
    var stack: NetStack { layer.stack }
    var now: UInt64 { layer.stack.now }
    let options: TCPOptions

    private(set) var state: TCPState = .closed
    var localIP: IPv4Addr = 0
    var localPort: UInt16 = 0
    var remoteIP: IPv4Addr = 0
    var remotePort: UInt16 = 0
    private(set) var error: TCPError? = nil
    /// The last ICMP error seen while synchronized (not fatal).
    var softError: ICMPError? = nil
    var noDelay: Bool
    var stats = TCPConnStats()

    /// Readiness callback (from netd or the end of an API call): re-check
    /// `readable`, `writable`, `isClosed`, `error`.
    var onEvent: ((TCPConnection) -> Void)?
    var notifyQueued = false

    // Listener state.
    var backlog = 0
    /// SYN_RECEIVED children, then established ones waiting for accept().
    var children: [TCPConnection] = []
    var acceptQueue: [TCPConnection] = []
    /// For a child: the listener until accepted.
    var parent: TCPConnection? = nil

    // Send sequence space.
    var iss: UInt32 = 0
    var sndUna: UInt32 = 0
    var sndNxt: UInt32 = 0
    var sndMax: UInt32 = 0
    var sndBase: UInt32 = 0
    var sndWnd = 0
    var maxSndWnd = 0
    var sndWl1: UInt32 = 0
    var sndWl2: UInt32 = 0
    var sendBuf = ByteRing(capacity: 0)
    var finQueued = false
    var finSent = false
    /// close() (not shutdown()): we won't read any more.
    var userClosed = false
    var finSeq: UInt32 { sndBase &+ UInt32(truncatingIfNeeded: sendBuf.count) }

    // Options.
    var mss = 536
    var sndScale = 0
    var rcvScale = 0
    var peerOfferedWS = false

    // Congestion control.
    var cwnd = 0
    var ssthresh = 1 << 30
    var dupAcks = 0
    var inRecovery = false
    var recover: UInt32 = 0

    // Retransmission.
    var rto: UInt64 = 100
    var srtt8 = 0
    var rttvar4 = 0
    var hasRTT = false
    var rttTiming = false
    var rttSeq: UInt32 = 0
    var rttStart: UInt64 = 0
    var retries = 0
    var synRetries = 0
    var backoffs = 0
    var persistBackoff = 0

    // Receive sequence space.
    var irs: UInt32 = 0
    var rcvNxt: UInt32 = 0
    /// Highest right edge advertised.
    var rcvAdv: UInt32 = 0
    var rcvBuf = ByteRing(capacity: 0)
    var ooo: [TCPOutOfOrder] = []
    var oooBytes = 0
    var oooFin: UInt32? = nil
    var peerFinished = false
    var unackedBytes = 0

    // Deadlines (UInt64.max: off).
    var rtoAt = UInt64.max
    var persistAt = UInt64.max
    var delAckAt = UInt64.max
    var lingerAt = UInt64.max
    var nextDeadline: UInt64 { min(min(rtoAt, persistAt), min(delAckAt, lingerAt)) }

    init(layer: TCPLayer, options: TCPOptions) {
        self.layer = layer
        self.options = options
        noDelay = options.noDelay
        rto = layer.initialRTO
    }

    // MARK: API

    /// Open a connection to `ip`:`port` (SYN sent at once). nil if there is
    /// no address yet, no free port, or the table is full.
    static func connect(_ stack: NetStack, to ip: IPv4Addr, port: UInt16, localPort: UInt16 = 0,
                        options: TCPOptions = TCPOptions()) -> TCPConnection? {
        let layer = stack.tcp!
        let local: IPv4Addr = ip >> 24 == 127 ? ip : stack.ip
        guard local != 0, port != 0, ip != 0, !stack.isBroadcast(ip), !isMulticastIP(ip),
              layer.connections.count < layer.maxConnections else { return nil }
        var lport = localPort
        if lport == 0 {
            guard let p = layer.ephemeralPort() else { return nil }
            lport = p
        } else if layer.find(local: local, localPort: lport, remote: ip, remotePort: port) != nil {
            return nil
        }
        let c = TCPConnection(layer: layer, options: options)
        c.localIP = local
        c.localPort = lport
        c.remoteIP = ip
        c.remotePort = port
        c.iss = layer.makeISN(local: local, localPort: lport, remote: ip, remotePort: port)
        c.sndUna = c.iss
        c.sndNxt = c.iss &+ 1
        c.sndMax = c.sndNxt
        c.sndBase = c.iss &+ 1
        c.recover = c.iss
        c.rttStart = layer.now
        c.allocateBuffers()
        c.state = .synSent
        layer.add(c)
        layer.stats.activeOpens += 1
        c.sendSYN()
        c.setRTO()
        return c
    }

    /// Listen on `port` (any local address). nil if the port has a listener.
    static func listen(_ stack: NetStack, port: UInt16, backlog: Int = 8, options: TCPOptions = TCPOptions()) -> TCPConnection? {
        let layer = stack.tcp!
        guard port != 0, layer.listener(port: port) == nil else { return nil }
        let c = TCPConnection(layer: layer, options: options)
        c.localPort = port
        c.backlog = max(1, min(backlog, layer.maxBacklog))
        c.state = .listen
        layer.listeners.append(c)
        return c
    }

    /// The next established connection, if any (listeners only).
    func accept() -> TCPConnection? {
        guard state == .listen, !acceptQueue.isEmpty else { return nil }
        let c = acceptQueue.removeFirst()
        c.parent = nil
        return c
    }

    var isListener: Bool { state == .listen }
    /// Bytes waiting to be read.
    var available: Int { rcvBuf.count }
    /// The peer sent FIN and everything before it has been read.
    var eof: Bool { peerFinished && rcvBuf.count == 0 }
    var connected: Bool {
        switch state {
        case .established, .finWait1, .finWait2, .closeWait, .closing, .lastAck, .timeWait: return true
        default: return false
        }
    }
    var canSend: Bool {
        (state == .established || state == .closeWait || state == .synSent || (state == .synReceived && parent == nil))
            && !finQueued && error == nil
    }
    var sendSpace: Int { canSend ? sendBuf.free : 0 }
    var readable: Bool { rcvBuf.count > 0 || peerFinished || error != nil || !acceptQueue.isEmpty }
    var writable: Bool {
        error != nil || ((state == .established || state == .closeWait) && !finQueued && sendBuf.free > 0)
    }
    /// Nothing more will happen on this connection.
    var isClosed: Bool { state == .closed || state == .timeWait }

    /// Queue bytes to send; how many were taken (0 when the buffer is full),
    /// or -1 if this connection can't send any more.
    func send(_ bytes: UnsafeRawBufferPointer) -> Int {
        guard canSend else { return -1 }
        let n = sendBuf.write(bytes)
        if n > 0 { output() }
        layer.flushEvents()
        return n
    }

    func send(_ data: [UInt8], from: Int = 0, count: Int? = nil) -> Int {
        let n = count ?? (data.count - from)
        guard from >= 0, n >= 0, from <= data.count - n else { return 0 }
        return data.withUnsafeBytes { send(UnsafeRawBufferPointer(start: $0.baseAddress! + from, count: n)) }
    }

    /// Copy received bytes out; 0 when there are none (check `eof`, `error`).
    func receive(into dst: UnsafeMutableRawBufferPointer) -> Int {
        let n = rcvBuf.read(into: dst)
        if n > 0 { windowOpened() }
        layer.flushEvents()
        return n
    }

    func receive(max: Int = 65536) -> [UInt8] {
        let n = min(max, rcvBuf.count)
        guard n > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: n)
        let got = out.withUnsafeMutableBytes { receive(into: $0) }
        if got < n { out.removeLast(n - got) }
        return out
    }

    /// Half close: send FIN after the queued data; keep receiving.
    func shutdown() {
        switch state {
        case .listen, .synSent:
            if state == .synSent { finish() } else { closeListener() }
        case .synReceived, .established, .closeWait:
            guard !finQueued else { break }
            finQueued = true
            if state == .established { state = .finWait1 }
            if state == .closeWait { state = .lastAck }
            output()
        default:
            break
        }
        layer.flushEvents()
    }

    /// Full close. Unread data turns it into a reset (RFC 2525 2.17).
    func close() {
        if state == .listen { closeListener(); layer.flushEvents(); return }
        userClosed = true
        if rcvBuf.count > 0 && connected && state != .timeWait {
            abort()
            return
        }
        shutdown()
        if state == .finWait2 { setLinger(layer.finWait2Ticks) }
    }

    /// RST now (if the peer knows about us) and forget the connection.
    func abort() {
        switch state {
        case .listen:
            closeListener()
        case .synReceived, .established, .finWait1, .finWait2, .closeWait:
            sendSegment(seq: sndNxt, flags: TCPFlag.rst | TCPFlag.ack)
            fail(.aborted)
        case .closed:
            break
        default:
            fail(.aborted)
        }
        layer.flushEvents()
    }

    private func closeListener() {
        for c in children + acceptQueue { c.parent = nil; c.abort() }
        children.removeAll()
        acceptQueue.removeAll()
        state = .closed
        layer.remove(self)
        layer.notify(self)
    }

    // MARK: Lifecycle

    func allocateBuffers() {
        if sendBuf.capacity == 0 { sendBuf = ByteRing(capacity: max(options.sendBuffer, 1024)) }
        if rcvBuf.capacity == 0 { rcvBuf = ByteRing(capacity: max(options.recvBuffer, 1024)) }
    }

    var rcvCapacity: Int { rcvBuf.capacity > 0 ? rcvBuf.capacity : max(options.recvBuffer, 1024) }

    /// The window scale we offer: the smallest that covers the buffer.
    var ourScale: Int {
        var s = 0
        while s < 14 && (65535 << s) < rcvCapacity { s += 1 }
        return s
    }

    /// Leave the table (state CLOSED). Received data stays readable.
    func finish() {
        guard state != .closed else { return }
        state = .closed
        rtoAt = UInt64.max
        persistAt = UInt64.max
        delAckAt = UInt64.max
        lingerAt = UInt64.max
        sendBuf.release()
        ooo.removeAll()
        oooBytes = 0
        if let p = parent {
            p.children.removeAll(where: { $0 === self })
            p.acceptQueue.removeAll(where: { $0 === self })
            parent = nil
        }
        layer.remove(self)
        layer.notify(self)
    }

    func fail(_ e: TCPError) {
        if error == nil { error = e }
        rcvBuf.release()
        finish()
    }

    private func becomeEstablished() {
        allocateBuffers()
        state = finQueued ? .finWait1 : .established
        if let p = parent {
            p.children.removeAll(where: { $0 === self })
            p.acceptQueue.append(self)
            layer.notify(p)
        }
        layer.notify(self)
    }

    private func enterTimeWait() {
        state = .timeWait
        rtoAt = UInt64.max
        persistAt = UInt64.max
        delAckAt = UInt64.max
        sendBuf.release()
        setLinger(2 * layer.mslTicks)
        layer.notify(self)
    }

    private func setLinger(_ ticks: UInt64) {
        lingerAt = now &+ ticks
        layer.arm(lingerAt)
    }

    private func setRTO() {
        rtoAt = now &+ rto
        layer.arm(rtoAt)
    }

    /// The MSS and window scale from the peer's SYN; the initial window.
    func applySynOptions(_ seg: TCPSegment, weOffered: Bool) {
        let ours = stack.dev.mtu - 40
        mss = max(64, min(seg.mss ?? 536, ours))
        if weOffered, let ws = seg.wscale {
            sndScale = ws
            rcvScale = ourScale
        } else {
            sndScale = 0
            rcvScale = 0
        }
        // RFC 5681 3.1 initial window.
        cwnd = mss > 2190 ? 2 * mss : (mss > 1095 ? 3 * mss : 4 * mss)
    }

    // MARK: Output

    /// Build and send one segment. Every segment but the first SYN carries
    /// the ACK and our window.
    func sendSegment(seq: UInt32, flags: UInt8, dataOffset: Int = 0, length: Int = 0) {
        let p = Packet.make()
        let syn = flags & TCPFlag.syn != 0
        let withAck = state != .synSent && flags & TCPFlag.rst == 0 || flags & TCPFlag.ack != 0
        var opts: [UInt8] = []
        if syn {
            let m = stack.dev.mtu - 40
            opts = [2, 4, UInt8(truncatingIfNeeded: m >> 8), UInt8(truncatingIfNeeded: m)]
            let offerWS = state == .synSent ? options.windowScale : (options.windowScale && peerOfferedWS)
            if offerWS { opts += [1, 3, 3, UInt8(ourScale)] }
        }
        p.appendU16(localPort)
        p.appendU16(remotePort)
        p.appendU32(seq)
        p.appendU32(withAck ? rcvNxt : 0)
        p.appendU8(UInt8((20 + opts.count) / 4) << 4)
        p.appendU8(flags | (withAck ? TCPFlag.ack : 0))
        if syn {
            let w = min(rcvCapacity, 65535)
            p.appendU16(UInt16(w))
            if withAck && tcpGT(rcvNxt &+ UInt32(w), rcvAdv) { rcvAdv = rcvNxt &+ UInt32(w) }
        } else {
            p.appendU16(withAck ? windowField() : 0)
        }
        p.appendU32(0) // checksum, urgent pointer
        p.append(opts)
        if length > 0 {
            let at = p.end
            guard at + length <= p.buf.count else { p.release(); return }
            p.buf.withUnsafeMutableBytes { sendBuf.copy(offset: dataOffset, count: length, to: $0.baseAddress! + at) }
            p.end += length
            stats.dataSegsOut += 1
            stats.bytesOut += UInt64(length)
        }
        p.setU16(16, csumFold(csumAdd(pseudoHeaderSum(src: localIP, dst: remoteIP, proto: 6, length: p.length), p.buf, p.start, p.length)))
        stats.segsOut += 1
        layer.stats.segsOut += 1
        if flags & TCPFlag.rst != 0 { layer.stats.resetsSent += 1 }
        if withAck {
            unackedBytes = 0
            delAckAt = UInt64.max
        }
        stack.sendIP(proto: 6, dst: remoteIP, p, src: localIP)
    }

    /// Our SYN (SYN_SENT) or SYN-ACK (SYN_RECEIVED).
    func sendSYN() {
        sendSegment(seq: iss, flags: TCPFlag.syn)
    }

    func sendACK() {
        sendSegment(seq: sndNxt, flags: TCPFlag.ack)
    }

    private func challengeAck() {
        stats.challengeAcks += 1
        if layer.challengeAllowed() { sendACK() }
    }

    /// The window field: free receive space, growing the right edge only in
    /// steps of min(buffer/2, MSS), never shrinking it, scaled.
    func windowField() -> UInt16 {
        let free = rcvBuf.capacity > 0 ? rcvBuf.free : rcvCapacity
        let cur = max(0, Int(Int32(bitPattern: rcvAdv &- rcvNxt)))
        var w = free
        if free >= cur && free - cur < min(rcvCapacity / 2, mss) { w = cur }
        var field = w >> rcvScale
        if field > 65535 { field = 65535 }
        let adv = UInt32(field << rcvScale)
        if tcpGT(rcvNxt &+ adv, rcvAdv) { rcvAdv = rcvNxt &+ adv }
        return UInt16(field)
    }

    /// Bytes of window we have advertised beyond rcvNxt.
    var rcvWindow: Int { max(0, Int(Int32(bitPattern: rcvAdv &- rcvNxt))) }

    /// After the application read: tell a stalled sender the window opened.
    private func windowOpened() {
        guard connected, state != .timeWait, !peerFinished else { return }
        let cur = rcvWindow
        let free = rcvBuf.free
        if cur < rcvCapacity / 2 && free - cur >= min(rcvCapacity / 2, mss) { sendACK() }
    }

    private var sendingState: Bool {
        state == .established || state == .closeWait || state == .finWait1 || state == .closing || state == .lastAck
    }

    /// Send what the windows, Nagle and SWS avoidance allow.
    func output() {
        guard sendingState else { return }
        var budget = 128
        while budget > 0 {
            budget -= 1
            let off = Int(Int32(bitPattern: sndNxt &- sndBase))
            guard off >= 0 else { break }
            let dataLeft = max(0, sendBuf.count - off)
            let flight = Int(Int32(bitPattern: sndNxt &- sndUna))
            let usable = max(0, min(sndWnd, cwnd) - flight)
            let len = min(mss, dataLeft, usable)
            let finNow = finQueued && tcpLEQ(sndNxt, finSeq) && len == dataLeft
            if len == 0 && !finNow {
                if dataLeft > 0 && flight == 0 && sndWnd < min(mss, dataLeft) && persistAt == UInt64.max { armPersist() }
                break
            }
            if len < mss && !finNow {
                if len == dataLeft {
                    // Nagle: one small segment in flight at a time.
                    if !(noDelay || flight == 0) { break }
                } else if !(flight == 0 || (maxSndWnd > 0 && len >= maxSndWnd / 2)) {
                    break // sender SWS avoidance: wait for a bigger window
                }
            }
            let retransmit = tcpLT(sndNxt, sndMax)
            var flags = TCPFlag.ack
            if finNow { flags |= TCPFlag.fin }
            if len > 0 && len == dataLeft { flags |= TCPFlag.psh }
            sendSegment(seq: sndNxt, flags: flags, dataOffset: off, length: len)
            if retransmit {
                stats.retransmits += 1
                layer.stats.retransmits += 1
            } else if len > 0 && !rttTiming {
                rttTiming = true
                rttSeq = sndNxt
                rttStart = now
            }
            if finNow { finSent = true }
            sndNxt &+= UInt32(len + (finNow ? 1 : 0))
            if tcpGT(sndNxt, sndMax) { sndMax = sndNxt }
            if rtoAt == UInt64.max { setRTO() }
            persistAt = UInt64.max
            if finNow { break }
        }
    }

    /// Resend the first unacknowledged segment (fast retransmit, partial ACKs).
    private func retransmitFirst() {
        let off = Int(Int32(bitPattern: sndUna &- sndBase))
        guard off >= 0 else { return }
        let outstanding = Int(Int32(bitPattern: sndMax &- sndUna))
        let len = max(0, min(mss, sendBuf.count - off, outstanding))
        let fin = finSent && off + len == sendBuf.count && tcpLT(sndUna &+ UInt32(len), sndMax)
        guard len > 0 || fin else { return }
        sendSegment(seq: sndUna, flags: TCPFlag.ack | (fin ? TCPFlag.fin : 0), dataOffset: off, length: len)
        stats.retransmits += 1
        layer.stats.retransmits += 1
        rttTiming = false
    }

    private func armPersist() {
        let base = max(rto, layer.persistMin)
        let interval = min(base << UInt64(min(persistBackoff, 12)), layer.persistMax)
        persistAt = now &+ interval
        layer.arm(persistAt)
    }

    // MARK: Timers

    func runTimers() {
        let t = now
        if t >= rtoAt { rtoAt = UInt64.max; retransmitTimeout() }
        guard state != .closed else { return }
        if t >= persistAt { persistAt = UInt64.max; persistProbe() }
        if t >= delAckAt {
            delAckAt = UInt64.max
            layer.stats.delayedAcks += 1
            sendACK()
        }
        if t >= lingerAt {
            lingerAt = UInt64.max
            if state == .timeWait || state == .finWait2 { finish() }
        }
    }

    private func retransmitTimeout() {
        if state == .synSent || state == .synReceived {
            synRetries += 1
            layer.stats.timeouts += 1
            stats.timeouts += 1
            if synRetries > layer.maxSynRetries {
                if parent != nil { finish() } else { fail(.timedOut) }
                return
            }
            rto = min(rto * 2, layer.maxRTO)
            rttTiming = false
            sendSYN()
            setRTO()
            return
        }
        guard sendingState, sndUna != sndMax else { return }
        let dataUnacked = Int(Int32(bitPattern: sndMax &- sndBase)) > 0 && sendBuf.count > 0
        if sndWnd == 0 && dataUnacked {
            // The window closed under data in flight: rewind and probe it.
            sndNxt = sndUna
            rttTiming = false
            armPersist()
            return
        }
        retries += 1
        stats.timeouts += 1
        layer.stats.timeouts += 1
        if retries > layer.maxRetries {
            sendSegment(seq: sndNxt, flags: TCPFlag.rst | TCPFlag.ack)
            fail(.timedOut)
            return
        }
        let flight = Int(Int32(bitPattern: sndMax &- sndUna))
        if backoffs == 0 { ssthresh = max(flight / 2, 2 * mss) }
        cwnd = mss
        inRecovery = false
        dupAcks = 0
        recover = sndMax
        rttTiming = false
        rto = min(rto * 2, layer.maxRTO)
        backoffs += 1
        sndNxt = sndUna // go back N
        output()
        setRTO()
    }

    private func persistProbe() {
        guard sendingState else { return }
        if sndWnd > 0 { persistBackoff = 0; output(); return }
        let dataLeft = sendBuf.count - Int(Int32(bitPattern: sndNxt &- sndBase))
        guard dataLeft > 0 || (finQueued && tcpLT(sndUna, sndMax)) else { return }
        stats.probes += 1
        layer.stats.probes += 1
        if dataLeft <= 0 {
            retransmitFirst() // only a FIN is left
        } else {
            sendSegment(seq: sndUna &- 1, flags: TCPFlag.ack)
        }
        persistBackoff += 1
        armPersist()
    }

    // MARK: Input

    /// A segment for this connection (any state but LISTEN).
    func segmentArrives(_ seg: TCPSegment, _ p: Packet) {
        stats.segsIn += 1
        if state == .synSent { synSentInput(seg); return }
        guard state != .closed && state != .listen else { return }

        // 1. Sequence number check (RFC 9293 3.10.7.4).
        let wnd = rcvWindow
        let len = seg.seqLen
        let acceptable: Bool
        if len == 0 {
            acceptable = wnd == 0 ? seg.seq == rcvNxt : inWindow(seg.seq, wnd)
        } else {
            acceptable = wnd > 0 && (inWindow(seg.seq, wnd) || inWindow(seg.seq &+ UInt32(len - 1), wnd))
        }

        // 2. RST (RFC 5961 3.2): exact match resets, in-window gets a challenge.
        if seg.rst {
            if seg.seq == rcvNxt {
                resetArrived()
            } else if inWindow(seg.seq, max(wnd, 1)) {
                challengeAck()
            }
            return
        }

        if !acceptable {
            if state == .synReceived && seg.syn && !seg.hasAck && seg.seq == irs {
                sendSYN() // their SYN again: our SYN-ACK was lost
                return
            }
            if state == .timeWait && seg.fin { setLinger(2 * layer.mslTicks) }
            // A zero window still takes valid ACKs (RFC 9293 3.10.7.4).
            if wnd == 0 && seg.seq == rcvNxt && seg.hasAck && !seg.syn {
                guard processAck(seg) else { return }
                output()
            }
            if state != .closed { sendACK() }
            return
        }

        // 4. SYN in the window: challenge ACK (RFC 5961 4.2).
        if seg.syn {
            challengeAck()
            return
        }

        // 5. ACK.
        guard seg.hasAck else { return }
        guard processAck(seg) else { return }
        guard state != .closed else { return }

        // 7, 8. Data and FIN.
        processData(seg, p)
        if state != .closed && state != .timeWait { output() }
    }

    private func inWindow(_ s: UInt32, _ wnd: Int) -> Bool {
        tcpLEQ(rcvNxt, s) && tcpLT(s, rcvNxt &+ UInt32(truncatingIfNeeded: wnd))
    }

    private func resetArrived() {
        switch state {
        case .synReceived:
            if parent != nil { finish() } else { fail(.refused) }
        case .established, .finWait1, .finWait2, .closeWait:
            fail(.reset)
        default:
            rcvBuf.release()
            finish()
        }
    }

    private func synSentInput(_ seg: TCPSegment) {
        if seg.hasAck && (tcpLEQ(seg.ack, iss) || tcpGT(seg.ack, sndMax)) {
            if !seg.rst {
                layer.sendRaw(src: localIP, srcPort: localPort, dst: remoteIP, dstPort: remotePort, seq: seg.ack, ack: 0, flags: TCPFlag.rst)
            }
            return
        }
        if seg.rst {
            if seg.hasAck { fail(.refused) } // the ACK was acceptable
            return
        }
        guard seg.syn else { return }
        irs = seg.seq
        rcvNxt = seg.seq &+ 1
        rcvAdv = rcvNxt
        peerOfferedWS = seg.wscale != nil
        applySynOptions(seg, weOffered: options.windowScale)
        sndWnd = Int(seg.window)
        maxSndWnd = sndWnd
        sndWl1 = seg.seq
        sndWl2 = seg.ack
        if seg.hasAck {
            if synRetries == 0 { rttSample(now &- (rttStart)) }
            sndUna = seg.ack
            rtoAt = UInt64.max
            retries = 0
            becomeEstablished()
            sendACK()
            output()
        } else {
            // Simultaneous open (RFC 9293 3.5): SYN-ACK and wait.
            state = .synReceived
            sendSYN()
            setRTO()
        }
    }

    /// A SYN for a listener: make a SYN_RECEIVED child (no buffers yet).
    func listenInput(_ h: IPv4Header, _ seg: TCPSegment) {
        if seg.rst { return }
        if seg.hasAck { layer.sendReset(h, seg); return }
        guard seg.syn else { return }
        guard children.count + acceptQueue.count < backlog, layer.connections.count < layer.maxConnections else {
            layer.stats.synDropped += 1
            return
        }
        let c = TCPConnection(layer: layer, options: options)
        c.parent = self
        c.localIP = h.dst
        c.localPort = localPort
        c.remoteIP = h.src
        c.remotePort = seg.srcPort
        c.irs = seg.seq
        c.rcvNxt = seg.seq &+ 1
        c.rcvAdv = c.rcvNxt
        c.peerOfferedWS = seg.wscale != nil
        c.applySynOptions(seg, weOffered: options.windowScale)
        c.iss = layer.makeISN(local: h.dst, localPort: localPort, remote: h.src, remotePort: seg.srcPort)
        c.sndUna = c.iss
        c.sndNxt = c.iss &+ 1
        c.sndMax = c.sndNxt
        c.sndBase = c.iss &+ 1
        c.recover = c.iss
        c.sndWnd = Int(seg.window)
        c.maxSndWnd = c.sndWnd
        c.sndWl1 = seg.seq
        c.sndWl2 = c.iss
        c.state = .synReceived
        c.rttStart = layer.now
        layer.add(c)
        children.append(c)
        layer.stats.passiveOpens += 1
        c.sendSYN()
        c.setRTO()
    }

    /// Step 5 of segment arrival. false: stop processing this segment.
    private func processAck(_ seg: TCPSegment) -> Bool {
        if state == .synReceived {
            guard tcpLT(sndUna, seg.ack) && tcpLEQ(seg.ack, sndMax) else {
                layer.sendRaw(src: localIP, srcPort: localPort, dst: remoteIP, dstPort: remotePort, seq: seg.ack, ack: 0, flags: TCPFlag.rst)
                return false
            }
            if synRetries == 0 { rttSample(now &- rttStart) }
            sndWnd = Int(seg.window) << sndScale
            maxSndWnd = max(maxSndWnd, sndWnd)
            sndWl1 = seg.seq
            sndWl2 = seg.ack
            becomeEstablished()
        }
        // RFC 5961 5.2: acceptable ACKs are in [SND.UNA - MAX.SND.WND, SND.NXT].
        if tcpGT(seg.ack, sndMax) {
            sendACK()
            return false
        }
        if tcpLT(seg.ack, sndUna &- UInt32(truncatingIfNeeded: max(maxSndWnd, 1))) {
            challengeAck()
            return false
        }
        let window = Int(seg.window) << sndScale
        if tcpGT(seg.ack, sndUna) {
            newAck(seg.ack)
        } else if seg.ack == sndUna && seg.dataLen == 0 && !seg.fin && window == sndWnd && sndMax != sndUna {
            dupAck()
        }
        if tcpLT(sndWl1, seg.seq) || (sndWl1 == seg.seq && tcpLEQ(sndWl2, seg.ack)) {
            sndWnd = window
            sndWl1 = seg.seq
            sndWl2 = seg.ack
            if sndWnd > maxSndWnd { maxSndWnd = sndWnd }
            if sndWnd > 0 && persistAt != UInt64.max {
                persistAt = UInt64.max
                persistBackoff = 0
            }
        }
        if finSent && tcpGEQ(sndUna, finSeq &+ 1) {
            switch state {
            case .finWait1:
                state = .finWait2
                rtoAt = UInt64.max
                if userClosed { setLinger(layer.finWait2Ticks) }
                layer.notify(self)
            case .closing:
                enterTimeWait()
            case .lastAck:
                finish()
                return false
            default:
                break
            }
        }
        return true
    }

    private func newAck(_ ack: UInt32) {
        let acked = Int(ack &- sndUna)
        if rttTiming && tcpGT(ack, rttSeq) {
            rttTiming = false
            rttSample(now &- rttStart)
        }
        if tcpGT(ack, sndBase) {
            let d = min(sendBuf.count, Int(ack &- sndBase))
            sendBuf.discard(d)
            sndBase &+= UInt32(d)
        }
        if inRecovery {
            if tcpGEQ(ack, recover) {
                // Full ACK: leave recovery (RFC 6582 3.2 step 3).
                cwnd = min(ssthresh, max(Int(Int32(bitPattern: sndMax &- ack)), 0) + mss)
                inRecovery = false
                dupAcks = 0
            } else {
                // Partial ACK: resend the next hole, deflate the window.
                sndUna = ack
                if tcpLT(sndNxt, sndUna) { sndNxt = sndUna }
                retransmitFirst()
                cwnd = max(cwnd - acked + mss, mss)
            }
        } else {
            dupAcks = 0
            if cwnd < ssthresh {
                cwnd += min(acked, mss)
            } else {
                cwnd += max(1, mss * mss / max(cwnd, 1))
            }
            if cwnd > 1 << 26 { cwnd = 1 << 26 }
        }
        sndUna = ack
        if tcpLT(sndNxt, sndUna) { sndNxt = sndUna }
        retries = 0
        if backoffs > 0 {
            backoffs = 0
            rto = hasRTT ? computedRTO : layer.initialRTO
        }
        if sndUna == sndMax { rtoAt = UInt64.max } else { setRTO() }
        layer.notify(self)
    }

    private func dupAck() {
        dupAcks += 1
        stats.dupAcksIn += 1
        if dupAcks == 3 && !inRecovery && tcpGEQ(sndUna, recover) {
            let flight = Int(Int32(bitPattern: sndMax &- sndUna))
            ssthresh = max(flight / 2, 2 * mss)
            recover = sndMax
            retransmitFirst()
            cwnd = ssthresh + 3 * mss
            inRecovery = true
            stats.fastRetransmits += 1
            layer.stats.fastRetransmits += 1
        } else if inRecovery && dupAcks > 3 {
            cwnd += mss
        }
    }

    private var computedRTO: UInt64 {
        let r = UInt64(max((srtt8 >> 3) + max(1, rttvar4), 0))
        return min(max(r, layer.minRTO), layer.maxRTO)
    }

    /// RFC 6298 2.2-2.4 with BSD's scaled integers (ticks).
    private func rttSample(_ r: UInt64) {
        let m = Int(min(r, 60000))
        if !hasRTT {
            srtt8 = m << 3
            rttvar4 = m << 1
            hasRTT = true
        } else {
            var delta = m - (srtt8 >> 3)
            srtt8 += delta
            if delta < 0 { delta = -delta }
            rttvar4 += delta - (rttvar4 >> 2)
        }
        rto = computedRTO
    }

    /// Steps 7 and 8: segment text and FIN.
    private func processData(_ seg: TCPSegment, _ p: Packet) {
        guard state == .established || state == .finWait1 || state == .finWait2 else { return }
        var seq = seg.seq
        var off = seg.dataStart
        var n = seg.dataLen
        var fin = seg.fin
        if n == 0 && !fin { return }
        if tcpLT(seq, rcvNxt) {
            let d = Int(rcvNxt &- seq)
            if d > n {
                n = 0
                fin = false // a FIN before rcvNxt is an old duplicate
            } else {
                off += d
                n -= d
            }
            seq = rcvNxt
        }
        let room = Int(Int32(bitPattern: (rcvNxt &+ UInt32(truncatingIfNeeded: rcvWindow)) &- seq))
        if n > room {
            n = max(room, 0)
            fin = false
        }
        if n == 0 && !fin {
            sendACK() // duplicate: ACK at once
            return
        }
        if userClosed && n > 0 {
            // Data for a closed reader (RFC 2525 2.17).
            sendSegment(seq: sndNxt, flags: TCPFlag.rst | TCPFlag.ack)
            fail(.aborted)
            return
        }
        stats.bytesIn += UInt64(n)
        if seq == rcvNxt {
            let hadHoles = !ooo.isEmpty
            if n > 0 {
                let w = p.buf.withUnsafeBytes { rcvBuf.write(UnsafeRawBufferPointer(start: $0.baseAddress! + p.start + off, count: n)) }
                rcvNxt &+= UInt32(w)
            }
            if fin {
                finArrived()
            } else {
                drainOutOfOrder()
            }
            if state == .closed { return }
            if hadHoles || fin || peerFinished {
                sendACK()
            } else {
                unackedBytes += n
                if unackedBytes >= 2 * mss {
                    sendACK()
                } else if delAckAt == UInt64.max {
                    delAckAt = now &+ layer.delayedAckTicks
                    layer.arm(delAckAt)
                }
            }
            layer.notify(self)
        } else {
            stats.outOfOrder += 1
            layer.stats.outOfOrder += 1
            if fin && oooFin == nil { oooFin = seq &+ UInt32(n) }
            if n > 0, let data = p.bytes(off, n) { insertOutOfOrder(seq, data) }
            sendACK() // a duplicate ACK tells the sender about the hole
        }
    }

    private func insertOutOfOrder(_ seq: UInt32, _ data: [UInt8]) {
        var at = ooo.count
        for (i, e) in ooo.enumerated() {
            if e.seq == seq && e.data.count >= data.count { return } // duplicate
            if tcpLT(seq, e.seq) { at = i; break }
        }
        guard ooo.count < layer.oooMaxSegments, oooBytes + data.count <= rcvCapacity else {
            layer.stats.outOfOrderDropped += 1
            return
        }
        ooo.insert(TCPOutOfOrder(seq: seq, data: data), at: at)
        oooBytes += data.count
    }

    private func drainOutOfOrder() {
        while let first = ooo.first, tcpLEQ(first.seq, rcvNxt) {
            ooo.removeFirst()
            oooBytes -= first.data.count
            let skip = Int(rcvNxt &- first.seq)
            if skip < first.data.count {
                let w = first.data.withUnsafeBytes {
                    rcvBuf.write(UnsafeRawBufferPointer(start: $0.baseAddress! + skip, count: first.data.count - skip))
                }
                rcvNxt &+= UInt32(w)
            }
        }
        if let f = oooFin, f == rcvNxt {
            oooFin = nil
            finArrived()
        }
    }

    private func finArrived() {
        rcvNxt &+= 1
        peerFinished = true
        ooo.removeAll()
        oooBytes = 0
        switch state {
        case .synReceived, .established:
            state = .closeWait
        case .finWait1:
            if finSent && tcpGEQ(sndUna, finSeq &+ 1) { enterTimeWait() } else { state = .closing }
        case .finWait2:
            enterTimeWait()
        default:
            break
        }
        sendACK()
        layer.notify(self)
    }

    // MARK: ICMP

    func icmpError(_ e: ICMPError) {
        if e.type == ICMPType.unreachable && e.code == ICMPUnreachCode.fragNeeded {
            // Path MTU (RFC 1191): shrink the MSS and resend.
            if e.mtu >= 68 + 40 {
                let newMSS = max(64, e.mtu - 40)
                if newMSS < mss {
                    mss = newMSS
                    sndNxt = sndUna
                    output()
                }
            }
            return
        }
        if state == .synSent && e.type == ICMPType.unreachable && e.code <= ICMPUnreachCode.port {
            fail(.unreachable)
            return
        }
        softError = e
    }
}
