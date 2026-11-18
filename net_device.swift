// Part 7 (Phase 7A1): network devices. Like BlockDevice, a class hierarchy
// (not a protocol): the stack stores "some device". Frames are whole Ethernet
// frames (no FCS). Subclasses: VirtioNet (virtio_net.swift), Loopback, and
// LinkPair's two ends, which join two stacks in memory with seeded loss,
// reordering, duplication and delay so the whole stack, TCP included, can be
// tested off-screen.
//
// Ownership: `send` takes the packet (the device releases it); the receive
// callback gets a packet it must treat as borrowed (NetStack.receive releases
// it). Everything runs on CPU 0 inside netd: no locking.

struct NetCounters {
    var rxFrames: UInt64 = 0
    var txFrames: UInt64 = 0
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0
    /// Frames lost before the stack saw them (no buffer, bad length, full ring).
    var rxDropped: UInt64 = 0
    /// Frames not sent (no free transmit slot, too long).
    var txDropped: UInt64 = 0
}

class NetDevice {
    let name: String
    var mac: MACAddr
    /// Largest IP packet (the Ethernet payload).
    let mtu: Int
    var counters = NetCounters()
    /// Set by the stack that owns the device.
    var onReceive: ((Packet) -> Void)?

    init(name: String, mac: MACAddr, mtu: Int = 1500) {
        self.name = name
        self.mac = mac
        self.mtu = mtu
    }

    /// Transmit one Ethernet frame (taking ownership of `p`).
    func send(_ p: Packet) { counters.txDropped += 1; p.release() }

    /// Move received frames to `onReceive` (never blocks).
    func poll() {}

    /// Cheap check for the main loop: is there something for `poll` to do?
    var hasWork: Bool { false }

    /// Link is up (virtio STATUS; always true for the in-memory devices).
    var linkUp: Bool { true }

    /// For subclasses: account for and hand a received frame to the stack.
    final func deliver(_ p: Packet) {
        counters.rxFrames += 1
        counters.rxBytes += UInt64(p.length)
        if let handler = onReceive { handler(p) } else { counters.rxDropped += 1; p.release() }
    }

    final func countTx(_ bytes: Int) {
        counters.txFrames += 1
        counters.txBytes += UInt64(bytes)
    }
}

/// Frames sent come straight back on the next poll.
final class Loopback: NetDevice {
    var queue: [[UInt8]] = []
    static let maxQueue = 64

    init() { super.init(name: "lo", mac: 0, mtu: 1500) }

    override func send(_ p: Packet) {
        defer { p.release() }
        guard queue.count < Loopback.maxQueue, let frame = p.bytes() else { counters.txDropped += 1; return }
        countTx(frame.count)
        queue.append(frame)
    }

    override func poll() {
        let frames = queue
        queue.removeAll(keepingCapacity: true)
        for f in frames {
            if let p = Packet.received(f) { deliver(p) } else { counters.rxDropped += 1 }
        }
    }

    override var hasWork: Bool { !queue.isEmpty }
}

// MARK: LinkPair

/// Two devices joined by a simulated wire, deterministic for a given seed and
/// call order. Time is `now` (ticks), advanced by the test; a frame sent at
/// tick t is delivered by the peer's `poll()` once `now >= t + delay`.
///
///  - `lossPct`: percent of frames silently dropped.
///  - `reorderPct`: percent held back 1-3 ticks extra, so later frames pass them.
///  - `dupPct`: percent delivered twice.
///  - `delay`: base one-way delay in ticks.
final class LinkPair {
    let a: LinkEnd
    let b: LinkEnd
    var now: UInt64 = 0
    var rng: NetRNG
    var lossPct = 0
    var reorderPct = 0
    var dupPct = 0
    var delay = 0
    /// Most frames in flight per direction (a bounded wire).
    var maxInFlight = 512
    var sent: UInt64 = 0
    var lost: UInt64 = 0
    var duplicated: UInt64 = 0
    var reordered: UInt64 = 0
    var overflowed: UInt64 = 0
    var seq: UInt64 = 0

    init(seed: UInt64, macA: MACAddr = 0x0200_0000_000A, macB: MACAddr = 0x0200_0000_000B, mtu: Int = 1500) {
        rng = NetRNG(seed: seed)
        a = LinkEnd(name: "link0", mac: macA, mtu: mtu)
        b = LinkEnd(name: "link1", mac: macB, mtu: mtu)
        a.peer = b
        b.peer = a
        a.pair = self
        b.pair = self
    }

    func percent(_ pct: Int) -> Bool { pct > 0 && rng.below(100) < pct }

    fileprivate func transmit(_ frame: [UInt8], to peer: LinkEnd) {
        sent += 1
        if percent(lossPct) { lost += 1; return }
        var extra = 0
        if percent(reorderPct) { extra = 1 + rng.below(3); reordered += 1 }
        enqueue(frame, to: peer, at: now + UInt64(delay + extra))
        if percent(dupPct) {
            duplicated += 1
            enqueue(frame, to: peer, at: now + UInt64(delay + extra + rng.below(2)))
        }
    }

    private func enqueue(_ frame: [UInt8], to peer: LinkEnd, at: UInt64) {
        guard peer.inbox.count < maxInFlight else { overflowed += 1; return }
        seq += 1
        peer.inbox.append(LinkEnd.Item(at: at, seq: seq, data: frame))
    }
}

final class LinkEnd: NetDevice {
    struct Item {
        var at: UInt64
        var seq: UInt64
        var data: [UInt8]
    }
    var pair: LinkPair!
    var peer: LinkEnd!
    /// Frames sent by the peer, not yet delivered.
    var inbox: [Item] = []

    override func send(_ p: Packet) {
        defer { p.release() }
        guard p.length <= mtu + 14, let frame = p.bytes() else { counters.txDropped += 1; return }
        countTx(frame.count)
        pair.transmit(frame, to: peer)
    }

    override func poll() {
        guard !inbox.isEmpty else { return }
        let now = pair.now
        var due: [Item] = []
        var keep: [Item] = []
        for item in inbox { if item.at <= now { due.append(item) } else { keep.append(item) } }
        inbox = keep
        // Insertion sort by (at, seq): small lists, and no closures needed.
        var i = 1
        while i < due.count {
            let x = due[i]
            var j = i - 1
            while j >= 0 && (due[j].at > x.at || (due[j].at == x.at && due[j].seq > x.seq)) {
                due[j + 1] = due[j]
                j -= 1
            }
            due[j + 1] = x
            i += 1
        }
        for item in due {
            if let p = Packet.received(item.data) { deliver(p) } else { counters.rxDropped += 1 }
        }
    }

    override var hasWork: Bool {
        let now = pair.now
        for item in inbox where item.at <= now { return true }
        return false
    }
}
