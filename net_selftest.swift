// Part 7 selftests: everything below the NIC runs off-screen over LinkPair
// with virtual time, so the results are deterministic. `NetRig` (two stacks on
// a LinkPair) and `NetWire` (one stack, hand-made frames in, captured frames
// out) are reusable by later phases, TCP included.

/// Two stacks, 10.1.0.1 (a) and 10.1.0.2 (b) on a /24, joined by a LinkPair.
/// `step()` advances virtual time by one tick and polls both.
final class NetRig {
    let pair: LinkPair
    let a: NetStack
    let b: NetStack
    var now: UInt64 = 1000

    static let ipA = ipv4(10, 1, 0, 1)
    static let ipB = ipv4(10, 1, 0, 2)
    static let mask = ipv4(255, 255, 255, 0)

    init(seed: UInt64 = 1, configured: Bool = true) {
        pair = LinkPair(seed: seed)
        a = NetStack(device: pair.a)
        b = NetStack(device: pair.b)
        a.now = now
        b.now = now
        if configured {
            a.configure(ip: NetRig.ipA, mask: NetRig.mask, gateway: 0)
            b.configure(ip: NetRig.ipB, mask: NetRig.mask, gateway: 0)
        }
    }

    func step() {
        now += 1
        pair.now = now
        a.poll(now: now)
        b.poll(now: now)
    }

    func run(_ ticks: Int) { for _ in 0..<ticks { step() } }

    /// Step until `cond()` or `limit` ticks; whether it held.
    @discardableResult
    func run(until cond: () -> Bool, limit: Int = 2000) -> Bool {
        var n = 0
        while !cond() && n < limit { step(); n += 1 }
        return cond()
    }
}

/// One stack (b, 10.1.0.2) fed hand-made frames "from" a fake peer at
/// 10.1.0.1; what it sends back is captured instead of processed.
final class NetWire {
    let pair = LinkPair(seed: 7)
    let stack: NetStack
    var frames: [[UInt8]] = []
    static let peerIP = ipv4(10, 1, 0, 1)

    init() {
        stack = NetStack(device: pair.b)
        stack.configure(ip: NetRig.ipB, mask: NetRig.mask, gateway: 0)
        stack.now = 1000
        pair.now = 1000
        pair.a.onReceive = { [self] p in
            if let f = p.bytes() { frames.append(f) }
            p.release()
        }
        // Make the stack know the peer, so it can answer without ARPing.
        injectARP(op: 1, spa: NetWire.peerIP, tpa: NetRig.ipB)
    }

    var peerMAC: MACAddr { pair.a.mac }

    func advance(_ ticks: Int = 1) {
        for _ in 0..<ticks {
            pair.now += 1
            stack.poll(now: pair.now)
            pair.a.poll()
        }
    }

    func injectARP(op: UInt16, spa: IPv4Addr, tpa: IPv4Addr) {
        var p: [UInt8] = [0, 1, 8, 0, 6, 4, UInt8(op >> 8), UInt8(op & 255)]
        for i in 0..<6 { p.append(UInt8(truncatingIfNeeded: peerMAC >> UInt64(8 * (5 - i)))) }
        p.append(contentsOf: netTestWord(spa))
        p.append(contentsOf: [UInt8](repeating: 0, count: 6))
        p.append(contentsOf: netTestWord(tpa))
        inject(netTestFrame(dst: op == 1 ? macBroadcast : stack.dev.mac, src: peerMAC, type: 0x0806, p))
    }

    func inject(_ frame: [UInt8]) {
        if let p = Packet.received(frame) { stack.receive(p) }
        advance()
    }

    /// An IPv4 datagram from the peer to the stack.
    func injectIP(proto: UInt8, payload: [UInt8], id: UInt16 = 1, offset: Int = 0, more: Bool = false,
                  dst: IPv4Addr = NetRig.ipB, ttl: UInt8 = 64, goodChecksum: Bool = true) {
        let ip = netTestIPv4(proto: proto, src: NetWire.peerIP, dst: dst, payload: payload, id: id, offset: offset,
                             more: more, ttl: ttl, goodChecksum: goodChecksum)
        inject(netTestFrame(dst: dst == 0xFFFF_FFFF ? macBroadcast : stack.dev.mac, src: peerMAC, type: 0x0800, ip))
    }

    /// IP payloads of captured frames with this protocol.
    func sent(proto: UInt8) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for f in frames where f.count >= 34 && f[12] == 8 && f[13] == 0 && f[23] == proto {
            let ihl = Int(f[14] & 15) * 4
            let total = Int(f[16]) << 8 | Int(f[17])
            if 14 + total <= f.count && total >= ihl { out.append(Array(f[(14 + ihl)..<(14 + total)])) }
        }
        return out
    }

    /// Captured ICMP messages of this type.
    func icmp(type: UInt8) -> [[UInt8]] { sent(proto: 1).filter { $0.first == type } }
}

func netTestWord(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * (3 - $0))) } }

func netTestFrame(dst: MACAddr, src: MACAddr, type: UInt16, _ payload: [UInt8]) -> [UInt8] {
    var f: [UInt8] = []
    for i in 0..<6 { f.append(UInt8(truncatingIfNeeded: dst >> UInt64(8 * (5 - i)))) }
    for i in 0..<6 { f.append(UInt8(truncatingIfNeeded: src >> UInt64(8 * (5 - i)))) }
    f.append(UInt8(type >> 8))
    f.append(UInt8(type & 255))
    return f + payload
}

func netTestIPv4(proto: UInt8, src: IPv4Addr, dst: IPv4Addr, payload: [UInt8], id: UInt16 = 1, offset: Int = 0,
                 more: Bool = false, ttl: UInt8 = 64, goodChecksum: Bool = true) -> [UInt8] {
    let total = 20 + payload.count
    let ff = UInt16(offset / 8) | (more ? 0x2000 : 0)
    var h: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 255), UInt8(id >> 8), UInt8(id & 255),
                      UInt8(ff >> 8), UInt8(ff & 255), ttl, proto, 0, 0]
    h += netTestWord(src) + netTestWord(dst)
    let c = inetChecksum(h, 0, 20) ^ (goodChecksum ? 0 : 0x1234)
    h[10] = UInt8(c >> 8)
    h[11] = UInt8(c & 255)
    return h + payload
}

func netTestICMPEcho(id: UInt16 = 1, seq: UInt16 = 1, data: [UInt8] = [1, 2, 3, 4], goodChecksum: Bool = true) -> [UInt8] {
    var m: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 255), UInt8(seq >> 8), UInt8(seq & 255)] + data
    let c = inetChecksum(m, 0, m.count) ^ (goodChecksum ? 0 : 0x4321)
    m[2] = UInt8(c >> 8)
    m[3] = UInt8(c & 255)
    return m
}

func netTestUDP(src: IPv4Addr, dst: IPv4Addr, sport: UInt16, dport: UInt16, data: [UInt8], goodChecksum: Bool = true) -> [UInt8] {
    let len = 8 + data.count
    var u: [UInt8] = [UInt8(sport >> 8), UInt8(sport & 255), UInt8(dport >> 8), UInt8(dport & 255),
                      UInt8(len >> 8), UInt8(len & 255), 0, 0] + data
    var c = csumFold(csumAdd(pseudoHeaderSum(src: src, dst: dst, proto: 17, length: len), u, 0, len))
    if c == 0 { c = 0xFFFF }
    c ^= goodChecksum ? 0 : 0x0F0F
    u[6] = UInt8(c >> 8)
    u[7] = UInt8(c & 255)
    return u
}

/// A pseudo-random test payload.
func netTestBytes(_ n: Int, seed: UInt64) -> [UInt8] {
    var rng = NetRNG(seed: seed)
    return (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next() >> 24) }
}

// MARK: DNS test helpers

