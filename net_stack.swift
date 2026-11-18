// Part 7 (Phase 7B): Ethernet II, ARP, IPv4 (with fragment reassembly) and
// ICMP, plus the timer and protocol-handler hooks the layers above plug into.
//
// One `NetStack` owns one device and one IPv4 interface. It is plain Swift
// with no hardware knowledge: tests build two stacks on a LinkPair and drive
// them with virtual time (net_selftest.swift). On the machine, the single
// stack on eth0 lives in the `netd` task (net_commands.swift), polled from
// the main loop, and owns all stack state: nothing else touches it unless it
// runs on CPU 0 (the shell commands do, and wait through `netBlock`).
//
// Hooks for TCP (7D) and the sockets layer (7E):
//
//  - Protocol handlers. `stack.registerProtocol(6) { header, packet in ... }`.
//    `packet.start` is the first byte of the IP payload (the IPv4 header sits
//    just before it in `packet.buf`), trimmed to the IP total length; a
//    reassembled datagram arrives the same way. The packet is borrowed: copy
//    what you keep. With no handler for a protocol, the stack answers ICMP
//    "protocol unreachable".
//  - Sending. `stack.sendIP(proto:dst:payload)` takes a Packet made with
//    `Packet.make()` and filled with the transport segment (the stack pushes
//    the IP and Ethernet headers into the headroom, resolves ARP, queues if
//    needed). It never fragments: payloads over mtu-20 are refused.
//  - ICMP errors. `stack.setErrorHandler(proto: 6) { err in ... }` gets
//    destination-unreachable and time-exceeded reports for datagrams we sent
//    (the original source must be our address). `ICMPError` carries the
//    quoted addresses, ports and (for TCP) the sequence number.
//  - Timers. `stack.schedule(after: ticks) { ... }` runs a closure inside
//    `poll`, from netd, no sooner than `ticks` timer ticks (100 Hz) later.
//    `cancel(id)` removes it. `stack.now` is the current tick. The stack
//    never sleeps in a timer: reschedule from the closure for repeating work.

// MARK: Types

struct IPv4Header {
    var tos: UInt8 = 0
    var ttl: UInt8 = 64
    var proto: UInt8 = 0
    var id: UInt16 = 0
    var src: IPv4Addr = 0
    var dst: IPv4Addr = 0
    var headerLength = 20
    var totalLength = 20
    /// Byte offset of this fragment (0 for a whole datagram).
    var fragmentOffset = 0
    var moreFragments = false
    /// Sent to a broadcast or multicast address (so no ICMP errors).
    var broadcast = false
}

/// A destination-unreachable (type 3) or time-exceeded (type 11) report,
/// decoded from the datagram it quotes.
struct ICMPError {
    var type: UInt8
    var code: UInt8
    /// Next-hop MTU for "fragmentation needed" (type 3 code 4), else 0.
    var mtu: Int
    /// The quoted datagram's addresses (src is ours), protocol and first transport words.
    var originalSrc: IPv4Addr
    var originalDst: IPv4Addr
    var proto: UInt8
    var srcPort: UInt16
    var dstPort: UInt16
    /// Bytes 4..<8 of the transport header (a TCP sequence number).
    var seq: UInt32
}

enum ICMPType {
    static let echoReply: UInt8 = 0
    static let unreachable: UInt8 = 3
    static let echoRequest: UInt8 = 8
    static let timeExceeded: UInt8 = 11
}

enum ICMPUnreachCode {
    static let network: UInt8 = 0
    static let host: UInt8 = 1
    static let proto: UInt8 = 2
    static let port: UInt8 = 3
    static let fragNeeded: UInt8 = 4
}

typealias IPProtocolHandler = (IPv4Header, Packet) -> Void
typealias ICMPErrorHandler = (ICMPError) -> Void

