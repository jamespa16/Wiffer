// Part 7 (Phase 7C2): DHCP client (RFC 2131): DISCOVER, OFFER, REQUEST, ACK
// at boot, then renewal at T1 (unicast), rebinding at T2 (broadcast) and a
// fresh DISCOVER when the lease runs out. If no offer arrives within 5 s the
// static configuration (QEMU's user network: 10.0.2.15/24, gateway 10.0.2.2,
// DNS 10.0.2.3) is applied; DISCOVER keeps being retried, and a later ACK
// replaces it. Timers run on the stack's schedule(); a generation counter
// makes a closure from an earlier state a no-op.
//
// Every incoming option is read through a bounds-checked ByteReader.

struct DHCPMessage {
    var op: UInt8 = 0
    var xid: UInt32 = 0
    var chaddr: MACAddr = 0
    var ciaddr: IPv4Addr = 0
    var yiaddr: IPv4Addr = 0
    // Options (0 / nil when absent).
    var messageType: UInt8 = 0
    var serverID: IPv4Addr = 0
    var mask: IPv4Addr = 0
    var router: IPv4Addr = 0
    var dns: IPv4Addr = 0
    var leaseSeconds: UInt32 = 0
    var t1Seconds: UInt32 = 0
    var t2Seconds: UInt32 = 0
}

enum DHCPType {
    static let discover: UInt8 = 1
    static let offer: UInt8 = 2
    static let request: UInt8 = 3
    static let decline: UInt8 = 4
    static let ack: UInt8 = 5
    static let nak: UInt8 = 6
}

/// Parse a BOOTP/DHCP message. nil if it is truncated or not DHCP.
func parseDHCP(_ bytes: [UInt8]) -> DHCPMessage? {
    var r = ByteReader(bytes)
    guard let op = r.u8(), let htype = r.u8(), let hlen = r.u8(), r.skip(1), let xid = r.u32(),
          r.skip(4), let ciaddr = r.u32(), let yiaddr = r.u32(), r.skip(8),
          let chHi = r.u32(), let chLo = r.u16(), r.skip(10 + 64 + 128), let cookie = r.u32(),
          htype == 1, hlen == 6, cookie == 0x6382_5363, op == 1 || op == 2
    else { return nil }
    var m = DHCPMessage()
    m.op = op
    m.xid = xid
    m.chaddr = UInt64(chHi) << 16 | UInt64(chLo)
    m.ciaddr = ciaddr
    m.yiaddr = yiaddr
    while let code = r.u8() {
        if code == 0 { continue }
        if code == 255 { break }
        guard let len = r.u8(), var o = r.sub(Int(len)) else { return nil }
        switch code {
        case 53: if len == 1 { m.messageType = o.u8() ?? 0 }
        case 54: if len == 4 { m.serverID = o.u32() ?? 0 }
        case 1: if len == 4 { m.mask = o.u32() ?? 0 }
        case 3: if len >= 4 { m.router = o.u32() ?? 0 }
        case 6: if len >= 4 { m.dns = o.u32() ?? 0 }
        case 51: if len == 4 { m.leaseSeconds = o.u32() ?? 0 }
        case 58: if len == 4 { m.t1Seconds = o.u32() ?? 0 }
        case 59: if len == 4 { m.t2Seconds = o.u32() ?? 0 }
        default: break
        }
    }
    return m.messageType == 0 ? nil : m
}

/// Build a DHCP message (client or server side; the tests use both).
func buildDHCP(op: UInt8, xid: UInt32, chaddr: MACAddr, type: UInt8, ciaddr: IPv4Addr = 0, yiaddr: IPv4Addr = 0,
               broadcast: Bool = false, requested: IPv4Addr = 0, serverID: IPv4Addr = 0, mask: IPv4Addr = 0,
               router: IPv4Addr = 0, dns: IPv4Addr = 0, lease: UInt32 = 0, t1: UInt32 = 0, t2: UInt32 = 0,
               hostname: String = "") -> [UInt8] {
    var b: [UInt8] = [op, 1, 6, 0]
    func u32(_ v: UInt32) { for i in 0..<4 { b.append(UInt8(truncatingIfNeeded: v >> UInt32(8 * (3 - i)))) } }
    u32(xid)
    b.append(contentsOf: [0, 0, broadcast ? 0x80 : 0, 0]) // secs, flags
    u32(ciaddr)
    u32(yiaddr)
    u32(0)
    u32(0)
    for i in 0..<6 { b.append(UInt8(truncatingIfNeeded: chaddr >> UInt64(8 * (5 - i)))) }
    b.append(contentsOf: [UInt8](repeating: 0, count: 10 + 64 + 128))
    u32(0x6382_5363)
    func option(_ code: UInt8, _ value: [UInt8]) { b.append(code); b.append(UInt8(value.count)); b.append(contentsOf: value) }
    func word(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * (3 - $0))) } }
    option(53, [type])
    if op == 1 {
        option(61, [1] + (0..<6).map { UInt8(truncatingIfNeeded: chaddr >> UInt64(8 * (5 - $0))) })
        if requested != 0 { option(50, word(requested)) }
        if !hostname.isEmpty { option(12, Array(hostname.utf8)) }
        if type != DHCPType.decline { option(55, [1, 3, 6, 51, 58, 59]) }
    }
    if serverID != 0 { option(54, word(serverID)) }
    if mask != 0 { option(1, word(mask)) }
    if router != 0 { option(3, word(router)) }
    if dns != 0 { option(6, word(dns)) }
    if lease != 0 { option(51, word(lease)) }
    if t1 != 0 { option(58, word(t1)) }
    if t2 != 0 { option(59, word(t2)) }
    b.append(255)
    while b.count < 300 { b.append(0) } // BOOTP minimum
    return b
}