/// A DNS reply for `qname` with the given answer records (name pointers are
/// written as compression pointers to the question when `compress`).
func netTestDNSReply(id: UInt16, qname: String, rcode: UInt16 = 0, flagsExtra: UInt16 = 0,
                     answers: [(owner: String, type: UInt16, ttl: UInt32, rdata: [UInt8])],
                     compress: Bool = true) -> [UInt8] {
    func encode(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        for l in s.split(separator: ".") { out.append(UInt8(l.utf8.count)); out.append(contentsOf: Array(l.utf8)) }
        out.append(0)
        return out
    }
    var m: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 0x81 | UInt8(flagsExtra >> 8), 0x80 | UInt8(rcode), 0, 1,
                      UInt8(answers.count >> 8), UInt8(answers.count & 255), 0, 0, 0, 0]
    m += encode(qname) + [0, 1, 0, 1]
    for a in answers {
        if compress && a.owner == qname { m += [0xC0, 12] } else { m += encode(a.owner) }
        m += [UInt8(a.type >> 8), UInt8(a.type & 255), 0, 1] + netTestWord(a.ttl)
        m += [UInt8(a.rdata.count >> 8), UInt8(a.rdata.count & 255)] + a.rdata
    }
    return m
}

func netTestEncodeName(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    for l in s.split(separator: ".") { out.append(UInt8(l.utf8.count)); out.append(contentsOf: Array(l.utf8)) }
    out.append(0)
    return out
}

/// A tiny DNS server on `stack`:53 answering from a table; counts queries.
final class NetTestDNSServer {
    let socket: UDPSocket
    var queries = 0
    /// name -> (type, rdata) records; a CNAME is `cname:` + target.
    var table: [String: [(UInt16, UInt32, [UInt8])]] = [:]
    /// Ignore the first n queries (a lossy server).
    var ignore = 0
    var nxdomain: [String] = []
    /// Names answered with only their first record (a dangling CNAME).
    var cnameOnly: [String] = []

    init(_ stack: NetStack) {
        socket = stack.udpBind(53)!
        socket.onReceive = { [self] in
            while let d = socket.receive() {
                queries += 1
                if ignore > 0 { ignore -= 1; continue }
                guard let m = parseDNS(d.data), let q = m.questions.first else { continue }
                let name = String(decoding: q.name, as: UTF8.self)
                let id = m.id
                if nxdomain.contains(name) {
                    socket.send(to: d.src, port: d.srcPort, netTestDNSReply(id: id, qname: name, rcode: 3, answers: []))
                    continue
                }
                var answers: [(owner: String, type: UInt16, ttl: UInt32, rdata: [UInt8])] = []
                var cur = name
                var hops = 0
                while let recs = table[cur], hops < 6 {
                    var followed = false
                    for (type, ttl, rdata) in recs {
                        answers.append((cur, type, ttl, type == 5 ? netTestEncodeName(String(decoding: rdata, as: UTF8.self)) : rdata))
                        if type == 5 { cur = String(decoding: rdata, as: UTF8.self); followed = true }
                    }
                    hops += 1
                    if !followed { break }
                }
                if cnameOnly.contains(name) { answers = Array(answers.prefix(1)) }
                socket.send(to: d.src, port: d.srcPort, netTestDNSReply(id: id, qname: name, answers: answers))
            }
        }
    }
}

/// A DHCP server stub on `stack`:67 that offers/acks one address.
final class NetTestDHCPServer {
    let socket: UDPSocket
    let stack: NetStack
    var offerIP = ipv4(10, 1, 0, 50)
    var lease: UInt32 = 3600
    var requests: [DHCPMessage] = []
    var nakNext = false
    var discovers = 0

    init(_ stack: NetStack) {
        self.stack = stack
        socket = stack.udpBind(67)!
        socket.onReceive = { [self] in
            while let d = socket.receive() {
                guard let m = parseDHCP(d.data), m.op == 1 else { continue }
                var type: UInt8 = 0
                if m.messageType == DHCPType.discover { type = DHCPType.offer; discovers += 1 }
                else if m.messageType == DHCPType.request { type = nakNext ? DHCPType.nak : DHCPType.ack; requests.append(m) }
                guard type != 0 else { continue }
                let reply = buildDHCP(op: 2, xid: m.xid, chaddr: m.chaddr, type: type, yiaddr: type == DHCPType.nak ? 0 : offerIP,
                                      serverID: stack.ip, mask: NetRig.mask, router: stack.ip, dns: stack.ip, lease: lease)
                // To the client's address when it has one (renewal), else broadcast.
                let unicast = m.ciaddr != 0
                socket.send(to: unicast ? m.ciaddr : 0xFFFF_FFFF, port: 68, reply)
            }
        }
    }
}

// MARK: Tests

func netTests(_ t: inout SelfTest) {
    netPacketTests(&t)
    netLinkTests(&t)
    netARPIPTests(&t)
    netHostileTests(&t)
    netReassemblyTests(&t)
    netHookTests(&t)
    netUDPTests(&t)
    netDHCPTests(&t)
    netDNSParseTests(&t)
    netDNSResolverTests(&t)
    tcpTests(&t) // net_tcp_selftest.swift
    netMachineTests(&t)
}

func netPacketTests(_ t: inout SelfTest) {
    let p = Packet.make()
    t.check("net: packet starts empty with headroom", p.length == 0 && p.start == Packet.headroom)
    p.append([1, 2, 3, 4, 5, 6])
    t.check("net: packet reads are big-endian and bounds-checked",
            p.u16(0) == 0x0102 && p.u32(2) == 0x0304_0506 && p.u8(6) == nil && p.u16(5) == nil && p.u48(0) == 0x0102_0304_0506
            && p.u32(-1) == nil && p.bytes(2, 9) == nil && p.bytes(2, 3) == [3, 4, 5])
    t.check("net: packet push/pull", p.push(4) && p.length == 10 && p.u8(0) == 0 && p.pull(4) && p.length == 6
            && !p.pull(7) && p.push(Packet.headroom + 1) == false)
    p.trim(to: 2)
    t.check("net: packet trim and setU16", p.length == 2 && p.setU16(0, 0xBEEF) && p.u16(0) == 0xBEEF && !p.setU16(1, 1))
    let before = packetPool.count
    p.release()
    p.release() // a double release must not put it on the list twice
    t.check("net: packet release is idempotent", packetPool.count == before + 1)
    let q = Packet.make()
    t.check("net: packet pool reuses buffers", q === p && packetPool.count == before)
    q.release()
    var many: [Packet] = []
    for _ in 0..<(Packet.poolCap + 50) { many.append(Packet.make()) }
    for m in many { m.release() }
    t.check("net: packet free list is capped", packetPool.count <= Packet.poolCap)
    let big = Packet.make()
    t.check("net: packet append refuses overflow", !big.append([UInt8](repeating: 0, count: Packet.size)) && big.length == 0)
    big.release()

    // The RFC 1071 example header: checksum field b861 verifies to zero.
    let hdr: [UInt8] = [0x45, 0, 0, 0x73, 0, 0, 0x40, 0, 0x40, 0x11, 0xb8, 0x61, 0xc0, 0xa8, 0, 1, 0xc0, 0xa8, 0, 0xc7]
    t.check("net: internet checksum verifies and computes",
            inetChecksum(hdr, 0, 20) == 0 && inetChecksum([0x45, 0, 0, 0x73, 0, 0, 0x40, 0, 0x40, 0x11, 0, 0, 0xc0, 0xa8, 0, 1, 0xc0, 0xa8, 0, 0xc7], 0, 20) == 0xb861)
    t.check("net: checksum of odd length and bad range", inetChecksum([0x01], 0, 1) == 0xFEFF && inetChecksum([1, 2], 5, 2) == 0xFFFF)
    t.check("net: parseIPv4", parseIPv4("10.0.2.15") == ipv4(10, 0, 2, 15) && parseIPv4("1.2.3") == nil && parseIPv4("1.2.3.256") == nil
            && parseIPv4("1.2.3.4.5") == nil && parseIPv4("a.b.c.d") == nil && parseIPv4("1..3.4") == nil && parseIPv4("-1.2.3.4") == nil)
    t.check("net: ipString and macString", ipString(ipv4(192, 168, 1, 77)) == "192.168.1.77" && macString(0x5254_0012_3456) == "52:54:00:12:34:56")
}