struct NetStats {
    var rxFrames: UInt64 = 0
    var rxNotForUs: UInt64 = 0
    var rxUnknownEtherType: UInt64 = 0
    var rxBadFrame: UInt64 = 0
    var arpRx: UInt64 = 0
    var arpBad: UInt64 = 0
    var arpRepliesSent: UInt64 = 0
    var arpRequestsSent: UInt64 = 0
    var arpFailed: UInt64 = 0
    var arpQueueDropped: UInt64 = 0
    var ipRx: UInt64 = 0
    var ipBadHeader: UInt64 = 0
    var ipBadChecksum: UInt64 = 0
    var ipNotForUs: UInt64 = 0
    var ipDelivered: UInt64 = 0
    var ipTx: UInt64 = 0
    var txNoRoute: UInt64 = 0
    var txTooBig: UInt64 = 0
    var fragments: UInt64 = 0
    var reassembled: UInt64 = 0
    var reassemblyDropped: UInt64 = 0
    var reassemblyTimeouts: UInt64 = 0
    var icmpRx: UInt64 = 0
    var icmpBad: UInt64 = 0
    var icmpEchoReplied: UInt64 = 0
    var icmpErrorsSent: UInt64 = 0
    var icmpErrorsRx: UInt64 = 0
    var icmpRateLimited: UInt64 = 0
    var udpRx: UInt64 = 0
    var udpBad: UInt64 = 0
    var udpNoPort: UInt64 = 0
    var udpQueueDropped: UInt64 = 0
}

final class ARPEntry {
    let ip: IPv4Addr
    var mac: MACAddr = 0
    var resolved = false
    /// When a resolved entry stops being trusted.
    var expires: UInt64 = 0
    /// IP packets waiting for the reply.
    var queue: [Packet] = []
    var tries = 0
    var nextTry: UInt64 = 0
    init(ip: IPv4Addr) { self.ip = ip }
}

struct StackTimer {
    var id: Int
    var at: UInt64
    var fn: () -> Void
}

struct Fragment {
    var offset: Int
    var data: [UInt8]
}

final class Reassembly {
    let src: IPv4Addr
    let dst: IPv4Addr
    let id: UInt16
    let proto: UInt8
    var fragments: [Fragment] = []
    /// Header bytes and fields of the offset-0 fragment, once seen.
    var headerBytes: [UInt8] = []
    var header: IPv4Header? = nil
    /// Payload length, known once the last fragment (MF=0) arrives.
    var total = -1
    var bytes = 0
    var expires: UInt64
    init(src: IPv4Addr, dst: IPv4Addr, id: UInt16, proto: UInt8, expires: UInt64) {
        self.src = src
        self.dst = dst
        self.id = id
        self.proto = proto
        self.expires = expires
    }
}

// MARK: Stack

final class NetStack {
    let dev: NetDevice
    var ip: IPv4Addr = 0
    var mask: IPv4Addr = 0
    var gateway: IPv4Addr = 0
    var dns: IPv4Addr = 0
    /// Current time in timer ticks (100 Hz), set by `poll(now:)`.
    var now: UInt64 = 0
    var stats = NetStats()

    // Tunables (ticks unless noted), visible so tests can shorten them.
    var arpTTL: UInt64 = 6000
    var arpRetry: UInt64 = 100
    var arpMaxTries = 3
    var arpMaxEntries = 32
    var arpMaxQueue = 4
    var reassemblyTimeout: UInt64 = 3000
    var reassemblyMaxDatagrams = 8
    var reassemblyMaxBytes = 256 * 1024
    var reassemblyMaxFragments = 128

    var arpTable: [ARPEntry] = []
    var reassemblies: [Reassembly] = []
    var reassemblyBytes: Int { reassemblies.reduce(0) { $0 + $1.bytes } }
    var handlers = [IPProtocolHandler?](repeating: nil, count: 256)
    var errorHandlers = [ICMPErrorHandler?](repeating: nil, count: 256)
    var timers: [StackTimer] = []
    var nextTimerID = 1
    var selfQueue: [Packet] = []
    var nextHousekeeping: UInt64 = UInt64.max
    var ipID: UInt16 = 1
    var icmpWindowStart: UInt64 = 0
    var icmpTokens = 10

    /// Echo replies for `ping`: source, id, sequence, TTL, payload bytes.
    var onEchoReply: ((IPv4Addr, UInt16, UInt16, UInt8, Int) -> Void)?