enum DHCPState {
    case idle, selecting, requesting, bound, renewing, rebinding
}

final class DHCPClient {
    let stack: NetStack
    let socket: UDPSocket
    var state = DHCPState.idle
    var xid: UInt32 = 0
    var offered: IPv4Addr = 0
    var server: IPv4Addr = 0
    /// Lease length and the tick it was acquired, for `ifconfig`.
    var leaseSeconds: UInt32 = 0
    var leaseStart: UInt64 = 0
    /// True after the 5 s fallback applied the static configuration.
    var usingFallback = false
    /// Bumped by every state change that retires pending retry/lease timers.
    var generation = 0
    /// Bumped by start(): retires the previous cycle's fallback timer.
    var epoch = 0
    var attempt = 0
    var sent: UInt64 = 0
    var received: UInt64 = 0
    var hostname = "wiffer"

    static let fallbackIP = ipv4(10, 0, 2, 15)
    static let fallbackMask = ipv4(255, 255, 255, 0)
    static let fallbackGateway = ipv4(10, 0, 2, 2)
    static let fallbackDNS = ipv4(10, 0, 2, 3)
    static let fallbackTicks: UInt64 = 500
    static let ticksPerSecond: UInt64 = 100

    init?(stack: NetStack) {
        guard let s = stack.udpBind(68) else { return nil }
        self.stack = stack
        socket = s
        s.onReceive = { [self] in drain() }
    }

    /// Timers of the current state, cancelled on every transition so none
    /// lingers (a fired-later no-op still costs a heap object).
    private var timerIDs: [Int] = []

    private func arm(after ticks: UInt64, _ fn: @escaping () -> Void) {
        if timerIDs.count > 16 { // forget timers that already fired
            let liveIDs = Set(stack.timers.map { $0.id })
            timerIDs.removeAll(where: { !liveIDs.contains($0) })
        }
        timerIDs.append(stack.schedule(after: ticks, fn))
    }

    /// The 5 s fallback timer (0 = none); it survives the OFFER and goes at start() and bind().
    private var fallbackTimer = 0

    private func cancelTimers() {
        for id in timerIDs { stack.cancel(id) }
        timerIDs.removeAll()
    }

    private func cancelFallback() {
        if fallbackTimer != 0 { stack.cancel(fallbackTimer) }
        fallbackTimer = 0
    }

    /// Begin (or restart) discovery.
    func start() {
        cancelTimers()
        cancelFallback()
        generation += 1
        epoch += 1
        stack.configure(ip: 0, mask: 0, gateway: 0, dns: 0)
        xid = UInt32(truncatingIfNeeded: netRandom())
        offered = 0
        server = 0
        attempt = 0
        state = .selecting
        usingFallback = false
        sendDiscover()
        let ep = epoch
        fallbackTimer = stack.schedule(after: DHCPClient.fallbackTicks) { [self] in
            fallbackTimer = 0
            guard ep == epoch, state == .selecting || state == .requesting, !usingFallback else { return }
            usingFallback = true
            stack.configure(ip: DHCPClient.fallbackIP, mask: DHCPClient.fallbackMask,
                            gateway: DHCPClient.fallbackGateway, dns: DHCPClient.fallbackDNS)
        }
    }

    /// Retransmit interval: 2, 4, 8 s, then every 8 s.
    private func retryDelay() -> UInt64 { UInt64(200 << min(attempt, 2)) }

    private func armRetry() {
        let gen = generation
        arm(after: retryDelay()) { [self] in
            guard gen == generation else { return }
            attempt += 1
            switch state {
            case .selecting: sendDiscover()
            case .requesting: sendRequest()
            default: return
            }
        }
    }