func netLinkTests(_ t: inout SelfTest) {
    func run(seed: UInt64, loss: Int, reorder: Int, dup: Int, delay: Int) -> (log: [UInt8], pair: LinkPair) {
        let pair = LinkPair(seed: seed)
        pair.lossPct = loss
        pair.reorderPct = reorder
        pair.dupPct = dup
        pair.delay = delay
        var log: [UInt8] = []
        pair.b.onReceive = { p in
            log.append(p.u8(0) ?? 0)
            p.release()
        }
        for i in 0..<200 {
            let p = Packet.make()
            p.appendU8(UInt8(truncatingIfNeeded: i))
            p.appendZeros(20)
            pair.a.send(p)
            if i % 4 == 3 { pair.now += 1; pair.b.poll() }
        }
        for _ in 0..<10 { pair.now += 1; pair.b.poll() }
        return (log, pair)
    }
    let x = run(seed: 99, loss: 30, reorder: 20, dup: 10, delay: 2)
    let y = run(seed: 99, loss: 30, reorder: 20, dup: 10, delay: 2)
    let z = run(seed: 100, loss: 30, reorder: 20, dup: 10, delay: 2)
    t.check("link: same seed, same deliveries", x.log == y.log && x.log != z.log)
    t.check("link: 30% loss drops roughly that many", x.pair.lost > 30 && x.pair.lost < 90 && x.pair.sent == 200)
    t.check("link: duplication and reordering happen", x.pair.duplicated > 0 && x.pair.reordered > 0)
    let clean = run(seed: 5, loss: 0, reorder: 0, dup: 0, delay: 0)
    t.check("link: a clean wire delivers everything in order", clean.log == (0..<200).map { UInt8(truncatingIfNeeded: $0) })
    let dup = run(seed: 5, loss: 0, reorder: 0, dup: 100, delay: 0)
    t.check("link: 100% duplication doubles the frames", dup.log.count == 400)
    let re = run(seed: 5, loss: 0, reorder: 50, dup: 0, delay: 0)
    var sorted = re.log
    for i in 1..<sorted.count { // insertion sort
        let v = sorted[i]
        var j = i - 1
        while j >= 0 && sorted[j] > v { sorted[j + 1] = sorted[j]; j -= 1 }
        sorted[j + 1] = v
    }
    t.check("link: reordering loses nothing but changes the order",
            re.log.count == 200 && re.log != (0..<200).map { UInt8(truncatingIfNeeded: $0) } && sorted == (0..<200).map { UInt8(truncatingIfNeeded: $0) })

    // Delay: not delivered until its time.
    let d = LinkPair(seed: 1)
    d.delay = 3
    var got = 0
    d.b.onReceive = { p in got += 1; p.release() }
    let p = Packet.make()
    p.appendZeros(30)
    d.a.send(p)
    d.b.poll()
    let early = got
    d.now += 2
    d.b.poll()
    let mid = got
    d.now += 1
    d.b.poll()
    t.check("link: delay holds frames back", early == 0 && mid == 0 && got == 1 && d.a.counters.txFrames == 1 && d.b.counters.rxFrames == 1)

    // Oversize frames are refused; Loopback echoes.
    let big = Packet.make()
    big.appendZeros(1600)
    d.a.send(big)
    t.check("link: oversize frame dropped", d.a.counters.txDropped == 1)
    let lo = Loopback()
    var echoed = 0
    lo.onReceive = { p in echoed = p.length; p.release() }
    let lp = Packet.make()
    lp.appendZeros(42)
    lo.send(lp)
    t.check("link: loopback queues until polled", echoed == 0 && lo.hasWork)
    lo.poll()
    t.check("link: loopback delivers", echoed == 42 && !lo.hasWork && lo.counters.rxFrames == 1)
}

func netARPIPTests(_ t: inout SelfTest) {
    let rig = NetRig(seed: 11)
    var reply: (IPv4Addr, UInt16, UInt16, UInt8, Int)? = nil
    rig.a.onEchoReply = { from, id, seq, ttl, size in reply = (from, id, seq, ttl, size) }
    _ = rig.a.sendEcho(to: NetRig.ipB, id: 0x77, seq: 5, size: 56)
    t.check("arp: the echo waits for ARP", rig.a.arpEntry(NetRig.ipB)?.queue.count == 1 && rig.a.stats.arpRequestsSent == 1)
    rig.run(until: { reply != nil }, limit: 50)
    t.check("icmp: two stacks ping each other over ARP",
            reply?.0 == NetRig.ipB && reply?.1 == 0x77 && reply?.2 == 5 && reply?.3 == 64 && reply?.4 == 56)
    t.check("arp: both sides learned the other's MAC", rig.a.arpLookup(NetRig.ipB) == rig.pair.b.mac && rig.b.arpLookup(NetRig.ipA) == rig.pair.a.mac)
    t.check("icmp: counters", rig.b.stats.icmpEchoReplied == 1 && rig.a.stats.arpRepliesSent == 0 && rig.b.stats.arpRepliesSent == 1)

    // Self and loopback addresses don't touch the wire.
    let frames = rig.pair.a.counters.txFrames
    reply = nil
    _ = rig.a.sendEcho(to: NetRig.ipA, id: 1, seq: 1)
    rig.a.poll(now: rig.now)
    t.check("icmp: pinging ourselves stays inside", reply?.0 == NetRig.ipA && rig.pair.a.counters.txFrames == frames)
    reply = nil
    _ = rig.a.sendEcho(to: ipv4(127, 0, 0, 1), id: 1, seq: 2)
    rig.a.poll(now: rig.now)
    t.check("icmp: 127/8 is local too", reply?.2 == 2)

    // ARP entries expire and are asked for again.
    rig.a.arpTTL = 50
    rig.b.arpTTL = 50
    rig.a.arpTable.removeAll()
    reply = nil
    _ = rig.a.sendEcho(to: NetRig.ipB, id: 1, seq: 9)
    rig.run(until: { reply != nil }, limit: 50)
    let asked = rig.a.stats.arpRequestsSent
    rig.run(60)
    t.check("arp: an entry expires", rig.a.arpLookup(NetRig.ipB) == nil)
    reply = nil
    _ = rig.a.sendEcho(to: NetRig.ipB, id: 1, seq: 10)
    rig.run(until: { reply != nil }, limit: 50)
    t.check("arp: ... and is re-resolved on demand", rig.a.stats.arpRequestsSent > asked && reply?.2 == 10)

    // An unanswered ARP is retried, then the queue is dropped.
    let dead = ipv4(10, 1, 0, 99)
    for _ in 0..<10 { _ = rig.a.sendEcho(to: dead, id: 1, seq: 1) }
    t.check("arp: the wait queue is bounded", rig.a.arpEntry(dead)?.queue.count == rig.a.arpMaxQueue && rig.a.stats.arpQueueDropped == 6)
    let failedBefore = rig.a.stats.arpFailed
    rig.run(400)
    t.check("arp: no answer after 3 requests gives up", rig.a.stats.arpFailed == failedBefore + 1 && rig.a.arpEntry(dead) == nil)

    // ARP flood: the table is capped.
    for i in 0..<100 {
        let w = rig.a
        w.stats.arpRx += 0
        _ = w.sendEcho(to: ipv4(10, 1, 0, UInt32(100 + i)), id: 1, seq: 1)
    }
    t.check("arp: the table is capped", rig.a.arpTable.count <= rig.a.arpMaxEntries)

    // Off-subnet goes through the gateway; with none it is refused.
    let rig2 = NetRig(seed: 12)
    rig2.a.configure(ip: NetRig.ipA, mask: NetRig.mask, gateway: NetRig.ipB)
    _ = rig2.a.sendEcho(to: ipv4(192, 0, 2, 7), id: 1, seq: 1)
    rig2.run(5)
    t.check("ip: off-subnet traffic goes to the gateway's MAC",
            rig2.a.arpLookup(NetRig.ipB) == rig2.pair.b.mac && rig2.b.stats.ipNotForUs == 1)
    let noGW = NetRig(seed: 13)
    _ = noGW.a.sendEcho(to: ipv4(192, 0, 2, 7), id: 1, seq: 1)
    t.check("ip: no route is counted", noGW.a.stats.txNoRoute == 1)
    var tooBig = Packet.make()
    tooBig.appendZeros(1490)
    t.check("ip: oversize payloads are refused, never fragmented", !noGW.a.sendIP(proto: 99, dst: NetRig.ipB, tooBig) && noGW.a.stats.txTooBig == 1)
    tooBig = Packet.make()
    tooBig.appendZeros(1480)
    t.check("ip: a payload of mtu-20 fits", noGW.a.sendIP(proto: 99, dst: NetRig.ipB, tooBig))

    // Hostile ARP.
    let w = NetWire()
    let learned = w.stack.arpTable.count
    w.injectARP(op: 2, spa: ipv4(10, 1, 0, 77), tpa: NetRig.ipB) // unsolicited reply
    t.check("arp: unsolicited replies are not learned", w.stack.arpTable.count == learned)
    w.injectARP(op: 1, spa: 0xFFFF_FFFF, tpa: NetRig.ipB)
    w.injectARP(op: 1, spa: 0, tpa: NetRig.ipB)
    t.check("arp: bogus sender addresses are rejected", w.stack.stats.arpBad == 2 && w.stack.arpTable.count == learned)
    w.inject(netTestFrame(dst: macBroadcast, src: w.peerMAC, type: 0x0806, [0, 1, 8, 0, 6, 4, 0, 9]))
    w.inject(netTestFrame(dst: macBroadcast, src: w.peerMAC, type: 0x0806, [0, 7, 8, 0, 6, 4, 0, 1] + [UInt8](repeating: 0, count: 20)))
    t.check("arp: truncated and wrong-hardware packets are dropped", w.stack.stats.arpBad == 4)
    w.frames.removeAll()
    w.injectARP(op: 1, spa: NetWire.peerIP, tpa: ipv4(10, 1, 0, 200)) // not for us
    t.check("arp: no reply for other addresses", w.frames.isEmpty)
}