    // Layers above (net_udp.swift, net_dhcp.swift, net_dns.swift).
    var udpSockets: [UDPSocket] = []
    var nextEphemeral: UInt16 = 0
    var dhcp: DHCPClient?
    var resolver: DNSResolver?

    init(device: NetDevice) {
        dev = device
        ipID = UInt16(truncatingIfNeeded: netRandom())
        handlers[1] = { [self] h, p in handleICMP(h, p) }
        handlers[17] = { [self] h, p in handleUDP(h, p) }
        device.onReceive = { [self] p in receive(p) }
        errorHandlers[17] = { [self] e in
            if let s = udpSockets.first(where: { $0.port == e.srcPort }) { s.lastError = e }
        }
    }

    func configure(ip: IPv4Addr, mask: IPv4Addr, gateway: IPv4Addr, dns: IPv4Addr = 0) {
        self.ip = ip
        self.mask = mask
        self.gateway = gateway
        self.dns = dns
    }

    // MARK: Hooks

    func registerProtocol(_ proto: UInt8, _ handler: @escaping IPProtocolHandler) { handlers[Int(proto)] = handler }
    func unregisterProtocol(_ proto: UInt8) { handlers[Int(proto)] = nil }
    func setErrorHandler(proto: UInt8, _ handler: @escaping ICMPErrorHandler) { errorHandlers[Int(proto)] = handler }

    /// Run `fn` from `poll` at least `ticks` ticks from now. Returns an id for `cancel`.
    @discardableResult
    func schedule(after ticks: UInt64, _ fn: @escaping () -> Void) -> Int {
        let id = nextTimerID
        nextTimerID += 1
        timers.append(StackTimer(id: id, at: now &+ ticks, fn: fn))
        return id
    }

    func cancel(_ id: Int) {
        if let i = timers.firstIndex(where: { $0.id == id }) { timers.remove(at: i) }
    }

    /// Earliest tick at which `poll` has timed work (UInt64.max if none).
    var nextDeadline: UInt64 {
        var t = nextHousekeeping
        for timer in timers where timer.at < t { t = timer.at }
        return t
    }

    /// True if `poll(now:)` has something to do: frames waiting, local
    /// packets, or a timer due. The main loop calls this to decide whether to
    /// wake netd.
    func needsPoll(_ t: UInt64) -> Bool {
        dev.hasWork || !selfQueue.isEmpty || t >= nextDeadline
    }

    /// Drain the device, local deliveries and due timers at time `t`.
    func poll(now t: UInt64) {
        now = t
        dev.poll()
        var rounds = 0
        repeat {
            drainSelf()
            runTimers()
            rounds += 1
        } while !selfQueue.isEmpty && rounds < 4
        if now >= nextHousekeeping { housekeep() }
    }

    private func runTimers() {
        var budget = 256
        while budget > 0 {
            budget -= 1
            var best = -1
            for i in 0..<timers.count where timers[i].at <= now {
                if best < 0 || timers[i].at < timers[best].at { best = i }
            }
            guard best >= 0 else { return }
            let timer = timers.remove(at: best)
            timer.fn()
        }
    }

    private func drainSelf() {
        guard !selfQueue.isEmpty else { return }
        let q = selfQueue
        selfQueue.removeAll(keepingCapacity: true)
        for p in q { handleIPv4(p, local: true) }
    }

    // MARK: Ethernet

    private func putMAC(_ p: Packet, _ at: Int, _ mac: MACAddr) {
        for i in 0..<6 { p.setU8(at + i, UInt8(truncatingIfNeeded: mac >> UInt64(8 * (5 - i)))) }
    }

    /// Prepend an Ethernet header to `p` and hand it to the device.
    func sendFrame(to mac: MACAddr, type: UInt16, _ p: Packet) {
        guard p.push(14) else { p.release(); return }
        putMAC(p, 0, mac)
        putMAC(p, 6, dev.mac)
        p.setU16(12, type)
        dev.send(p)
    }

