// Part 7 (Phase 7A2): virtio-net over the legacy (virtio 0.9.5) PCI
// transport, the same register sequence as virtio_blk.swift.
//
// Queue 0 is rx, queue 1 is tx. Features: MAC and STATUS only, so there are
// no offloads and every frame is preceded by the 10-byte virtio_net_hdr
// (all zero on tx, ignored on rx). Rx has up to 256 preposted 2 KiB buffers
// from one contiguous frame run; a consumed buffer is copied into a Packet
// and immediately reposted. Tx has a ring of 2 KiB bounce buffers (a slot is
// reclaimed when the device reports it used). Both queues are polled from
// netd, with device interrupts suppressed (avail flags = 1). Physical memory
// is identity-mapped, so pointers are also DMA addresses.
//
// Phase 7F: MSI-X. When the function has an MSI-X capability and the x2APIC
// is on, table entry 0 is aimed at CPU 0's LAPIC with vector 0x50
// (`Vector.net`) and the rx queue is bound to it (rx interrupts on: avail
// flags 0). The tx queue is bound to the same vector but keeps its
// interrupts suppressed: tx slots are reclaimed on the next send, so a tx
// completion has nothing to wake. The handler (netInterrupt) only counts,
// sets a flag and unparks netd. With MSI-X on, the legacy header grows by
// two vector registers (config 0x14, queue 0x16) and the device config
// moves from 0x14 to 0x18. Polling from the main loop stays as the fallback
// (and is all there is without MSI-X).
//
// CPU 0 only, no locks.

enum VirtioNetFeature {
    static let mac: UInt32 = 1 << 5
    static let status: UInt32 = 1 << 16
}

/// Legacy virtio registers that exist only with MSI-X enabled.
enum VirtioMSIXReg {
    static let configVector: UInt16 = 0x14
    static let queueVector: UInt16 = 0x16
    /// The device config with MSI-X on.
    static let config: UInt16 = 0x18
    static let noVector: UInt16 = 0xFFFF
}

/// Legacy (transitional) virtio-net PCI ID; modern-only devices are 0x1041.
let virtioNetLegacyID: UInt16 = 0x1000
/// struct virtio_net_hdr without MRG_RXBUF: flags, gso_type, hdr_len,
/// gso_size, csum_start, csum_offset.
let virtioNetHeaderSize = 10

/// One legacy virtqueue: descriptors and avail ring, then the used ring.
struct VirtQueue {
    let size: Int
    let desc: UnsafeMutableRawPointer
    let avail: UnsafeMutableRawPointer
    let used: UnsafeMutableRawPointer
    let phys: UInt
    let frames: Int
    var availIdx: UInt16 = 0
    var usedIdx: UInt16 = 0

    var hasUsed: Bool { dma_load16(used + 2) != usedIdx }

    func setDescriptor(_ i: Int, _ addr: UInt, _ length: Int, _ flags: UInt16) {
        let d = desc + 16 * i
        d.storeBytes(of: UInt64(addr), toByteOffset: 0, as: UInt64.self)
        d.storeBytes(of: UInt32(length), toByteOffset: 8, as: UInt32.self)
        d.storeBytes(of: flags, toByteOffset: 12, as: UInt16.self)
        d.storeBytes(of: UInt16(0), toByteOffset: 14, as: UInt16.self)
    }

    /// Publish descriptor `head` (the chain's first descriptor) in the avail ring.
    mutating func publish(_ head: Int) {
        avail.storeBytes(of: UInt16(head), toByteOffset: 4 + 2 * (Int(availIdx) & (size - 1)), as: UInt16.self)
        availIdx &+= 1
    }

    /// Make everything published so far visible to the device.
    func commit() {
        dma_store16(avail + 2, availIdx)
        dma_fence()
    }

    /// Next used element (id, length written by the device), if any.
    mutating func popUsed() -> (id: Int, length: Int)? {
        guard hasUsed else { return nil }
        let slot = Int(usedIdx) & (size - 1)
        let id = Int(used.load(fromByteOffset: 4 + 8 * slot, as: UInt32.self))
        let len = Int(used.load(fromByteOffset: 8 + 8 * slot, as: UInt32.self))
        usedIdx &+= 1
        return (id, len)
    }