func netHostileTests(_ t: inout SelfTest) {
    let w = NetWire()
    let echo = netTestICMPEcho()
    w.injectIP(proto: 1, payload: echo)
    t.check("icmp: the stub answers a good echo", w.icmp(type: 0).count == 1)
    w.frames.removeAll()
    w.injectIP(proto: 1, payload: echo, goodChecksum: false)
    t.check("ip: bad header checksum dropped and counted", w.stack.stats.ipBadChecksum == 1 && w.icmp(type: 0).isEmpty)
    w.injectIP(proto: 1, payload: netTestICMPEcho(goodChecksum: false))
    t.check("icmp: bad checksum dropped and counted", w.stack.stats.icmpBad == 1 && w.icmp(type: 0).isEmpty)
    w.injectIP(proto: 17, payload: netTestUDP(src: NetWire.peerIP, dst: NetRig.ipB, sport: 1, dport: 2, data: [1], goodChecksum: false))
    t.check("udp: bad checksum dropped and counted", w.stack.stats.udpBad == 1 && w.icmp(type: 3).isEmpty)
    w.injectIP(proto: 1, payload: echo, ttl: 0)
    t.check("ip: TTL 0 dropped", w.icmp(type: 0).isEmpty)
    w.injectIP(proto: 1, payload: echo, dst: ipv4(10, 1, 0, 9))
    t.check("ip: other destinations are not ours", w.icmp(type: 0).isEmpty && w.stack.stats.ipNotForUs >= 1)
    w.injectIP(proto: 1, payload: echo, dst: 0xFFFF_FFFF)
    t.check("icmp: broadcast echo requests are not answered", w.icmp(type: 0).isEmpty)

    // Malformed headers.
    let good = netTestIPv4(proto: 1, src: NetWire.peerIP, dst: NetRig.ipB, payload: echo)
    func raw(_ ip: [UInt8]) { w.inject(netTestFrame(dst: w.stack.dev.mac, src: w.peerMAC, type: 0x0800, ip)) }
    let badBefore = w.stack.stats.ipBadHeader
    var v6 = good; v6[0] = 0x65
    var ihl4 = good; ihl4[0] = 0x44
    var longIHL = good; longIHL[0] = 0x4F
    var bigTotal = good; bigTotal[2] = 0xFF
    var smallTotal = good; smallTotal[3] = 10
    raw(v6); raw(ihl4); raw(longIHL); raw(bigTotal); raw(smallTotal); raw(Array(good[0..<19])); raw([]); raw([0x45])
    t.check("ip: malformed headers are counted, not trusted", w.stack.stats.ipBadHeader == badBefore + 8)
    w.inject(netTestFrame(dst: w.stack.dev.mac, src: w.peerMAC, type: 0x86DD, [UInt8](repeating: 0, count: 40)))
    w.inject([1, 2, 3])
    t.check("net: unknown ethertypes and runt frames are counted", w.stack.stats.rxUnknownEtherType == 1 && w.stack.stats.rxBadFrame == 1)
    // A trailing Ethernet pad is trimmed off.
    w.frames.removeAll()
    w.inject(netTestFrame(dst: w.stack.dev.mac, src: w.peerMAC, type: 0x0800, good + [0, 0, 0, 0, 0, 0]))
    t.check("ip: Ethernet padding is ignored", w.icmp(type: 0).count == 1)

    // Fuzz: mutated and random frames must never trap.
    var rng = NetRNG(seed: 2024)
    let seeds: [[UInt8]] = [
        netTestFrame(dst: w.stack.dev.mac, src: w.peerMAC, type: 0x0800, good),
        netTestFrame(dst: w.stack.dev.mac, src: w.peerMAC, type: 0x0800,
                     netTestIPv4(proto: 17, src: NetWire.peerIP, dst: NetRig.ipB,
                                 payload: netTestUDP(src: NetWire.peerIP, dst: NetRig.ipB, sport: 5, dport: 6, data: [1, 2, 3]))),
        netTestFrame(dst: macBroadcast, src: w.peerMAC, type: 0x0806, [0, 1, 8, 0, 6, 4, 0, 1, 1, 2, 3, 4, 5, 6, 10, 1, 0, 1, 0, 0, 0, 0, 0, 0, 10, 1, 0, 2]),
        netTestFrame(dst: w.stack.dev.mac, src: w.peerMAC, type: 0x0800,
                     netTestIPv4(proto: 99, src: NetWire.peerIP, dst: NetRig.ipB, payload: [UInt8](repeating: 7, count: 64), offset: 8, more: true)),
    ]
    for round in 0..<3000 {
        var f = seeds[round % seeds.count]
        let flips = 1 + rng.below(4)
        for _ in 0..<flips { f[rng.below(f.count)] = UInt8(truncatingIfNeeded: rng.next()) }
        if rng.below(4) == 0 { f = Array(f[0..<rng.below(f.count + 1)]) }
        if round % 50 == 0 { f = (0..<rng.below(200)).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }
        if let p = Packet.received(f) { w.stack.receive(p) }
        if round % 100 == 99 { w.frames.removeAll(); w.advance(30) }
    }
    t.check("net: 3000 fuzzed frames did not trap the stack", w.stack.stats.rxFrames > 3000)
}