    func receive(_ p: Packet) {
        defer { p.release() }
        stats.rxFrames += 1
        guard p.length >= 14, let dst = p.u48(0), let src = p.u48(6), let type = p.u16(12) else {
            stats.rxBadFrame += 1
            return
        }
        // Unicast to us or broadcast only; our own broadcasts echoed back are ignored.
        guard dst == dev.mac || dst == macBroadcast, src != dev.mac else {
            stats.rxNotForUs += 1
            return
        }
        p.pull(14)
        switch type {
        case 0x0806: handleARP(p)
        case 0x0800: handleIPv4(p, local: false)
        default: stats.rxUnknownEtherType += 1
        }
    }

    // MARK: ARP

    func arpEntry(_ addr: IPv4Addr) -> ARPEntry? { arpTable.first(where: { $0.ip == addr }) }

    /// The cached MAC for `addr`, if resolved and not expired.
    func arpLookup(_ addr: IPv4Addr) -> MACAddr? {
        guard let e = arpEntry(addr), e.resolved, e.expires > now else { return nil }
        return e.mac
    }

    private func sendARP(op: UInt16, targetMAC: MACAddr, targetIP: IPv4Addr, to: MACAddr) {
        let p = Packet.make()
        p.appendU16(1)
        p.appendU16(0x0800)
        p.appendU8(6)
        p.appendU8(4)
        p.appendU16(op)
        for i in 0..<6 { p.appendU8(UInt8(truncatingIfNeeded: dev.mac >> UInt64(8 * (5 - i)))) }
        p.appendU32(ip)
        for i in 0..<6 { p.appendU8(UInt8(truncatingIfNeeded: targetMAC >> UInt64(8 * (5 - i)))) }
        p.appendU32(targetIP)
        sendFrame(to: to, type: 0x0806, p)
    }

    private func handleARP(_ p: Packet) {
        stats.arpRx += 1
        guard let htype = p.u16(0), let ptype = p.u16(2), let hlen = p.u8(4), let plen = p.u8(5), let op = p.u16(6),
              let sha = p.u48(8), let spa = p.u32(14), let tpa = p.u32(24),
              htype == 1, ptype == 0x0800, hlen == 6, plen == 4, op == 1 || op == 2
        else { stats.arpBad += 1; return }
        // Never learn broadcast/multicast/zero hardware or protocol addresses.
        guard sha != macBroadcast, sha & 0x0100_0000_0000 == 0, sha != 0, spa != 0, spa != 0xFFFF_FFFF, !isMulticastIP(spa)
        else { stats.arpBad += 1; return }
        let forUs = ip != 0 && tpa == ip
        if let e = arpEntry(spa) {
            // Refresh what we already track. (Replies and requests alike.)
            e.mac = sha
            e.expires = now &+ arpTTL
            if !e.resolved {
                e.resolved = true
                flush(e)
            }
        } else if forUs && op == 1 {
            learn(spa, sha) // a request to us: they will talk to us next
        }
        if op == 1 && forUs {
            stats.arpRepliesSent += 1
            sendARP(op: 2, targetMAC: sha, targetIP: spa, to: sha)
        }
    }

    @discardableResult
    private func learn(_ addr: IPv4Addr, _ mac: MACAddr) -> ARPEntry {
        let e = ARPEntry(ip: addr)
        e.mac = mac
        e.resolved = true
        e.expires = now &+ arpTTL
        insert(e)
        return e
    }

    private func insert(_ e: ARPEntry) {
        if arpTable.count >= arpMaxEntries {
            // Evict the entry closest to expiry (unresolved entries first).
            var victim = 0
            for i in 1..<arpTable.count {
                let a = arpTable[i], b = arpTable[victim]
                if (!a.resolved && b.resolved) || (a.resolved == b.resolved && a.expires < b.expires) { victim = i }
            }
            drop(arpTable.remove(at: victim))
        }
        arpTable.append(e)
    }

    private func drop(_ e: ARPEntry) {
        for q in e.queue { q.release() }
        stats.arpQueueDropped += UInt64(e.queue.count)
        e.queue.removeAll()
    }

