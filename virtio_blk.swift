// Part 5 (Phase V2): virtio-blk over the legacy (virtio 0.9.5) PCI transport.
//
// Everything goes through the I/O-port BAR 0 (no MMIO). One virtqueue,
// polled: each request is a descriptor chain (header, data, status byte),
// published in the avail ring, kicked through the notify register; the
// driver then spins until the used ring's index moves, or about 2 s pass.
// The ring, the request header/status and a bounce buffer are contiguous
// frame runs from pmm, allocated once at probe time. Physical memory is
// identity-mapped at PML4[0] (pmm.swift), so their pointers are also their
// device (DMA) addresses. Swift arrays are never handed to the device.
//
// CPU 0 only (ROADMAP Part 4 affinity), one request in flight: no locks.

enum VirtioReg {
    // Legacy header, offsets into BAR 0 (no MSI-X, so device config at 0x14).
    static let deviceFeatures: UInt16 = 0x00
    static let guestFeatures: UInt16 = 0x04
    static let queuePFN: UInt16 = 0x08
    static let queueSize: UInt16 = 0x0C
    static let queueSelect: UInt16 = 0x0E
    static let queueNotify: UInt16 = 0x10
    static let status: UInt16 = 0x12
    static let isr: UInt16 = 0x13
    static let config: UInt16 = 0x14 // virtio-blk: capacity (u64, sectors) first
}

enum VirtioStatus {
    static let acknowledge: UInt8 = 1
    static let driver: UInt8 = 2
    static let driverOK: UInt8 = 4
    static let failed: UInt8 = 0x80
}

enum VirtioBlkFeature {
    static let readOnly: UInt32 = 1 << 5
    static let flush: UInt32 = 1 << 9
}

enum VirtioBlkRequest {
    static let read: UInt32 = 0  // VIRTIO_BLK_T_IN
    static let write: UInt32 = 1 // VIRTIO_BLK_T_OUT
    static let flush: UInt32 = 4 // VIRTIO_BLK_T_FLUSH
}

enum VirtqDesc {
    static let next: UInt16 = 1
    static let write: UInt16 = 2 // device writes this buffer
}

/// Legacy (transitional) virtio-blk PCI ID; modern-only devices are 0x1042.
let virtioVendor: UInt16 = 0x1AF4
let virtioBlkLegacyID: UInt16 = 0x1001

final class VirtioBlock: BlockDevice {
    let pci: PCIDevice
    /// BAR 0 I/O port base.
    let io: UInt16
    let queueSize: Int
    /// The virtqueue: descriptors and the avail ring, then the used ring at
    /// the next 4 KiB boundary (the legacy layout).
    let queuePhys: UInt
    let queueFrames: Int
    let desc: UnsafeMutableRawPointer
    let avail: UnsafeMutableRawPointer
    let used: UnsafeMutableRawPointer
    /// One frame: the 16-byte request header at 0, the status byte at 16.
    let requestPhys: UInt
    /// Data bounce buffer: every transfer is split into chunks this size.
    let bouncePhys: UInt
    static let bounceFrames = 16 // 64 KiB = 128 sectors
    static var bounceSectors: Int { bounceFrames * frameSize / sectorSize }
    let canFlush: Bool
    /// Next avail ring index to publish; last used index seen.
    var availIdx: UInt16 = 0
    var usedIdx: UInt16 = 0
    /// Set when a request timed out: the device may still own the buffers,
    /// so every later request fails with .io.
    var broken = false
    var requests: UInt64 = 0

    private init(name: String, pci: PCIDevice, io: UInt16, sectors: UInt64, readOnly: Bool, canFlush: Bool,
                 queueSize: Int, queuePhys: UInt, queueFrames: Int, usedOffset: Int,
                 requestPhys: UInt, bouncePhys: UInt) {
        self.pci = pci
        self.io = io
        self.canFlush = canFlush
        self.queueSize = queueSize
        self.queuePhys = queuePhys
        self.queueFrames = queueFrames
        desc = pmm.identity(queuePhys)
        avail = desc + 16 * queueSize
        used = desc + usedOffset
        self.requestPhys = requestPhys
        self.bouncePhys = bouncePhys
        super.init(name: name, sectorCount: sectors, readOnly: readOnly)
    }

