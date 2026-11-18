// Part 7: bringing the network up on the machine, the `netd` task, and the
// shell commands (ifconfig, ping, host, arp).
//
// netd is a CPU-0 task that owns the one NetStack (eth0). It sleeps in
// waitEvent(); the main loop's pollEvents calls netPollHook, which posts it a
// message when the NIC has frames, a stack timer is due, or local packets
// wait. (7F replaces the polling with an MSI-X interrupt that posts the same
// message.) Shell commands run in their own tasks on CPU 0, so they may call
// into the stack directly (never at the same instant as netd: tasks are
// cooperative) and wait with `netBlock`, which sleeps the task until netd has
// run again or a deadline passes.

var netStack: NetStack?
var netdTask: Task?
/// A wake message to netd is already queued.
var netdKicked = false
/// The last netBlock ended because the user pressed Ctrl-C.
var netInterrupted = false
/// Tasks blocked in netBlock, woken after every netd run.
var netWaiters: [Task] = []

func netInit() {
    guard let dev = pciFind(vendor: virtioVendor, device: virtioNetLegacyID).first else {
        for d in pciFind(vendor: virtioVendor, device: 0x1041) {
            print("virtio-net at \(d.location) is modern-only (needs disable-legacy=off): skipped")
        }
        print("net: no virtio-net device")
        return
    }
    guard let nic = VirtioNet.probe(dev) else { return }
    print("eth0: virtio-net at \(dev.location), mac \(macString(nic.mac)), link \(nic.linkUp ? "up" : "down")")
    let stack = NetStack(device: nic)
    stack.now = ticks
    stack.resolver = DNSResolver(stack: stack)
    netStack = stack
    if let d = DHCPClient(stack: stack) {
        stack.dhcp = d
        d.start()
    }
    netdTask = spawn("netd") {
        while true {
            _ = waitEvent()
            netdKicked = false
            netStack?.poll(now: ticks)
            for t in netWaiters { t.post(.message(1)) }
        }
    }
    if netdTask == nil { print("net: no memory for netd") }
}

/// Wait (at most 6 s) for DHCP to finish or fall back, so the selftests
/// don't measure heap or timers while the lease is still being set up.
func netSettle() {
    guard let dhcp = netStack?.dhcp else { return }
    netBlock(timeout: 600) { dhcp.state != .selecting && dhcp.state != .requesting && dhcp.state != .idle || dhcp.usingFallback }
    netBlock(timeout: 20) { false } // let the last frames drain
}

/// Called from pollEvents (CPU 0, main loop): wake netd if it has work.
func netPollHook() {
    guard !netdKicked, let s = netStack, let t = netdTask, s.needsPoll(ticks) else { return }
    netdKicked = true
    t.post(.message(0))
}

/// Block the calling task until `cond()` holds (true) or `timeout` ticks pass
/// (false). Wakes whenever netd has run. Ctrl-C gives up (false). Callable
/// only from a task other than the main loop; from there it just tests `cond`.
@discardableResult
func netBlock(timeout: UInt64, _ cond: () -> Bool) -> Bool {
    netInterrupted = false
    guard let me = scheduler.current, !me.isMain, let stack = netStack else { return cond() }
    let deadline = ticks &+ timeout
    netWaiters.append(me)
    defer { netWaiters.removeAll(where: { $0 === me }) }
    while !cond() {
        let t = ticks
        guard t < deadline else { return false }
        let timer = stack.schedule(after: deadline - t) { me.post(.message(2)) }
        let event = waitEvent()
        stack.cancel(timer)
        if case .key(let key) = event, key.isCtrl("c") { netInterrupted = true; return false }
    }
    return true
}

// MARK: ifconfig, arp

func ifconfigLines() -> [String] {
    guard let s = netStack else { return ["no network interface (no virtio-net device)"] }
    let d = s.dev
    var lines = ["\(d.name): link \(d.linkUp ? "up" : "down"), mtu \(d.mtu)", "  ether \(macString(d.mac))"]
    if s.ip == 0 {
        lines.append("  inet (not configured)")
    } else {
        lines.append("  inet \(ipString(s.ip)) netmask \(ipString(s.mask)) gateway \(ipString(s.gateway)) dns \(ipString(s.dns))")
    }
    if let dhcp = s.dhcp {
        switch dhcp.state {
        case .bound, .renewing, .rebinding:
            lines.append("  dhcp: lease from \(ipString(dhcp.server)), \(dhcp.leaseRemaining) of \(dhcp.leaseSeconds) s left (\(dhcp.stateName))")
        default:
            lines.append(dhcp.usingFallback ? "  dhcp: no offer, static fallback (\(dhcp.stateName))" : "  dhcp: \(dhcp.stateName)")
        }
    }
    let c = d.counters
    lines.append("  rx \(c.rxFrames) frames \(c.rxBytes) bytes, tx \(c.txFrames) frames \(c.txBytes) bytes")
    lines.append("  dropped rx \(c.rxDropped) tx \(c.txDropped); ip bad \(s.stats.ipBadHeader + s.stats.ipBadChecksum)")
    return lines
}