func netReassemblyTests(_ t: inout SelfTest) {
    let payload = netTestBytes(3000, seed: 42)
    let want = fnv1a64(payload)
    // Cut points at multiples of 8.
    let cuts = [(0, 1480), (1480, 1480), (2960, 40)]
    func send(_ w: NetWire, order: [Int], id: UInt16, dupFirst: Bool = false) {
        for i in order {
            let (off, len) = cuts[i]
            w.injectIP(proto: 99, payload: Array(payload[off..<(off + len)]), id: id, offset: off, more: i != 2)
            if dupFirst && i == order[0] {
                w.injectIP(proto: 99, payload: Array(payload[off..<(off + len)]), id: id, offset: off, more: i != 2)
            }
        }
    }
    let orders = [[0, 1, 2], [2, 1, 0], [1, 0, 2], [1, 2, 0], [0, 2, 1], [2, 0, 1]]
    var allGood = true
    for (n, order) in orders.enumerated() {
        let w = NetWire()
        var got: [UInt8] = []
        var hdrOK = false
        w.stack.registerProtocol(99) { h, p in
            got = p.bytes() ?? []
            hdrOK = h.proto == 99 && h.src == NetWire.peerIP && !h.moreFragments && h.fragmentOffset == 0
        }
        send(w, order: order, id: UInt16(n + 1))
        if fnv1a64(got) != want || got.count != 3000 || !hdrOK || w.stack.stats.reassembled != 1 { allGood = false }
    }
    t.check("ip: fragments reassemble in any of 6 orders", allGood)

    var rng = NetRNG(seed: 5)
    var randomGood = true
    for round in 0..<20 {
        // Random cuts, random order.
        let w = NetWire()
        var got: [UInt8] = []
        w.stack.registerProtocol(99) { _, p in got = p.bytes() ?? [] }
        var pieces: [(Int, Int)] = []
        var off = 0
        while off < 3000 {
            let len = min(3000 - off, 8 * (1 + rng.below(100)))
            pieces.append((off, len))
            off += len
        }
        var order = Array(0..<pieces.count)
        for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, rng.below(i + 1)) }
        for i in order {
            let (o, l) = pieces[i]
            w.injectIP(proto: 99, payload: Array(payload[o..<(o + l)]), id: 9, offset: o, more: o + l < 3000)
        }
        if fnv1a64(got) != want { randomGood = false }
        _ = round
    }
    t.check("ip: random fragment sizes and order reassemble", randomGood)

    let w = NetWire()
    var count = 0
    var last: [UInt8] = []
    w.stack.registerProtocol(99) { _, p in count += 1; last = p.bytes() ?? [] }
    send(w, order: [0, 1, 2], id: 20, dupFirst: true)
    t.check("ip: a duplicated fragment is tolerated", count == 1 && fnv1a64(last) == want)

    // Overlap discards the datagram.
    let w2 = NetWire()
    var c2 = 0
    w2.stack.registerProtocol(99) { _, _ in c2 += 1 }
    w2.injectIP(proto: 99, payload: Array(payload[0..<64]), id: 30, offset: 0, more: true)
    w2.injectIP(proto: 99, payload: Array(payload[32..<96]), id: 30, offset: 32, more: true)
    w2.injectIP(proto: 99, payload: Array(payload[64..<72]), id: 30, offset: 64, more: false)
    t.check("ip: overlapping fragments discard the datagram", c2 == 0 && w2.stack.stats.reassemblyDropped >= 1)
    // Non-multiple-of-8 middle fragment, zero-length, and oversize datagrams.
    w2.injectIP(proto: 99, payload: [1, 2, 3, 4, 5], id: 31, offset: 0, more: true)
    w2.injectIP(proto: 99, payload: [1, 2, 3, 4, 5, 6, 7, 8], id: 32, offset: 65520, more: false)
    t.check("ip: bad fragment lengths and oversize datagrams are dropped", w2.stack.stats.reassemblyDropped >= 3 && w2.stack.reassemblies.count <= 1)

    // Memory caps.
    let w3 = NetWire()
    for id in 0..<30 { w3.injectIP(proto: 99, payload: [UInt8](repeating: 1, count: 16), id: UInt16(100 + id), offset: 0, more: true) }
    t.check("ip: in-progress datagrams are capped", w3.stack.reassemblies.count <= w3.stack.reassemblyMaxDatagrams)
    let w4 = NetWire()
    w4.stack.reassemblyMaxBytes = 100
    for i in 0..<5 { w4.injectIP(proto: 99, payload: [UInt8](repeating: 1, count: 64), id: 7, offset: i * 64, more: true) }
    t.check("ip: reassembly memory is capped", w4.stack.reassemblyBytes <= 100 && w4.stack.stats.reassemblyDropped >= 1)

    // Timeout: only the first fragment arrives; the sender is told.
    let w5 = NetWire()
    w5.stack.reassemblyTimeout = 200
    w5.injectIP(proto: 99, payload: Array(payload[0..<1480]), id: 55, offset: 0, more: true)
    w5.frames.removeAll()
    w5.advance(250)
    let te = w5.icmp(type: 11)
    t.check("ip: reassembly times out and sends time-exceeded",
            w5.stack.reassemblies.isEmpty && w5.stack.stats.reassemblyTimeouts == 1 && te.count == 1 && te[0][1] == 1)
    let w6 = NetWire()
    w6.stack.reassemblyTimeout = 200
    w6.injectIP(proto: 99, payload: Array(payload[1480..<2960]), id: 56, offset: 1480, more: true)
    w6.frames.removeAll()
    w6.advance(250)
    t.check("ip: no time-exceeded when the first fragment never came", w6.stack.stats.reassemblyTimeouts == 1 && w6.icmp(type: 11).isEmpty)
}

func netHookTests(_ t: inout SelfTest) {
    // The TCP hooks: a protocol-6 handler on b, and unreachable reports on a.
    let rig = NetRig(seed: 21)
    var received: [UInt8] = []
    var from: IPv4Addr = 0
    rig.b.registerProtocol(6) { h, p in received = p.bytes() ?? []; from = h.src }
    var segment = Packet.make()
    segment.append([0x04, 0xD2, 0x00, 0x50, 0xAA, 0xBB, 0xCC, 0xDD, 1, 2, 3])
    rig.a.sendIP(proto: 6, dst: NetRig.ipB, segment)
    rig.run(until: { !received.isEmpty }, limit: 50)
    t.check("hook: a protocol-6 handler receives the IP payload", received == [0x04, 0xD2, 0x00, 0x50, 0xAA, 0xBB, 0xCC, 0xDD, 1, 2, 3] && from == NetRig.ipA)

    rig.b.unregisterProtocol(6)
    var err: ICMPError? = nil
    rig.a.setErrorHandler(proto: 6) { e in err = e }
    segment = Packet.make()
    segment.append([0x04, 0xD2, 0x00, 0x50, 0xAA, 0xBB, 0xCC, 0xDD, 1, 2, 3])
    rig.a.sendIP(proto: 6, dst: NetRig.ipB, segment)
    rig.run(until: { err != nil }, limit: 50)
    t.check("hook: no protocol handler gives ICMP protocol unreachable to the sender's handler",
            err?.type == ICMPType.unreachable && err?.code == ICMPUnreachCode.proto && err?.proto == 6)
    t.check("hook: the report names ports and the TCP sequence number",
            err?.srcPort == 1234 && err?.dstPort == 80 && err?.seq == 0xAABB_CCDD && err?.originalDst == NetRig.ipB && err?.originalSrc == NetRig.ipA)

    // UDP to a closed port: port unreachable lands on the socket.
    let sock = rig.a.udpBind()!
    sock.send(to: NetRig.ipB, port: 9999, [1, 2, 3])
    rig.run(until: { sock.lastError != nil }, limit: 50)
    t.check("hook: UDP to a closed port reports port unreachable to the socket",
            sock.lastError?.code == ICMPUnreachCode.port && sock.lastError?.dstPort == 9999 && sock.lastError?.srcPort == sock.port)
    sock.close()

    // Spoofed errors (quoting a datagram not from us) are ignored.
    let w = NetWire()
    var spoofed = false
    w.stack.setErrorHandler(proto: 6) { _ in spoofed = true }
    let quote = netTestIPv4(proto: 6, src: ipv4(1, 2, 3, 4), dst: NetWire.peerIP, payload: [0, 1, 0, 2, 0, 0, 0, 0])
    var msg: [UInt8] = [3, 3, 0, 0, 0, 0, 0, 0] + Array(quote[0..<28])
    let c = inetChecksum(msg, 0, msg.count)
    msg[2] = UInt8(c >> 8); msg[3] = UInt8(c & 255)
    w.injectIP(proto: 1, payload: msg)
    t.check("hook: ICMP errors about datagrams we didn't send are ignored", !spoofed && w.stack.stats.icmpBad == 1)
    var truncated: [UInt8] = [3, 3, 0, 0, 0, 0, 0, 0, 0x45, 0, 0]
    let tc = inetChecksum(truncated, 0, truncated.count)
    truncated[2] = UInt8(tc >> 8); truncated[3] = UInt8(tc & 255)
    w.injectIP(proto: 1, payload: truncated)
    t.check("hook: a truncated ICMP error is dropped", !spoofed && w.stack.stats.icmpBad == 2)

    // No error about errors, nor about broadcasts; rate limited.
    let w2 = NetWire()
    w2.injectIP(proto: 1, payload: [3, 1, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 28))
    w2.injectIP(proto: 99, payload: [1, 2, 3], dst: 0xFFFF_FFFF)
    t.check("icmp: no errors about errors or broadcasts", w2.icmp(type: 3).isEmpty && w2.sent(proto: 1).isEmpty)
    for i in 0..<30 { w2.injectIP(proto: 99, payload: [1, 2, 3], id: UInt16(i)) }
    t.check("icmp: error replies are rate limited", w2.icmp(type: 3).count == 10 && w2.stack.stats.icmpRateLimited == 20)

    // Timers.
    let rig2 = NetRig(seed: 3)
    var fired: [Int] = []
    rig2.a.schedule(after: 5) { fired.append(5) }
    rig2.a.schedule(after: 2) { fired.append(2) }
    let cancelled = rig2.a.schedule(after: 3) { fired.append(3) }
    rig2.a.cancel(cancelled)
    rig2.a.schedule(after: 4) {
        fired.append(4)
        rig2.a.schedule(after: 1) { fired.append(45) } // reschedules from inside a timer
    }
    t.check("timer: nextDeadline is the earliest", rig2.a.nextDeadline == rig2.a.now + 2)
    rig2.run(1)
    let early = fired
    rig2.run(1)
    t.check("timer: nothing fires early", early.isEmpty && fired == [2])
    t.check("timer: needsPoll once due", !rig2.a.needsPoll(rig2.now + 1) && rig2.a.needsPoll(rig2.now + 2))
    rig2.run(6)
    t.check("timer: order, cancel and reschedule from a timer", fired == [2, 4, 5, 45] && rig2.a.nextDeadline == UInt64.max)
}