    /// Bytes for the descriptor table + avail ring, rounded up to a frame,
    /// then the used ring (legacy virtio 2.4.2, with 4096 alignment).
    static func queueLayout(_ n: Int) -> (usedOffset: Int, frames: Int) {
        func align(_ x: Int) -> Int { (x + frameSize - 1) & ~(frameSize - 1) }
        let usedOffset = align(16 * n + 6 + 2 * n)
        return (usedOffset, (usedOffset + align(6 + 8 * n)) / frameSize)
    }

    /// Run the legacy init sequence on one PCI function. nil (with a message)
    /// if the device isn't usable; the device is then left reset or FAILED.
    static func probe(_ dev: PCIDevice, name: String) -> VirtioBlock? {
        guard let bar = dev.bars.first, bar.isIO, bar.address != 0, bar.address < 0x10000, bar.size >= 0x20 else {
            print("\(name): virtio-blk at \(dev.location) has no I/O BAR 0 (modern-only device?)")
            return nil
        }
        let io = UInt16(bar.address)
        dev.enable(io: true, busMaster: true)
        func status(_ s: UInt8) { outb(io + VirtioReg.status, s) }
        func fail(_ why: String) -> VirtioBlock? {
            status(VirtioStatus.failed)
            print("\(name): \(why)")
            return nil
        }
        status(0) // reset
        status(VirtioStatus.acknowledge)
        status(VirtioStatus.acknowledge | VirtioStatus.driver)
        let features = inl(io + VirtioReg.deviceFeatures)
        let accepted = features & (VirtioBlkFeature.flush | VirtioBlkFeature.readOnly)
        outl(io + VirtioReg.guestFeatures, accepted)

        outw(io + VirtioReg.queueSelect, 0)
        let n = Int(inw(io + VirtioReg.queueSize))
        guard n > 0, n & (n - 1) == 0 else { return fail("bad queue size \(n)") }
        guard inl(io + VirtioReg.queuePFN) == 0 else { return fail("queue 0 already in use") }
        let layout = queueLayout(n)
        guard let queuePhys = pmm.allocate(count: layout.frames) else { return fail("no memory for the queue") }
        guard let requestPhys = pmm.allocate(count: 1) else {
            pmm.free(queuePhys, count: layout.frames)
            return fail("no memory for requests")
        }
        guard let bouncePhys = pmm.allocate(count: bounceFrames) else {
            pmm.free(queuePhys, count: layout.frames)
            pmm.free(requestPhys, count: 1)
            return fail("no memory for the bounce buffer")
        }
        pmm.identity(queuePhys).initializeMemory(as: UInt8.self, repeating: 0, count: layout.frames * frameSize)
        pmm.identity(requestPhys).initializeMemory(as: UInt8.self, repeating: 0, count: frameSize)
        outl(io + VirtioReg.queuePFN, UInt32(queuePhys >> 12))

        let sectors = UInt64(inl(io + VirtioReg.config)) | UInt64(inl(io + VirtioReg.config + 4)) << 32
        let blk = VirtioBlock(name: name, pci: dev, io: io, sectors: sectors,
                              readOnly: accepted & VirtioBlkFeature.readOnly != 0,
                              canFlush: accepted & VirtioBlkFeature.flush != 0,
                              queueSize: n, queuePhys: queuePhys, queueFrames: layout.frames,
                              usedOffset: layout.usedOffset, requestPhys: requestPhys, bouncePhys: bouncePhys)
        // Polled: ask the device not to interrupt (it's only a hint).
        dma_store16(blk.avail, 1)
        status(VirtioStatus.acknowledge | VirtioStatus.driver | VirtioStatus.driverOK)
        return blk
    }

    private func setDescriptor(_ i: Int, _ phys: UInt, _ length: Int, _ flags: UInt16, next: Int = 0) {
        let d = desc + 16 * i
        d.storeBytes(of: UInt64(phys), toByteOffset: 0, as: UInt64.self)
        d.storeBytes(of: UInt32(length), toByteOffset: 8, as: UInt32.self)
        d.storeBytes(of: flags, toByteOffset: 12, as: UInt16.self)
        d.storeBytes(of: UInt16(next), toByteOffset: 14, as: UInt16.self)
    }