func arpLines() -> [String] {
    guard let s = netStack else { return ["no network interface"] }
    if s.arpTable.isEmpty { return ["arp cache empty"] }
    return s.arpTable.map { e in
        e.resolved ? "\(ipString(e.ip)) at \(macString(e.mac)) (\(e.expires > s.now ? (e.expires - s.now) / 100 : 0) s left)"
                   : "\(ipString(e.ip)) incomplete (\(e.queue.count) queued)"
    }
}

// MARK: ping, host

/// Resolve `name` (an address or a host name) for a command, blocking.
func netResolve(_ name: Substring, server: IPv4Addr? = nil, port: UInt16 = 53, say: (String) -> Void) -> DNSQuery? {
    guard let stack = netStack, let resolver = stack.resolver else { say("no network interface"); return nil }
    let q = resolver.start(String(name), server: server, port: port)
    let wait = UInt64(resolver.maxAttempts) * resolver.timeoutTicks + 100
    netBlock(timeout: wait) { q.state != .pending }
    return q
}

func pingCommand(_ args: [Substring], say: (String) -> Void) {
    var count = 4
    var target: Substring? = nil
    var i = 0
    while i < args.count {
        if args[i] == "-c" {
            guard i + 1 < args.count, let n = parseInt(args[i + 1]), n >= 1, n <= 1000 else {
                say("usage: ping [-c count] <host>")
                return
            }
            count = n
            i += 2
        } else {
            guard target == nil else { say("usage: ping [-c count] <host>"); return }
            target = args[i]
            i += 1
        }
    }
    guard let target else { say("usage: ping [-c count] <host>"); return }
    guard let stack = netStack else { say("ping: no network interface"); return }
    var address: IPv4Addr
    if let a = parseIPv4(target) {
        address = a
    } else {
        guard let q = netResolve(target, say: say) else { return }
        guard q.state == .done, let first = q.addresses.first else {
            say("ping: \(target): \(q.error?.message ?? "no answer")")
            return
        }
        address = first
    }
    let id = UInt16(truncatingIfNeeded: netRandom())
    var replySeq = -1
    var replyTTL: UInt8 = 0
    var replySize = 0
    var replyFrom: IPv4Addr = 0
    stack.onEchoReply = { from, rid, seq, ttl, size in
        guard rid == id else { return }
        replySeq = Int(seq)
        replyTTL = ttl
        replySize = size
        replyFrom = from
    }
    defer { stack.onEchoReply = nil }
    say("PING \(ipString(address)): 32 data bytes")
    var received = 0
    for n in 1...count {
        let sentAt = ticks
        guard stack.sendEcho(to: address, id: id, seq: UInt16(n)) else {
            say("ping: cannot send (no route)")
            break
        }
        netBlock(timeout: 100) { replySeq == n }
        if netInterrupted { break }
        if replySeq == n {
            received += 1
            let ms = (ticks - sentAt) * 10
            say("\(replySize + 8) bytes from \(ipString(replyFrom)): icmp_seq=\(n) ttl=\(replyTTL) time=" + (ms == 0 ? "<10" : "\(ms)") + " ms")
        } else {
            say("Request timeout for icmp_seq \(n)")
        }
        // One probe per second.
        if n < count && ticks < sentAt + 100 {
            netBlock(timeout: sentAt + 100 - ticks) { false }
            if netInterrupted { break }
        }
    }
    say("\(count) packets transmitted, \(received) received, \((count - received) * 100 / count)% packet loss")
}

func hostCommand(_ args: [Substring], say: (String) -> Void) {
    guard args.count == 1 || args.count == 2 else { say("usage: host <name> [server[:port]]"); return }
    var server: IPv4Addr? = nil
    var port: UInt16 = 53
    if args.count == 2 {
        let parts = args[1].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let a = parseIPv4(parts[0]) else { say("host: bad server '\(args[1])'"); return }
        server = a
        if parts.count == 2 {
            guard let p = parseInt(parts[1]), p > 0, p < 65536 else { say("host: bad port in '\(args[1])'"); return }
            port = UInt16(p)
        }
    }
    let name = args[0]
    if let a = parseIPv4(name) { say("\(name) has address \(ipString(a))"); return }
    guard let q = netResolve(name, server: server, port: port, say: say) else { return }
    guard q.state == .done else {
        say("Host \(name) not found: \(q.error?.message ?? "no answer")")
        return
    }
    var owner = String(name)
    for alias in q.aliases {
        let target = String(decoding: alias, as: UTF8.self)
        say("\(owner) is an alias for \(target).")
        owner = target
    }
    for a in q.addresses { say("\(owner) has address \(ipString(a))") }
    if q.fromCache { say("(cached)") }
}

extension Shell {
    static func netCommands() -> [Command<T>] {
        [
            Command(name: "ifconfig", args: "", help: "network interface: MAC, address, DHCP lease, counters") { sh, _ in
                for l in ifconfigLines() { sh.say(l) }
            },
            Command(name: "arp", args: "", help: "show the ARP cache") { sh, _ in
                for l in arpLines() { sh.say(l) }
            },
            Command(name: "ping", args: "<host>", help: "ICMP echo; 'ping -c n <host>' sets the count (Ctrl-C stops)") { sh, args in
                pingCommand(args) { sh.say($0) }
            },
            Command(name: "host", args: "<name>", help: "DNS lookup; 'host <name> <ip[:port]>' picks the server") { sh, args in
                hostCommand(args) { sh.say($0) }
            },
        ]
    }
}
