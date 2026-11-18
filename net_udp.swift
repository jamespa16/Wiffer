// Part 7 (Phase 7C1): UDP. A socket is bound to a local port (any local
// address) and keeps a bounded queue of received datagrams. Checksums are
// verified when present (zero means "none" over IPv4) and always sent.
// A datagram for a port nobody has bound is answered with ICMP port
// unreachable (unicast only).

struct UDPDatagram {
    var src: IPv4Addr
    var srcPort: UInt16
    var data: [UInt8]
}

final class UDPSocket {
    let stack: NetStack
    let port: UInt16
    /// Received datagrams, oldest first, at most `maxQueue`.
    var queue: [UDPDatagram] = []
    static let maxQueue = 32
    /// Called (from netd) after a datagram is queued.
    var onReceive: (() -> Void)?
    /// The last ICMP error for a datagram sent from this socket, if any.
    var lastError: ICMPError?
    var closed = false
    var sent: UInt64 = 0
    var received: UInt64 = 0

    init(stack: NetStack, port: UInt16) {
        self.stack = stack
        self.port = port
    }

    /// Send `data` (at most mtu-28 bytes). `src` overrides the source
    /// address (DHCP sends from 0.0.0.0 while it has none). False if not sent.
    @discardableResult
    func send(to dst: IPv4Addr, port dstPort: UInt16, _ data: [UInt8], src: IPv4Addr? = nil) -> Bool {
        guard !closed, data.count + 28 <= stack.dev.mtu else { return false }
        let p = Packet.make()
        p.append(data)
        guard p.push(8) else { p.release(); return false }
        let source = src ?? stack.ip
        p.setU16(0, port)
        p.setU16(2, dstPort)
        p.setU16(4, UInt16(truncatingIfNeeded: p.length))
        var c = csumFold(csumAdd(pseudoHeaderSum(src: source, dst: dst, proto: 17, length: p.length), p.buf, p.start, p.length))
        if c == 0 { c = 0xFFFF }
        p.setU16(6, c)
        sent += 1
        return stack.sendIP(proto: 17, dst: dst, p, src: source)
    }

    func receive() -> UDPDatagram? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let i = stack.udpSockets.firstIndex(where: { $0 === self }) { stack.udpSockets.remove(at: i) }
        queue.removeAll()
    }
}

extension NetStack {
    /// Bind a UDP port (0 picks an ephemeral one). nil if it is taken, or no
    /// ephemeral port is free.
    func udpBind(_ port: UInt16 = 0) -> UDPSocket? {
        var chosen = port
        if chosen == 0 {
            // 49152...65535, starting somewhere random, skipping bound ports.
            let span = 65536 - 49152
            let startAt = Int(truncatingIfNeeded: netRandom() >> 40) % span
            for i in 0..<span {
                let candidate = UInt16(49152 + (startAt + i) % span)
                if !udpSockets.contains(where: { $0.port == candidate }) { chosen = candidate; break }
            }
            guard chosen != 0 else { return nil }
        } else if udpSockets.contains(where: { $0.port == chosen }) {
            return nil
        }
        let s = UDPSocket(stack: self, port: chosen)
        udpSockets.append(s)
        return s
    }

    /// Protocol 17 handler; `p` is at the UDP header.
    func handleUDP(_ h: IPv4Header, _ p: Packet) {
        stats.udpRx += 1
        guard let sport = p.u16(0), let dport = p.u16(2), let len = p.u16(4), let csum = p.u16(6),
              Int(len) >= 8, Int(len) <= p.length
        else { stats.udpBad += 1; return }
        p.trim(to: Int(len))
        if csum != 0 {
            let sum = csumAdd(pseudoHeaderSum(src: h.src, dst: h.dst, proto: 17, length: p.length), p.buf, p.start, p.length)
            guard csumFold(sum) == 0 else { stats.udpBad += 1; return }
        }
        guard let socket = udpSockets.first(where: { $0.port == dport }) else {
            stats.udpNoPort += 1
            if !h.broadcast { sendICMPError(type: ICMPType.unreachable, code: ICMPUnreachCode.port, h, p) }
            return
        }
        guard socket.queue.count < UDPSocket.maxQueue, let data = p.bytes(8) else {
            stats.udpQueueDropped += 1
            return
        }
        socket.queue.append(UDPDatagram(src: h.src, srcPort: sport, data: data))
        socket.received += 1
        socket.onReceive?()
    }
}