    /// One request: header, optional data (`count` sectors of the bounce
    /// buffer), status. Returns once the device has completed it.
    private func submit(_ type: UInt32, _ lba: UInt64, count: Int) throws(BlockError) {
        guard !broken else { throw .io }
        let req = pmm.identity(requestPhys)
        req.storeBytes(of: type, toByteOffset: 0, as: UInt32.self)
        req.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
        req.storeBytes(of: lba, toByteOffset: 8, as: UInt64.self)
        req.storeBytes(of: UInt8(0xFF), toByteOffset: 16, as: UInt8.self)
        if count > 0 {
            setDescriptor(0, requestPhys, 16, VirtqDesc.next, next: 1)
            setDescriptor(1, bouncePhys, count * sectorSize,
                          VirtqDesc.next | (type == VirtioBlkRequest.read ? VirtqDesc.write : 0), next: 2)
            setDescriptor(2, requestPhys + 16, 1, VirtqDesc.write)
        } else {
            setDescriptor(0, requestPhys, 16, VirtqDesc.next, next: 1)
            setDescriptor(1, requestPhys + 16, 1, VirtqDesc.write)
        }
        avail.storeBytes(of: UInt16(0), toByteOffset: 4 + 2 * (Int(availIdx) & (queueSize - 1)), as: UInt16.self)
        availIdx &+= 1
        dma_store16(avail + 2, availIdx) // release: the chain is visible first
        dma_fence()
        outw(io + VirtioReg.queueNotify, 0)

        let deadline = ticks + 2 * timerHz
        var spins = 0
        while dma_load16(used + 2) == usedIdx {
            spins += 1
            // ticks only advance with interrupts on; the spin cap is a backstop.
            if ticks >= deadline || spins > 1 << 28 {
                broken = true
                print("\(name): request timed out (type \(type), sector \(lba))")
                throw .io
            }
            cpu_pause()
        }
        usedIdx &+= 1
        _ = inb(io + VirtioReg.isr) // reading ISR status acknowledges any interrupt
        requests += 1
        guard dma_load8(req + 16) == 0 else { throw .io }
    }

    override func readSectors(_ lba: UInt64, count: Int, into buf: UnsafeMutableRawBufferPointer) throws(BlockError) {
        let bounce = pmm.identity(bouncePhys)
        var done = 0
        while done < count {
            let n = min(count - done, VirtioBlock.bounceSectors)
            try submit(VirtioBlkRequest.read, lba + UInt64(done), count: n)
            (buf.baseAddress! + done * sectorSize).copyMemory(from: bounce, byteCount: n * sectorSize)
            done += n
        }
    }

    override func writeSectors(_ lba: UInt64, count: Int, from buf: UnsafeRawBufferPointer) throws(BlockError) {
        let bounce = pmm.identity(bouncePhys)
        var done = 0
        while done < count {
            let n = min(count - done, VirtioBlock.bounceSectors)
            bounce.copyMemory(from: buf.baseAddress! + done * sectorSize, byteCount: n * sectorSize)
            try submit(VirtioBlkRequest.write, lba + UInt64(done), count: n)
            done += n
        }
    }

    override func flush() throws(BlockError) {
        guard canFlush else { return } // no FLUSH feature: the device has no write cache
        try submit(VirtioBlkRequest.flush, 0, count: 0)
    }
}

/// Phase V: find PCI devices, then every legacy virtio-blk function becomes
/// vda, vdb, ... in blockDevices. Called from kernelMain after smpInit.
func diskInit() {
    pciInit()
    var letter: UInt8 = 0x61 // "a"
    for dev in pciFind(vendor: virtioVendor, device: virtioBlkLegacyID) {
        let name = "vd" + String(decoding: [letter], as: UTF8.self)
        guard let blk = VirtioBlock.probe(dev, name: name) else { continue }
        blockDevices.append(blk)
        print("\(name): virtio-blk at \(dev.location), \(blk.sectorCount) sectors (\(blk.byteCount >> 20) MiB)\(blk.readOnly ? ", read-only" : "")\(blk.canFlush ? "" : ", no flush")")
        letter += 1
    }
    for dev in pciFind(vendor: virtioVendor, device: 0x1042) {
        print("virtio-blk at \(dev.location) is modern-only (needs disable-legacy=off): skipped")
    }
}