func netUDPTests(_ t: inout SelfTest) {
    let rig = NetRig(seed: 31)
    let server = rig.b.udpBind(7000)!
    t.check("udp: a bound port can't be bound again", rig.b.udpBind(7000) == nil)
    let client = rig.a.udpBind()!
    t.check("udp: ephemeral ports are in the dynamic range and distinct", client.port >= 49152 && rig.a.udpBind()!.port != client.port)
    var notified = 0
    server.onReceive = { notified += 1 }
    client.send(to: NetRig.ipB, port: 7000, Array("hello udp".utf8))
    rig.run(until: { !server.queue.isEmpty }, limit: 50)
    let d = server.receive()
    t.check("udp: a datagram arrives with its source", d?.data == Array("hello udp".utf8) && d?.src == NetRig.ipA && d?.srcPort == client.port && notified == 1)
    server.send(to: d!.src, port: d!.srcPort, [9, 9])
    rig.run(until: { !client.queue.isEmpty }, limit: 50)
    t.check("udp: and the reply returns", client.receive()?.data == [9, 9])
    t.check("udp: oversize payloads are refused", !client.send(to: NetRig.ipB, port: 7000, [UInt8](repeating: 0, count: 1473)))
    t.check("udp: the largest payload (1472) goes", client.send(to: NetRig.ipB, port: 7000, [UInt8](repeating: 0, count: 1472)))
    rig.run(10)
    for _ in 0..<40 { client.send(to: NetRig.ipB, port: 7000, [1]) }
    rig.run(10)
    t.check("udp: the receive queue is bounded", server.queue.count == UDPSocket.maxQueue && rig.b.stats.udpQueueDropped > 0)
    server.close()
    t.check("udp: closing frees the port", rig.b.udpBind(7000) != nil)
    // Short and inconsistent UDP headers.
    let w = NetWire()
    let s = w.stack.udpBind(53)!
    w.injectIP(proto: 17, payload: [0, 1, 0, 53, 0, 8])
    w.injectIP(proto: 17, payload: [0, 1, 0, 53, 0, 20, 0, 0, 1, 2])
    w.injectIP(proto: 17, payload: [0, 1, 0, 53, 0, 4, 0, 0])
    t.check("udp: truncated headers and bad lengths are dropped", w.stack.stats.udpBad == 3 && s.queue.isEmpty)
    w.injectIP(proto: 17, payload: [0, 1, 0, 53, 0, 9, 0, 0, 0x42, 0xFF])
    t.check("udp: zero checksum accepted, extra bytes trimmed", s.queue.count == 1 && s.queue[0].data == [0x42])
}