    /// Send what waited for `e`'s address.
    private func flush(_ e: ARPEntry) {
        let q = e.queue
        e.queue.removeAll()
        for p in q { sendFrame(to: e.mac, type: 0x0800, p) }
    }

    /// Send the IP packet `p` to the on-link address `hop`, ARPing if needed.
    private func resolveAndSend(_ p: Packet, hop: IPv4Addr) {
        if let e = arpEntry(hop) {
            if e.resolved && e.expires > now {
                sendFrame(to: e.mac, type: 0x0800, p)
                return
            }
            if e.resolved { // stale: ask again, keep the old MAC out of use
                e.resolved = false
                e.tries = 0
            }
            queue(p, on: e)
            if e.tries == 0 { request(e) }
            return
        }
        let e = ARPEntry(ip: hop)
        insert(e)
        queue(p, on: e)
        request(e)
    }

    private func queue(_ p: Packet, on e: ARPEntry) {
        if e.queue.count >= arpMaxQueue {
            e.queue.removeFirst().release() // the oldest loses
            stats.arpQueueDropped += 1
        }
        e.queue.append(p)
    }

    private func request(_ e: ARPEntry) {
        e.tries += 1
        e.nextTry = now &+ arpRetry
        stats.arpRequestsSent += 1
        sendARP(op: 1, targetMAC: 0, targetIP: e.ip, to: macBroadcast)
        scheduleHousekeeping()
    }

    private func scheduleHousekeeping() {
        if nextHousekeeping == UInt64.max { nextHousekeeping = now &+ 10 }
    }

    /// Periodic work while ARP requests or reassemblies are pending.
    private func housekeep() {
        nextHousekeeping = UInt64.max
        var i = 0
        while i < arpTable.count {
            let e = arpTable[i]
            if !e.resolved {
                if now >= e.nextTry {
                    if e.tries >= arpMaxTries {
                        stats.arpFailed += 1
                        drop(e)
                        arpTable.remove(at: i)
                        continue
                    }
                    request(e)
                }
            } else if e.expires <= now {
                arpTable.remove(at: i)
                continue
            }
            i += 1
        }
        var j = 0
        while j < reassemblies.count {
            if reassemblies[j].expires <= now {
                stats.reassemblyTimeouts += 1
                reassemblyExpired(reassemblies.remove(at: j))
            } else {
                j += 1
            }
        }
        if !reassemblies.isEmpty || arpTable.contains(where: { !$0.resolved }) { scheduleHousekeeping() }
    }

    // MARK: IPv4 send

    /// True if `addr` is on the interface's subnet.
    func onLink(_ addr: IPv4Addr) -> Bool { ip != 0 && (addr ^ ip) & mask == 0 }

    func isBroadcast(_ addr: IPv4Addr) -> Bool {
        addr == 0xFFFF_FFFF || (ip != 0 && mask != 0 && mask != 0xFFFF_FFFF && addr == (ip & mask) | ~mask)
    }

    /// Wrap `payload` (a transport segment, built with `Packet.make()` and
    /// appended to) in an IPv4 header and send it. `src` defaults to our
    /// address (0.0.0.0 before DHCP completes). Takes ownership of `payload`.
    /// False if it can't be sent (too large for the MTU, no route).
    @discardableResult
    func sendIP(proto: UInt8, dst: IPv4Addr, _ payload: Packet, src: IPv4Addr? = nil, ttl: UInt8 = 64,
                tos: UInt8 = 0) -> Bool {
        guard payload.length + 20 <= dev.mtu else {
            stats.txTooBig += 1
            payload.release()
            return false
        }
        guard payload.push(20) else { payload.release(); return false }
        let total = payload.length
        payload.setU8(0, 0x45)
        payload.setU8(1, tos)
        payload.setU16(2, UInt16(truncatingIfNeeded: total))
        payload.setU16(4, ipID)
        ipID &+= 1
        payload.setU16(6, 0x4000) // DF: we never fragment
        payload.setU8(8, ttl)
        payload.setU8(9, proto)
        let s = src ?? ip
        for i in 0..<4 {
            payload.setU8(12 + i, UInt8(truncatingIfNeeded: s >> UInt32(8 * (3 - i))))
            payload.setU8(16 + i, UInt8(truncatingIfNeeded: dst >> UInt32(8 * (3 - i))))
        }
        payload.setU16(10, inetChecksum(payload.buf, payload.start, 20))
        stats.ipTx += 1
        route(payload, dst: dst)
        return true
    }