/// `disks`: one line per block device.
func disksLines() -> [String] {
    if blockDevices.isEmpty { return ["no disks"] }
    var lines = ["name  size      sectors         read   written"]
    for d in blockDevices {
        let mib = d.byteCount >> 20
        lines.append(pad(d.name, 6) + pad("\(mib) MiB", 10) + pad("\(d.sectorCount)", 10)
            + pad("\(d.sectorsRead)", 9, left: true) + pad("\(d.sectorsWritten)", 10, left: true) + (d.readOnly ? "  ro" : ""))
    }
    return lines
}

func virtioTests(_ t: inout SelfTest) {
    let layout = VirtioBlock.queueLayout(256)
    t.check("virtio: legacy queue layout (256: used ring at 8 KiB, 3 frames)",
            layout.usedOffset == 8192 && layout.frames == 3 && VirtioBlock.queueLayout(128).frames == 2)
    t.check("disks: 'no disks' when there are none", !blockDevices.isEmpty || disksLines() == ["no disks"])
    guard let vda = blockDevices.first(where: { $0.name == "vda" }) else {
        puts("  note no vda: virtio-blk round trip skipped\n")
        return
    }
    let blk = vda as? VirtioBlock
    t.check("virtio: vda is a VirtioBlock with a queue", blk.map { $0.queueSize > 0 && !$0.broken } == true)
    // Save the last sector, write a pattern over it, read it back, flush,
    // restore it, and read the original back again. Then a transfer bigger
    // than the bounce buffer.
    let last = vda.sectorCount - 1
    guard let saved = try? vda.read(last, count: 1) else {
        t.check("virtio: read the last sector", false)
        return
    }
    var pattern = [UInt8](repeating: 0, count: sectorSize)
    for i in 0..<sectorSize { pattern[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
    let before = vda.sectorsWritten
    let wrote = (try? vda.write(last, pattern)) != nil
    let back = try? vda.read(last, count: 1)
    let flushed = (try? vda.flush()) != nil
    let restored = (try? vda.write(last, saved)) != nil && (try? vda.flush()) != nil
    t.check("virtio: write/read/flush round trip on the last sector", wrote && back == pattern && flushed)
    t.check("virtio: last sector restored", restored && (try? vda.read(last, count: 1)) == saved
        && vda.sectorsWritten == before + 2)
    // Bigger than the bounce buffer, so split into chunks: the last `span`
    // sectors, saved and restored the same way.
    let span = VirtioBlock.bounceSectors + 3
    let start = vda.sectorCount - UInt64(span)
    if let savedSpan = try? vda.read(start, count: span) {
        var big = [UInt8](repeating: 0, count: span * sectorSize)
        for i in 0..<big.count { big[i] = UInt8(truncatingIfNeeded: (i / sectorSize) &* 13 &+ i) }
        let wroteBig = (try? vda.write(start, big)) != nil
        let readBig = try? vda.read(start, count: span)
        let oneByOne = try? vda.read(vda.sectorCount - 1, count: 1)
        let restoredBig = (try? vda.write(start, savedSpan)) != nil && (try? vda.flush()) != nil
        t.check("virtio: multi-chunk write/read (131 sectors)", wroteBig && readBig == big
            && oneByOne == Array(big[(span - 1) * sectorSize..<span * sectorSize]))
        t.check("virtio: multi-chunk span restored", restoredBig && (try? vda.read(start, count: span)) == savedSpan)
    } else {
        t.check("virtio: multi-chunk read", false)
    }
    t.check("virtio: out of range rejected", (try? vda.read(vda.sectorCount, count: 1)) == nil)
}

extension Shell {
    static func diskCommands() -> [Command<T>] {
        [
            Command(name: "lspci", args: "", help: "list PCI functions: location, vendor:device, class") { sh, _ in
                for l in lspciLines() { sh.say(l) }
            },
            Command(name: "disks", args: "", help: "list block devices: size, sectors read/written") { sh, _ in
                for l in disksLines() { sh.say(l) }
            },
        ]
    }
}