    private func sendDiscover() {
        sent += 1
        let m = buildDHCP(op: 1, xid: xid, chaddr: stack.dev.mac, type: DHCPType.discover, broadcast: true, hostname: hostname)
        socket.send(to: 0xFFFF_FFFF, port: 67, m, src: 0)
        armRetry()
    }

    private func sendRequest() {
        sent += 1
        let m = buildDHCP(op: 1, xid: xid, chaddr: stack.dev.mac, type: DHCPType.request, broadcast: true,
                          requested: offered, serverID: server, hostname: hostname)
        socket.send(to: 0xFFFF_FFFF, port: 67, m, src: 0)
        armRetry()
    }

    /// Renew (unicast to the server) or rebind (broadcast) with the current address.
    private func sendRenew(unicast: Bool) {
        sent += 1
        let m = buildDHCP(op: 1, xid: xid, chaddr: stack.dev.mac, type: DHCPType.request, ciaddr: stack.ip,
                          hostname: hostname)
        socket.send(to: unicast ? server : 0xFFFF_FFFF, port: 67, m)
    }

    private func drain() {
        while let d = socket.receive() {
            guard d.srcPort == 67, let m = parseDHCP(d.data) else { continue }
            handle(m)
        }
    }

    func handle(_ m: DHCPMessage) {
        guard m.op == 2, m.xid == xid, m.chaddr == stack.dev.mac else { return }
        received += 1
        switch (state, m.messageType) {
        case (.selecting, DHCPType.offer):
            guard m.yiaddr != 0, m.serverID != 0 else { return }
            offered = m.yiaddr
            server = m.serverID
            state = .requesting
            cancelTimers()
            generation += 1
            attempt = 0
            sendRequest()
        case (.requesting, DHCPType.ack), (.renewing, DHCPType.ack), (.rebinding, DHCPType.ack):
            guard m.yiaddr != 0 else { return }
            bind(m)
        case (.requesting, DHCPType.nak), (.renewing, DHCPType.nak), (.rebinding, DHCPType.nak):
            start()
        default:
            break
        }
    }

    private func bind(_ m: DHCPMessage) {
        cancelTimers()
        cancelFallback()
        generation += 1
        let gen = generation
        state = .bound
        usingFallback = false
        // Clamp: at least a minute, at most a year (0xFFFFFFFF is "infinite").
        let lease = min(max(m.leaseSeconds == 0 ? 3600 : m.leaseSeconds, 60), 365 * 86400)
        leaseSeconds = lease
        leaseStart = stack.now
        if m.serverID != 0 { server = m.serverID }
        stack.configure(ip: m.yiaddr, mask: m.mask != 0 ? m.mask : DHCPClient.fallbackMask,
                        gateway: m.router, dns: m.dns)
        var t1 = m.t1Seconds == 0 ? lease / 2 : m.t1Seconds
        var t2 = m.t2Seconds == 0 ? lease / 8 * 7 : m.t2Seconds
        if t2 >= lease { t2 = lease / 8 * 7 }
        if t1 >= t2 { t1 = t2 / 2 }
        let tps = DHCPClient.ticksPerSecond
        arm(after: UInt64(t1) * tps) { [self] in
            guard gen == generation else { return }
            state = .renewing
            renewTick(gen: gen, mode: .renewing)
        }
        arm(after: UInt64(t2) * tps) { [self] in
            guard gen == generation else { return }
            state = .rebinding
            renewTick(gen: gen, mode: .rebinding)
        }
        arm(after: UInt64(lease) * tps) { [self] in
            guard gen == generation else { return }
            start() // the lease ran out
        }
    }

    /// While renewing (unicast to the server) or rebinding (broadcast), ask
    /// again every 10 s until the next state takes over.
    private func renewTick(gen: Int, mode: DHCPState) {
        guard gen == generation, state == mode else { return }
        sendRenew(unicast: mode == .renewing)
        arm(after: 1000) { [self] in renewTick(gen: gen, mode: mode) }
    }

    /// Seconds of lease left (0 if none).
    var leaseRemaining: UInt32 {
        guard state == .bound || state == .renewing || state == .rebinding else { return 0 }
        let used = (stack.now &- leaseStart) / DHCPClient.ticksPerSecond
        return used >= UInt64(leaseSeconds) ? 0 : UInt32(UInt64(leaseSeconds) - used)
    }

    var stateName: String {
        switch state {
        case .idle: return "idle"
        case .selecting: return "discovering"
        case .requesting: return "requesting"
        case .bound: return "bound"
        case .renewing: return "renewing"
        case .rebinding: return "rebinding"
        }
    }
}