    private func route(_ p: Packet, dst: IPv4Addr) {
        if dst == ip && ip != 0 || dst >> 24 == 127 {
            selfQueue.append(p)
        } else if isBroadcast(dst) {
            sendFrame(to: macBroadcast, type: 0x0800, p)
        } else if isMulticastIP(dst) {
            // 01:00:5e + low 23 bits.
            sendFrame(to: 0x0100_5E00_0000 | UInt64(dst & 0x7F_FFFF), type: 0x0800, p)
        } else if ip == 0 {
            stats.txNoRoute += 1
            p.release()
        } else if onLink(dst) {
            resolveAndSend(p, hop: dst)
        } else if gateway != 0 {
            resolveAndSend(p, hop: gateway)
        } else {
            stats.txNoRoute += 1
            p.release()
        }
    }

    // MARK: IPv4 receive

    func parseIPv4Header(_ p: Packet) -> IPv4Header? {
        guard let vihl = p.u8(0), vihl >> 4 == 4, let total = p.u16(2), let id = p.u16(4), let ff = p.u16(6),
              let ttl = p.u8(8), let proto = p.u8(9), let src = p.u32(12), let dst = p.u32(16), let tos = p.u8(1)
        else { return nil }
        let ihl = Int(vihl & 15) * 4
        guard ihl >= 20, ihl <= p.length, Int(total) >= ihl, Int(total) <= p.length else { return nil }
        var h = IPv4Header()
        h.tos = tos
        h.ttl = ttl
        h.proto = proto
        h.id = id
        h.src = src
        h.dst = dst
        h.headerLength = ihl
        h.totalLength = Int(total)
        h.fragmentOffset = Int(ff & 0x1FFF) * 8
        h.moreFragments = ff & 0x2000 != 0
        h.broadcast = isBroadcast(dst) || isMulticastIP(dst)
        return h
    }

    /// `p` starts at the IPv4 header. `local`: from our own send queue.
    func handleIPv4(_ p: Packet, local: Bool) {
        defer { p.release() }
        stats.ipRx += 1
        guard var h = parseIPv4Header(p) else { stats.ipBadHeader += 1; return }
        guard inetChecksum(p.buf, p.start, h.headerLength) == 0 else { stats.ipBadChecksum += 1; return }
        p.trim(to: h.totalLength) // drops Ethernet padding
        let forUs = local || h.dst == ip || h.broadcast || ip == 0 // ip == 0: DHCP offers
        guard forUs, h.ttl != 0 else { stats.ipNotForUs += 1; return }
        // A sender that is broadcast or multicast is never valid.
        guard h.src != 0xFFFF_FFFF, !isMulticastIP(h.src) else { stats.ipBadHeader += 1; return }
        if h.moreFragments || h.fragmentOffset != 0 {
            stats.fragments += 1
            guard let whole = addFragment(h, p) else { return }
            h = whole.0
            defer { whole.1.release() }
            deliver(h, whole.1)
            return
        }
        p.pull(h.headerLength)
        deliver(h, p)
    }

    /// `p.start` is at the IP payload.
    func deliver(_ h: IPv4Header, _ p: Packet) {
        stats.ipDelivered += 1
        if let handler = handlers[Int(h.proto)] {
            handler(h, p)
        } else if !h.broadcast {
            sendICMPError(type: ICMPType.unreachable, code: ICMPUnreachCode.proto, h, p)
        }
    }

    // MARK: Reassembly