    /// Select queue `index`, allocate and register it. nil if unusable.
    static func setup(io: UInt16, index: UInt16) -> VirtQueue? {
        outw(io + VirtioReg.queueSelect, index)
        let n = Int(inw(io + VirtioReg.queueSize))
        guard n > 0, n & (n - 1) == 0, inl(io + VirtioReg.queuePFN) == 0 else { return nil }
        let layout = VirtioBlock.queueLayout(n)
        guard let phys = pmm.allocate(count: layout.frames) else { return nil }
        let base = pmm.identity(phys)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: layout.frames * frameSize)
        var q = VirtQueue(size: n, desc: base, avail: base + 16 * n, used: base + layout.usedOffset,
                          phys: phys, frames: layout.frames)
        q.availIdx = 0
        outl(io + VirtioReg.queuePFN, UInt32(phys >> 12))
        dma_store16(q.avail, 1) // polled: ask the device not to interrupt
        return q
    }
}

final class VirtioNet: NetDevice {
    static let bufferSize = 2048
    let pci: PCIDevice
    let io: UInt16
    var rx: VirtQueue
    var tx: VirtQueue
    let rxCount: Int
    let rxBufPhys: UInt
    let rxBufFrames: Int
    let txCount: Int
    let txBufPhys: UInt
    let txBufFrames: Int
    /// Free tx slots.
    var txFree: [Int] = []
    let hasStatus: Bool
    var polls: UInt64 = 0
    /// MSI-X vector in use (nil: polled only), and where device config is.
    var msixVector: UInt8? = nil
    var configBase: UInt16 = VirtioReg.config

    private init(pci: PCIDevice, io: UInt16, mac: MACAddr, hasStatus: Bool, rx: VirtQueue, tx: VirtQueue,
                 rxCount: Int, rxBufPhys: UInt, rxBufFrames: Int, txCount: Int, txBufPhys: UInt, txBufFrames: Int) {
        self.pci = pci
        self.io = io
        self.hasStatus = hasStatus
        self.rx = rx
        self.tx = tx
        self.rxCount = rxCount
        self.rxBufPhys = rxBufPhys
        self.rxBufFrames = rxBufFrames
        self.txCount = txCount
        self.txBufPhys = txBufPhys
        self.txBufFrames = txBufFrames
        super.init(name: "eth0", mac: mac, mtu: 1500)
        txFree.reserveCapacity(txCount)
        for i in 0..<txCount { txFree.append(i) }
    }