func netDHCPTests(_ t: inout SelfTest) {
    let msg = buildDHCP(op: 2, xid: 0x1234_5678, chaddr: 0x0200_0000_000A, type: DHCPType.ack, yiaddr: ipv4(10, 0, 0, 9),
                        serverID: ipv4(10, 0, 0, 1), mask: ipv4(255, 255, 255, 0), router: ipv4(10, 0, 0, 1),
                        dns: ipv4(10, 0, 0, 3), lease: 7200, t1: 3600, t2: 6300)
    let m = parseDHCP(msg)
    t.check("dhcp: a canned ACK parses", m?.messageType == DHCPType.ack && m?.yiaddr == ipv4(10, 0, 0, 9) && m?.serverID == ipv4(10, 0, 0, 1)
            && m?.mask == ipv4(255, 255, 255, 0) && m?.router == ipv4(10, 0, 0, 1) && m?.dns == ipv4(10, 0, 0, 3)
            && m?.leaseSeconds == 7200 && m?.t1Seconds == 3600 && m?.t2Seconds == 6300 && m?.xid == 0x1234_5678 && m?.chaddr == 0x0200_0000_000A)
    var allTruncationsSafe = true
    for n in 0..<msg.count where parseDHCP(Array(msg[0..<n])) != nil && n < 241 { allTruncationsSafe = false }
    t.check("dhcp: truncation at every length fails cleanly", allTruncationsSafe && parseDHCP([]) == nil)
    var badCookie = msg; badCookie[236] = 0
    var overrun = Array(msg[0..<240]) + [53, 1, 5, 6, 200, 1, 2] // option 6 claims 200 bytes
    var noType = Array(msg[0..<240]) + [1, 4, 255, 255, 255, 0, 255]
    overrun += []
    noType += []
    t.check("dhcp: bad cookie, overrunning option, missing type are rejected", parseDHCP(badCookie) == nil && parseDHCP(overrun) == nil && parseDHCP(noType) == nil)
    var rng = NetRNG(seed: 77)
    var fuzzOK = true
    for _ in 0..<2000 {
        var f = msg
        for _ in 0..<(1 + rng.below(6)) { f[rng.below(f.count)] = UInt8(truncatingIfNeeded: rng.next()) }
        if rng.below(3) == 0 { f = Array(f[0..<rng.below(f.count + 1)]) }
        _ = parseDHCP(f)
        fuzzOK = true
    }
    t.check("dhcp: 2000 fuzzed messages did not trap", fuzzOK)

    // A full exchange over a LinkPair, then renewal.
    let rig = NetRig(seed: 41, configured: false)
    rig.b.configure(ip: NetRig.ipB, mask: NetRig.mask, gateway: 0)
    let server = NetTestDHCPServer(rig.b)
    server.lease = 200
    let client = DHCPClient(stack: rig.a)!
    client.start()
    rig.run(until: { client.state == .bound }, limit: 300)
    t.check("dhcp: DISCOVER, OFFER, REQUEST, ACK configures the stack",
            client.state == .bound && rig.a.ip == server.offerIP && rig.a.mask == NetRig.mask && rig.a.gateway == NetRig.ipB
            && rig.a.dns == NetRig.ipB && !client.usingFallback && client.leaseSeconds == 200 && server.discovers == 1)
    t.check("dhcp: lease time is tracked", client.leaseRemaining > 195 && client.leaseRemaining <= 200)
    let requestsBefore = server.requests.count
    rig.run(until: { client.state == .renewing || server.requests.count > requestsBefore }, limit: 11_000)
    rig.run(10)
    t.check("dhcp: renewal at T1 asks the server (ciaddr set) and stays bound",
            server.requests.count == requestsBefore + 1 && server.requests.last?.ciaddr == server.offerIP && client.state == .bound
            && client.leaseRemaining > 190 && client.leaseRemaining <= 200)
    // The server goes quiet: rebind at T2 (broadcast), then expiry starts over.
    server.socket.close()
    rig.run(until: { client.state == .rebinding }, limit: 20_000)
    t.check("dhcp: rebinding at T2 when renewal gets no answer", client.state == .rebinding)
    rig.run(until: { client.state == .selecting }, limit: 20_000)
    t.check("dhcp: an expired lease deconfigures and rediscovers", client.state == .selecting && (rig.a.ip == 0 || client.usingFallback))

    // A NAK restarts discovery.
    let rig2 = NetRig(seed: 42, configured: false)
    rig2.b.configure(ip: NetRig.ipB, mask: NetRig.mask, gateway: 0)
    let s2 = NetTestDHCPServer(rig2.b)
    s2.nakNext = true
    let c2 = DHCPClient(stack: rig2.a)!
    c2.start()
    rig2.run(until: { s2.requests.count >= 2 }, limit: 600)
    t.check("dhcp: a NAK sends the client back to DISCOVER", s2.discovers >= 2 && c2.state != .bound)

    // No server: the static fallback after 5 s.
    let rig3 = NetRig(seed: 43, configured: false)
    let c3 = DHCPClient(stack: rig3.a)!
    c3.start()
    rig3.run(499)
    t.check("dhcp: no fallback before 5 s", rig3.a.ip == 0 && !c3.usingFallback)
    rig3.run(3)
    t.check("dhcp: static fallback after 5 s without an offer",
            c3.usingFallback && rig3.a.ip == ipv4(10, 0, 2, 15) && rig3.a.gateway == ipv4(10, 0, 2, 2) && rig3.a.dns == ipv4(10, 0, 2, 3))
    // ...and a late server still wins.
    rig3.b.configure(ip: NetRig.ipB, mask: NetRig.mask, gateway: 0)
    let s3 = NetTestDHCPServer(rig3.b)
    rig3.run(until: { c3.state == .bound }, limit: 2000)
    t.check("dhcp: a late offer replaces the fallback", c3.state == .bound && rig3.a.ip == s3.offerIP && !c3.usingFallback)
    // A reply with the wrong xid or MAC is ignored.
    let rig4 = NetRig(seed: 44, configured: false)
    let c4 = DHCPClient(stack: rig4.a)!
    c4.start()
    var offer = DHCPMessage()
    offer.op = 2; offer.xid = c4.xid &+ 1; offer.chaddr = rig4.a.dev.mac; offer.messageType = DHCPType.offer
    offer.yiaddr = ipv4(10, 9, 9, 9); offer.serverID = ipv4(10, 9, 9, 1)
    c4.handle(offer)
    offer.xid = c4.xid; offer.chaddr = 0x1234
    c4.handle(offer)
    t.check("dhcp: replies with another xid or MAC are ignored", c4.state == .selecting)
}

func netDNSParseTests(_ t: inout SelfTest) {
    let reply = netTestDNSReply(id: 0x1111, qname: "www.example.test", answers: [
        ("www.example.test", 5, 300, netTestEncodeName("host.example.test")),
        ("host.example.test", 1, 120, [192, 0, 2, 33]),
    ])
    let m = parseDNS(reply)
    t.check("dns: a CNAME + A reply parses", m?.id == 0x1111 && m?.questions.first?.name == Array("www.example.test".utf8) && m?.answers.count == 2
            && m?.isResponse == true && m?.rcode == 0)
    if let a = m?.answers, a.count == 2, case .cname(let target) = a[0].data, case .a(let addr) = a[1].data {
        t.check("dns: compressed owner names and CNAME rdata decode", target == Array("host.example.test".utf8) && addr == ipv4(192, 0, 2, 33)
                && a[0].name == Array("www.example.test".utf8) && a[1].ttl == 120)
    } else {
        t.check("dns: compressed owner names and CNAME rdata decode", false)
    }
    var allTruncated = true
    for n in 0..<reply.count where parseDNS(Array(reply[0..<n])) != nil { allTruncated = false }
    t.check("dns: truncation at every length fails cleanly", allTruncated)

    // Compression abuse.
    var selfLoop = Array(reply[0..<12])
    selfLoop += [0xC0, 12, 0, 1, 0, 1] // question name = pointer to itself
    selfLoop[5] = 1
    var forward = Array(reply[0..<12]) + [0xC0, 30, 0, 1, 0, 1] + [UInt8](repeating: 0, count: 20)
    forward[5] = 1
    // a -> b -> a pointer cycle, both backward-looking is impossible: build a pointer that points at a later pointer.
    var chain = Array(reply[0..<12]) + [3, 0x61, 0x61, 0x61, 0xC0, 12 + 8, 0, 1, 0, 1]
    chain[5] = 1
    t.check("dns: self, forward and looping compression pointers are rejected",
            dnsReadName(selfLoop, 12) == nil && dnsReadName(forward, 12) == nil && parseDNS(selfLoop) == nil && parseDNS(forward) == nil
            && dnsReadName(chain, 12) == nil)
    var longLabel = Array(reply[0..<12]) + [64] + [UInt8](repeating: 0x61, count: 64) + [0, 0, 1, 0, 1]
    longLabel[5] = 1
    var reserved = Array(reply[0..<12]) + [0x80, 1, 2, 0, 0, 1, 0, 1]
    reserved[5] = 1
    var hugeName: [UInt8] = []
    for _ in 0..<10 { hugeName += [30] + [UInt8](repeating: 0x62, count: 30) }
    let big = Array(reply[0..<12]) + hugeName + [0, 0, 1, 0, 1]
    t.check("dns: 64-byte labels, reserved label types and 300-byte names are rejected",
            parseDNS(longLabel) == nil && parseDNS(reserved) == nil && dnsReadName(big, 12) == nil)
    // A pointer chain that is legal: each hop strictly backward.
    var ok = Array(reply[0..<12]) + [1, 0x61, 0] + [1, 0x62, 0xC0, 12] + [0xC0, 15]
    ok[5] = 0
    t.check("dns: strictly backward pointer chains decode", dnsReadName(ok, 19)?.name == Array("b.a".utf8) && dnsReadName(ok, 19)?.end == 21)
    // rdlength past the end, absurd counts.
    var rdlen = reply
    rdlen[reply.count - 5] = 0xFF
    var counts = reply
    counts[6] = 0xFF
    counts[7] = 0xFF
    t.check("dns: oversize rdlength and absurd counts are rejected", parseDNS(rdlen) == nil && parseDNS(counts) == nil)
    t.check("dns: names are normalized and validated", dnsNormalize("WWW.Example.COM.") == Array("www.example.com".utf8)
            && dnsNormalize("") == nil && dnsNormalize("a..b") == nil && dnsNormalize(".") == nil && dnsNormalize("a b") == nil
            && dnsNormalize(String(repeating: "a", count: 64)) == nil && dnsNormalize("a.b\u{0}") == nil && dnsNormalize("é.com") == nil)
    let q = dnsBuildQuery(id: 7, name: Array("a.bc".utf8))
    t.check("dns: query wire format", q == [0, 7, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0x61, 2, 0x62, 0x63, 0, 0, 1, 0, 1])
    var rng = NetRNG(seed: 4242)
    var fuzzOK = true
    for i in 0..<5000 {
        var f = reply
        for _ in 0..<(1 + rng.below(8)) { f[rng.below(f.count)] = UInt8(truncatingIfNeeded: rng.next()) }
        if i % 5 == 0 { f = Array(f[0..<rng.below(f.count + 1)]) }
        if i % 97 == 0 { f = (0..<rng.below(600)).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }
        _ = parseDNS(f)
        fuzzOK = true
    }
    t.check("dns: 5000 fuzzed replies did not trap", fuzzOK)
}