    /// Add a fragment (`p` at the IP header); returns the whole datagram, its
    /// payload at `start`, once complete. Duplicates are ignored; overlapping
    /// fragments, bad lengths and oversize datagrams discard the datagram.
    private func addFragment(_ h: IPv4Header, _ p: Packet) -> (IPv4Header, Packet)? {
        let plen = h.totalLength - h.headerLength
        let offset = h.fragmentOffset
        guard let payload = p.bytes(h.headerLength, plen) else { stats.reassemblyDropped += 1; return nil }
        var index = reassemblies.firstIndex(where: { $0.src == h.src && $0.dst == h.dst && $0.id == h.id && $0.proto == h.proto })
        if index == nil {
            if reassemblies.count >= reassemblyMaxDatagrams {
                stats.reassemblyDropped += 1
                reassemblies.removeFirst() // the oldest loses
            }
            reassemblies.append(Reassembly(src: h.src, dst: h.dst, id: h.id, proto: h.proto, expires: now &+ reassemblyTimeout))
            index = reassemblies.count - 1
            scheduleHousekeeping()
        }
        let r = reassemblies[index!]
        func discard() {
            stats.reassemblyDropped += 1
            if let i = reassemblies.firstIndex(where: { $0 === r }) { reassemblies.remove(at: i) }
        }
        // Whole-datagram limits: IP's 65535, minus a header.
        guard offset + plen <= 65535 - 20, plen > 0, h.moreFragments ? plen % 8 == 0 : true else { discard(); return nil }
        if !h.moreFragments {
            if r.total >= 0 && r.total != offset + plen { discard(); return nil }
            r.total = offset + plen
        }
        if r.total >= 0 {
            for f in r.fragments where f.offset + f.data.count > r.total { discard(); return nil }
            if offset + plen > r.total { discard(); return nil }
        }
        // Duplicate or overlap?
        for f in r.fragments {
            if f.offset == offset && f.data.count == plen { return nil } // exact duplicate
            if offset < f.offset + f.data.count && f.offset < offset + plen { discard(); return nil }
        }
        guard r.fragments.count < reassemblyMaxFragments, reassemblyBytes + plen <= reassemblyMaxBytes else {
            discard()
            return nil
        }
        // Insert sorted by offset.
        var at = r.fragments.count
        for (i, f) in r.fragments.enumerated() where f.offset > offset { at = i; break }
        r.fragments.insert(Fragment(offset: offset, data: payload), at: at)
        r.bytes += plen
        if offset == 0 {
            r.header = h
            r.headerBytes = p.bytes(0, h.headerLength) ?? []
        }
        guard r.total >= 0, r.header != nil else { return nil }
        var expected = 0
        for f in r.fragments {
            guard f.offset == expected else { return nil }
            expected += f.data.count
        }
        guard expected == r.total, var first = r.header else { return nil }
        var buffer = r.headerBytes
        for f in r.fragments { buffer.append(contentsOf: f.data) }
        if let i = reassemblies.firstIndex(where: { $0 === r }) { reassemblies.remove(at: i) }
        stats.reassembled += 1
        first.fragmentOffset = 0
        first.moreFragments = false
        first.totalLength = buffer.count
        return (first, Packet.large(buffer, start: first.headerLength))
    }

    private func reassemblyExpired(_ r: Reassembly) {
        // RFC 1122 3.3.2: if the first fragment arrived, tell the sender.
        guard let h = r.header, let first = r.fragments.first, first.offset == 0 else { return }
        let q = Packet.large(r.headerBytes + first.data.prefix(8), start: h.headerLength)
        sendICMPError(type: ICMPType.timeExceeded, code: 1, h, q)
    }

    // MARK: ICMP