    /// Run the legacy init sequence on one PCI function. nil (with a message)
    /// if the device isn't usable.
    static func probe(_ dev: PCIDevice) -> VirtioNet? {
        guard let bar = dev.bars.first, bar.isIO, bar.address != 0, bar.address < 0x10000, bar.size >= 0x20 else {
            print("eth0: virtio-net at \(dev.location) has no I/O BAR 0 (modern-only device?)")
            return nil
        }
        let io = UInt16(bar.address)
        dev.enable(io: true, busMaster: true)
        func status(_ s: UInt8) { outb(io + VirtioReg.status, s) }
        func fail(_ why: String) -> VirtioNet? {
            status(VirtioStatus.failed)
            print("eth0: \(why)")
            return nil
        }
        status(0)
        status(VirtioStatus.acknowledge)
        status(VirtioStatus.acknowledge | VirtioStatus.driver)
        let features = inl(io + VirtioReg.deviceFeatures)
        guard features & VirtioNetFeature.mac != 0 else { return fail("device has no MAC feature") }
        let accepted = features & (VirtioNetFeature.mac | VirtioNetFeature.status)
        outl(io + VirtioReg.guestFeatures, accepted)

        // Phase 7F: MSI-X before the queues (the header layout changes).
        let msix = x2apicEnabled ? pciEnableMSIX(dev, vector: Vector.net, apicID: apicID()) : false // (probe: CPU 0)
        var configBase = VirtioReg.config
        if msix {
            configBase = VirtioMSIXReg.config
            outw(io + VirtioMSIXReg.configVector, VirtioMSIXReg.noVector)
        }
        guard let rxq = VirtQueue.setup(io: io, index: 0) else { return fail("rx queue unusable") }
        guard let txq = VirtQueue.setup(io: io, index: 1) else { return fail("tx queue unusable") }
        var vectorOK = msix
        if msix {
            for q in 0..<2 {
                outw(io + VirtioReg.queueSelect, UInt16(q))
                outw(io + VirtioMSIXReg.queueVector, 0)
                if inw(io + VirtioMSIXReg.queueVector) != 0 { vectorOK = false }
            }
            if vectorOK {
                dma_store16(rxq.avail, 0) // rx interrupts on
            } else {
                print("eth0: the device refused the MSI-X queue vector; polling")
            }
        }
        let rxCount = min(rxq.size, 256), txCount = min(txq.size, 128)
        let rxFrames = rxCount * bufferSize / frameSize, txFrames = txCount * bufferSize / frameSize
        guard let rxPhys = pmm.allocate(count: rxFrames) else { return fail("no memory for rx buffers") }
        guard let txPhys = pmm.allocate(count: txFrames) else {
            pmm.free(rxPhys, count: rxFrames)
            return fail("no memory for tx buffers")
        }
        pmm.identity(txPhys).initializeMemory(as: UInt8.self, repeating: 0, count: txFrames * frameSize)

        var mac: UInt64 = 0
        for i in 0..<6 { mac = mac << 8 | UInt64(inb(io + configBase + UInt16(i))) }

        var rxq2 = rxq
        for i in 0..<rxCount {
            rxq2.setDescriptor(i, rxPhys + UInt(i * bufferSize), bufferSize, VirtqDesc.write)
            rxq2.publish(i)
        }
        rxq2.commit()
        let nic = VirtioNet(pci: dev, io: io, mac: mac, hasStatus: accepted & VirtioNetFeature.status != 0,
                            rx: rxq2, tx: txq, rxCount: rxCount, rxBufPhys: rxPhys, rxBufFrames: rxFrames,
                            txCount: txCount, txBufPhys: txPhys, txBufFrames: txFrames)
        nic.configBase = configBase
        if vectorOK { nic.msixVector = Vector.net }
        status(VirtioStatus.acknowledge | VirtioStatus.driver | VirtioStatus.driverOK)
        outw(io + VirtioReg.queueNotify, 0) // rx buffers are available
        return nic
    }

    override var linkUp: Bool {
        guard hasStatus else { return true }
        return inw(io + configBase + 6) & 1 != 0
    }

    override var hasWork: Bool { rx.hasUsed }

    override func poll() {
        polls &+= 1
        var reposted = false
        var budget = 256
        while budget > 0, let (id, len) = rx.popUsed() {
            budget -= 1
            let frameLength = len - virtioNetHeaderSize
            if id < rxCount, frameLength > 0, len <= VirtioNet.bufferSize {
                let p = Packet.make()
                p.start = 0
                p.end = frameLength
                let src = pmm.identity(rxBufPhys + UInt(id * VirtioNet.bufferSize + virtioNetHeaderSize))
                p.buf.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: src, byteCount: frameLength) }
                deliver(p)
            } else {
                counters.rxDropped += 1
            }
            if id < rxCount {
                rx.publish(id)
                reposted = true
            }
        }
        if reposted {
            rx.commit()
            outw(io + VirtioReg.queueNotify, 0)
        }
    }

    private func reclaimTx() {
        while let (id, _) = tx.popUsed() {
            if id < txCount { txFree.append(id) }
        }
    }

    override func send(_ p: Packet) {
        defer { p.release() }
        reclaimTx()
        // Ethernet minimum is 60 bytes before the FCS.
        let frameLength = max(p.length, 60)
        guard p.length <= mtu + 14, let slot = txFree.popLast() else { counters.txDropped += 1; return }
        let base = pmm.identity(txBufPhys + UInt(slot * VirtioNet.bufferSize))
        base.initializeMemory(as: UInt8.self, repeating: 0, count: virtioNetHeaderSize)
        let body = base + virtioNetHeaderSize
        p.buf.withUnsafeBytes { body.copyMemory(from: $0.baseAddress! + p.start, byteCount: p.length) }
        if frameLength > p.length { (body + p.length).initializeMemory(as: UInt8.self, repeating: 0, count: frameLength - p.length) }
        tx.setDescriptor(slot, txBufPhys + UInt(slot * VirtioNet.bufferSize), virtioNetHeaderSize + frameLength, 0)
        tx.publish(slot)
        tx.commit()
        outw(io + VirtioReg.queueNotify, 1)
        countTx(p.length)
    }
}