func netDNSResolverTests(_ t: inout SelfTest) {
    let rig = NetRig(seed: 51)
    rig.a.dns = NetRig.ipB
    let server = NetTestDNSServer(rig.b)
    server.table["www.example.test"] = [(5, 300, Array("host.example.test".utf8))]
    server.table["host.example.test"] = [(1, 2, [192, 0, 2, 33]), (1, 2, [192, 0, 2, 34])]
    server.table["plain.test"] = [(1, 600, [198, 51, 100, 7])]
    server.nxdomain = ["nope.test"]
    let resolver = DNSResolver(stack: rig.a)
    rig.a.resolver = resolver

    var q = resolver.start("WWW.Example.test")
    rig.run(until: { q.state != .pending }, limit: 100)
    t.check("dns: resolves a CNAME chain to its addresses", q.state == .done && q.addresses == [ipv4(192, 0, 2, 33), ipv4(192, 0, 2, 34)]
            && q.aliases == [Array("host.example.test".utf8)] && server.queries == 1)
    let sentBefore = resolver.queriesSent
    q = resolver.start("www.example.test")
    t.check("dns: a repeat is answered from the cache", q.state == .done && q.fromCache && resolver.queriesSent == sentBefore && resolver.cacheHits == 1)
    rig.run(250) // TTL was min(300, 2): 2 s
    q = resolver.start("www.example.test")
    rig.run(until: { q.state != .pending }, limit: 100)
    t.check("dns: the cache honours the TTL", q.state == .done && !q.fromCache && server.queries == 2)

    q = resolver.start("nope.test")
    rig.run(until: { q.state != .pending }, limit: 100)
    t.check("dns: NXDOMAIN fails with that reason", q.state == .failed && q.error == .nxdomain)
    q = resolver.start("unknown.test") // the server answers with no records
    rig.run(until: { q.state != .pending }, limit: 100)
    t.check("dns: an empty answer is 'no address'", q.state == .failed && q.error == .noAddress)
    q = resolver.start("bad name")
    t.check("dns: invalid names fail at once", q.state == .failed && q.error == .badName)

    // A lossy server: the first query is ignored; the retry works.
    server.ignore = 1
    let queriesBefore = server.queries
    q = resolver.start("plain.test")
    rig.run(until: { q.state != .pending }, limit: 600)
    t.check("dns: a lost query is retried after the timeout", q.state == .done && q.attempts == 2 && server.queries == queriesBefore + 2
            && q.addresses == [ipv4(198, 51, 100, 7)])

    // No server at all: three attempts, then timeout.
    server.ignore = 1000
    let before = resolver.queriesSent
    q = resolver.start("silent.test")
    rig.run(until: { q.state != .pending }, limit: 1000)
    t.check("dns: three attempts then a timeout", q.state == .failed && q.error == .timeout && resolver.queriesSent == before + 3)
    server.ignore = 0
    t.check("dns: a finished query frees its socket", rig.a.udpSockets.count == 0)

    // Replies from the wrong place or with the wrong id/question are ignored.
    q = resolver.start("spoof.test")
    let sock = q.socket!
    let name = Array("spoof.test".utf8)
    func inject(from src: IPv4Addr, port: UInt16, _ bytes: [UInt8]) {
        resolver.handle(q, UDPDatagram(src: src, srcPort: port, data: bytes))
    }
    let good = netTestDNSReply(id: q.id, qname: "spoof.test", answers: [("spoof.test", 1, 60, [6, 6, 6, 6])])
    inject(from: ipv4(10, 1, 0, 9), port: 53, good)
    inject(from: NetRig.ipB, port: 5353, good)
    inject(from: NetRig.ipB, port: 53, netTestDNSReply(id: q.id &+ 1, qname: "spoof.test", answers: [("spoof.test", 1, 60, [6, 6, 6, 6])]))
    inject(from: NetRig.ipB, port: 53, netTestDNSReply(id: q.id, qname: "other.test", answers: [("other.test", 1, 60, [6, 6, 6, 6])]))
    var query = good
    query[2] = 0x01 // QR clear: a query, not a response
    inject(from: NetRig.ipB, port: 53, query)
    inject(from: NetRig.ipB, port: 53, [1, 2, 3])
    t.check("dns: spoofed, mismatched and garbage replies leave the query waiting", q.state == .pending && resolver.repliesIgnored >= 6 && sock.port > 0)
    _ = name
    inject(from: NetRig.ipB, port: 53, good)
    t.check("dns: the genuine reply is then accepted", q.state == .done && q.addresses == [ipv4(6, 6, 6, 6)])

    // A CNAME to a name this reply doesn't answer starts a second query.
    let server2Table = server.table
    server.table["alias.test"] = [(5, 300, Array("target.test".utf8))]
    server.table["target.test"] = [(1, 60, [203, 0, 113, 5])]
    server.cnameOnly = ["alias.test"]
    q = resolver.start("alias.test")
    rig.run(until: { q.state != .pending }, limit: 400)
    t.check("dns: a dangling CNAME is chased with a new query", q.state == .done && q.addresses == [ipv4(203, 0, 113, 5)] && q.aliases == [Array("target.test".utf8)])
    _ = server2Table

    // A CNAME loop terminates.
    server.table["loop-a.test"] = [(5, 300, Array("loop-b.test".utf8))]
    server.table["loop-b.test"] = [(5, 300, Array("loop-a.test".utf8))]
    q = resolver.start("loop-a.test")
    rig.run(until: { q.state != .pending }, limit: 600)
    t.check("dns: a CNAME loop fails instead of spinning", q.state == .failed && (q.error == .tooManyCNAMEs || q.error == .noAddress))

    // No server configured.
    rig.a.dns = 0
    q = resolver.start("plain-uncached.test")
    t.check("dns: no configured server fails at once", q.state == .failed && q.error == .noServer)
    // An explicit server and port work without the configured one.
    let alt = rig.b.udpBind(5300)!
    alt.onReceive = {
        while let d = alt.receive() {
            if let m = parseDNS(d.data) {
                alt.send(to: d.src, port: d.srcPort, netTestDNSReply(id: m.id, qname: "alt.test", answers: [("alt.test", 1, 30, [9, 8, 7, 6])]))
            }
        }
    }
    q = resolver.start("alt.test", server: NetRig.ipB, port: 5300)
    rig.run(until: { q.state != .pending }, limit: 100)
    t.check("dns: an explicit server and port are used", q.state == .done && q.addresses == [ipv4(9, 8, 7, 6)])
}

/// Checks that only make sense with the machine's real NIC.
func netMachineTests(_ t: inout SelfTest) {
    guard let stack = netStack, let nic = stack.dev as? VirtioNet else {
        puts("  note no eth0: virtio-net checks skipped\n")
        return
    }
    t.check("virtio-net: queues set up, link up, MAC is unicast", nic.rx.size >= 8 && nic.tx.size >= 8 && nic.linkUp && nic.mac & 0x0100_0000_0000 == 0 && nic.mac != 0)
    t.check("virtio-net: sent the DHCP DISCOVER", nic.counters.txFrames >= 1 && stack.dhcp != nil)
    // A raw broadcast frame goes out (ARP who-has the gateway): either it
    // was transmitted or counted; the NIC must never wedge.
    let before = nic.counters.txFrames
    let p = Packet.make()
    p.appendZeros(46)
    stack.sendFrame(to: macBroadcast, type: 0x88B5, p)
    t.check("virtio-net: a raw broadcast frame is transmitted", nic.counters.txFrames == before + 1)
}