    /// Send an ICMP error about the datagram header `h` / payload `p` (the
    /// IPv4 header must sit just before `p.start`). Never answers errors,
    /// broadcasts, non-first fragments or an unconfigured interface, and is
    /// rate limited.
    func sendICMPError(type: UInt8, code: UInt8, rest: UInt32 = 0, _ h: IPv4Header, _ p: Packet) {
        guard ip != 0, !h.broadcast, h.fragmentOffset == 0, h.src != 0, !isBroadcast(h.src), !isMulticastIP(h.src),
              p.start >= h.headerLength
        else { return }
        if h.proto == 1, let t = p.u8(0), t != ICMPType.echoRequest, t != ICMPType.echoReply { return }
        if now &- icmpWindowStart >= 100 { icmpWindowStart = now; icmpTokens = 10 }
        guard icmpTokens > 0 else { stats.icmpRateLimited += 1; return }
        icmpTokens -= 1
        let from = p.start - h.headerLength
        let to = min(p.end, p.start + 8)
        let out = Packet.make()
        out.appendU8(type)
        out.appendU8(code)
        out.appendU16(0)
        out.appendU32(rest)
        out.append(Array(p.buf[from..<to]))
        out.setU16(2, inetChecksum(out.buf, out.start, out.length))
        stats.icmpErrorsSent += 1
        sendIP(proto: 1, dst: h.src, out)
    }

    private func handleICMP(_ h: IPv4Header, _ p: Packet) {
        stats.icmpRx += 1
        guard p.length >= 8, let type = p.u8(0), let code = p.u8(1), inetChecksum(p.buf, p.start, p.length) == 0 else {
            stats.icmpBad += 1
            return
        }
        switch type {
        case ICMPType.echoRequest:
            // Not to broadcasts (smurf); never larger than we could send back.
            guard !h.broadcast, p.length + 20 <= dev.mtu, let id = p.u16(4), let seq = p.u16(6),
                  let data = p.bytes(8) else { return }
            let r = Packet.make()
            r.appendU8(ICMPType.echoReply)
            r.appendU8(0)
            r.appendU16(0)
            r.appendU16(id)
            r.appendU16(seq)
            r.append(data)
            r.setU16(2, inetChecksum(r.buf, r.start, r.length))
            stats.icmpEchoReplied += 1
            sendIP(proto: 1, dst: h.src, r, src: h.dst == ip ? ip : nil)
        case ICMPType.echoReply:
            if let id = p.u16(4), let seq = p.u16(6) { onEchoReply?(h.src, id, seq, h.ttl, p.length - 8) }
        case ICMPType.unreachable, ICMPType.timeExceeded:
            stats.icmpErrorsRx += 1
            handleICMPError(type: type, code: code, p)
        default:
            break
        }
    }

    /// Decode the quoted datagram in an ICMP error and pass it to the
    /// protocol's error handler. Ignored unless the quote is a datagram we
    /// could have sent (a valid header from our own address).
    private func handleICMPError(type: UInt8, code: UInt8, _ p: Packet) {
        guard let vihl = p.u8(8), vihl >> 4 == 4, let proto = p.u8(17), let src = p.u32(20), let dst = p.u32(24)
        else { stats.icmpBad += 1; return }
        let ihl = Int(vihl & 15) * 4
        guard ihl >= 20, src == ip, ip != 0 else { stats.icmpBad += 1; return }
        let t = 8 + ihl
        let err = ICMPError(type: type, code: code, mtu: type == ICMPType.unreachable && code == ICMPUnreachCode.fragNeeded
                                ? Int(p.u16(6) ?? 0) : 0,
                            originalSrc: src, originalDst: dst, proto: proto,
                            srcPort: p.u16(t) ?? 0, dstPort: p.u16(t + 2) ?? 0, seq: p.u32(t + 4) ?? 0)
        errorHandlers[Int(proto)]?(err)
    }

    /// Send an echo request with `size` payload bytes. False if it can't be sent.
    @discardableResult
    func sendEcho(to dst: IPv4Addr, id: UInt16, seq: UInt16, size: Int = 32) -> Bool {
        let p = Packet.make()
        p.appendU8(ICMPType.echoRequest)
        p.appendU8(0)
        p.appendU16(0)
        p.appendU16(id)
        p.appendU16(seq)
        var data = [UInt8](repeating: 0, count: max(0, min(size, dev.mtu - 28)))
        for i in 0..<data.count { data[i] = UInt8(truncatingIfNeeded: 0x61 &+ i) }
        p.append(data)
        p.setU16(2, inetChecksum(p.buf, p.start, p.length))
        return sendIP(proto: 1, dst: dst, p)
    }
}