// MARK: MSI-X (Phase 7F)

/// Find the MSI-X capability, map its table, aim entry 0 at `apicID` with
/// `vector` (fixed, edge), and enable MSI-X (legacy INTx off). False if the
/// function has no usable MSI-X.
func pciEnableMSIX(_ dev: PCIDevice, vector: UInt8, apicID: UInt32) -> Bool {
    guard apicID < 256, (dev.read32(0x04) >> 16) & 0x10 != 0 else { return false } // capability list
    var cap = UInt8(truncatingIfNeeded: dev.read32(0x34)) & 0xFC
    var hops = 0
    while cap >= 0x40 && hops < 48 {
        let header = dev.read32(cap)
        if header & 0xFF == 0x11 { break }
        cap = UInt8(truncatingIfNeeded: header >> 8) & 0xFC
        hops += 1
    }
    guard cap >= 0x40, hops < 48 else { return false }
    let header = dev.read32(cap)
    let tableSize = Int((header >> 16) & 0x7FF) + 1
    let tableReg = dev.read32(cap + 4)
    let bir = Int(tableReg & 7)
    guard bir < dev.bars.count, !dev.bars[bir].isIO, dev.bars[bir].address != 0 else { return false }
    let tablePhys = dev.bars[bir].address + UInt64(tableReg & ~7)
    guard let table = mapMMIO(UInt(tablePhys), tableSize * 16) else { return false }
    dev.enable(memory: true)
    // Masked (function mask) while the entries are written.
    dev.write32(cap, (header & 0xFFFF) | ((header >> 16) | 0xC000) << 16)
    for i in 0..<tableSize {
        let e = table + 16 * i
        e.storeBytes(of: UInt32(0xFEE0_0000) | apicID << 12, toByteOffset: 0, as: UInt32.self)
        e.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
        e.storeBytes(of: UInt32(vector), toByteOffset: 8, as: UInt32.self)
        e.storeBytes(of: UInt32(i == 0 ? 0 : 1), toByteOffset: 12, as: UInt32.self) // only entry 0 unmasked
    }
    dma_fence()
    // INTx off (command bit 10), then enable with the function unmasked.
    dev.write32(0x04, (dev.read32(0x04) & 0xFFFF) | 0x400)
    dev.write32(cap, (header & 0xFFFF) | (((header >> 16) & ~0x4000) | 0x8000) << 16)
    return (dev.read32(cap) >> 16) & 0xC000 == 0x8000
}

/// MSI-X interrupts taken (all CPUs; only CPU 0 is targeted).
var netInterrupts: UInt64 = 0
/// Set by the interrupt, cleared by netd when it polls.
var netIRQPending = false

/// Vector 0x50 (Vector.net), from interrupt_dispatch. No allocation: count,
/// set the flag, unpark netd, EOI.
func netInterrupt() {
    netInterrupts &+= 1
    entropyAddInterrupt(3)
    netIRQPending = true
    if let t = netdTask {
        schedLock.acquire()
        unparkLocked(t)
        schedLock.release()
    }
    if x2apicEnabled { apicEOI() }
}
