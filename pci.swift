// Part 5 (Phase V1): PCI enumeration through configuration mechanism #1
// (address to port 0xCF8, data at 0xCFC). Brute force: every bus, device
// and function (functions 1-7 only on multi-function devices). Run once at
// boot from diskInit (CPU 0), which keeps the list for `lspci` and drivers.

struct PCIBar {
    /// I/O-port BAR (else memory).
    var isIO = false
    var is64 = false
    var prefetchable = false
    /// Port or physical address; 0 with size 0 = unused or unassigned.
    var address: UInt64 = 0
    var size: UInt64 = 0
}

struct PCIDevice {
    var bus: UInt8
    var device: UInt8
    var function: UInt8
    var vendorID: UInt16
    var deviceID: UInt16
    var classCode: UInt8
    var subclass: UInt8
    var progIF: UInt8
    var headerType: UInt8
    var interruptLine: UInt8
    var interruptPin: UInt8
    /// Six slots for a normal device (two for a bridge, none otherwise); the
    /// upper half of a 64-bit BAR is an empty slot.
    var bars: [PCIBar]

    /// "bb:dd.f"
    var location: String {
        "\(hexDigits(UInt64(bus), 2)):\(hexDigits(UInt64(device), 2)).\(function)"
    }

    func read32(_ offset: UInt8) -> UInt32 { pciRead32(bus, device, function, offset) }
    func write32(_ offset: UInt8, _ value: UInt32) { pciWrite32(bus, device, function, offset, value) }

    /// Turn on I/O and/or memory decoding and bus mastering (DMA) in the
    /// command register.
    func enable(io: Bool = false, memory: Bool = false, busMaster: Bool = false) {
        var command = read32(0x04) & 0xFFFF
        if io { command |= 1 }
        if memory { command |= 2 }
        if busMaster { command |= 4 }
        write32(0x04, command) // the upper half (status) is write-1-to-clear: leave it 0
    }

    var command: UInt16 { UInt16(truncatingIfNeeded: read32(0x04)) }
}

enum PCIConfig {
    static let address: UInt16 = 0xCF8
    static let data: UInt16 = 0xCFC
}

func pciRead32(_ bus: UInt8, _ device: UInt8, _ function: UInt8, _ offset: UInt8) -> UInt32 {
    outl(PCIConfig.address, pciAddress(bus, device, function, offset))
    return inl(PCIConfig.data)
}

func pciWrite32(_ bus: UInt8, _ device: UInt8, _ function: UInt8, _ offset: UInt8, _ value: UInt32) {
    outl(PCIConfig.address, pciAddress(bus, device, function, offset))
    outl(PCIConfig.data, value)
}

private func pciAddress(_ bus: UInt8, _ device: UInt8, _ function: UInt8, _ offset: UInt8) -> UInt32 {
    0x8000_0000 | UInt32(bus) << 16 | UInt32(device & 31) << 11 | UInt32(function & 7) << 8 | UInt32(offset & 0xFC)
}

/// Every function found by pciInit.
var pciDevices: [PCIDevice] = []

func pciInit() {
    pciDevices = pciEnumerate()
    print("pci: \(pciDevices.count) functions")
}

func pciEnumerate() -> [PCIDevice] {
    var found: [PCIDevice] = []
    for bus in 0..<256 {
        for device in 0..<32 {
            let b = UInt8(bus), d = UInt8(device)
            guard pciRead32(b, d, 0, 0) & 0xFFFF != 0xFFFF else { continue }
            let multi = (pciRead32(b, d, 0, 0x0C) >> 16) & 0x80 != 0
            for function in 0..<(multi ? 8 : 1) {
                if let dev = pciProbe(b, d, UInt8(function)) { found.append(dev) }
            }
        }
    }
    return found
}

private func pciProbe(_ bus: UInt8, _ device: UInt8, _ function: UInt8) -> PCIDevice? {
    let id = pciRead32(bus, device, function, 0)
    guard id & 0xFFFF != 0xFFFF else { return nil }
    let classReg = pciRead32(bus, device, function, 0x08)
    let header = UInt8(truncatingIfNeeded: pciRead32(bus, device, function, 0x0C) >> 16) & 0x7F
    let irq = pciRead32(bus, device, function, 0x3C)
    var dev = PCIDevice(bus: bus, device: device, function: function,
                        vendorID: UInt16(truncatingIfNeeded: id), deviceID: UInt16(truncatingIfNeeded: id >> 16),
                        classCode: UInt8(truncatingIfNeeded: classReg >> 24),
                        subclass: UInt8(truncatingIfNeeded: classReg >> 16),
                        progIF: UInt8(truncatingIfNeeded: classReg >> 8),
                        headerType: header,
                        interruptLine: UInt8(truncatingIfNeeded: irq), interruptPin: UInt8(truncatingIfNeeded: irq >> 8),
                        bars: [])
    let barCount = header == 0 ? 6 : header == 1 ? 2 : 0
    if barCount > 0 { dev.bars = pciSizeBars(dev, count: barCount) }
    return dev
}

/// Read each BAR and size it (write all ones, read back the mask, restore).
/// Decoding is off meanwhile, so the device can't answer at a bogus address,
/// and so are interrupts on this CPU, to keep that window short.
private func pciSizeBars(_ dev: PCIDevice, count: Int) -> [PCIBar] {
    var bars = [PCIBar](repeating: PCIBar(), count: count)
    let flags = irq_save()
    let command = dev.read32(0x04) & 0xFFFF
    dev.write32(0x04, command & ~3)
    var i = 0
    while i < count {
        let offset = UInt8(0x10 + 4 * i)
        let original = dev.read32(offset)
        dev.write32(offset, 0xFFFF_FFFF)
        let mask = dev.read32(offset)
        dev.write32(offset, original)
        var bar = PCIBar()
        if original & 1 == 1 {
            bar.isIO = true
            bar.address = UInt64(original & 0xFFFF_FFFC)
            let m = mask & 0xFFFF_FFFC
            if m != 0 { bar.size = UInt64((~m & 0xFFFF) &+ 1) }
        } else {
            bar.prefetchable = original & 8 != 0
            bar.is64 = (original >> 1) & 3 == 2 && i + 1 < count
            var address = UInt64(original & 0xFFFF_FFF0)
            var sizeMask = UInt64(mask & 0xFFFF_FFF0)
            if bar.is64 {
                let hiOffset = offset + 4
                let hi = dev.read32(hiOffset)
                dev.write32(hiOffset, 0xFFFF_FFFF)
                let hiMask = dev.read32(hiOffset)
                dev.write32(hiOffset, hi)
                address |= UInt64(hi) << 32
                sizeMask |= UInt64(hiMask) << 32
            } else if sizeMask != 0 {
                sizeMask |= 0xFFFF_FFFF_0000_0000
            }
            bar.address = address
            if sizeMask != 0 { bar.size = ~sizeMask &+ 1 }
        }
        bars[i] = bar
        i += bar.is64 ? 2 : 1
    }
    dev.write32(0x04, command)
    irq_restore(flags)
    return bars
}

/// Every function with this vendor/device ID pair, in bus order.
func pciFind(vendor: UInt16, device: UInt16) -> [PCIDevice] {
    pciDevices.filter { $0.vendorID == vendor && $0.deviceID == device }
}

func pciClassName(_ c: UInt8, _ sub: UInt8) -> String {
    switch (c, sub) {
    case (0x01, 0x00): return "SCSI storage"
    case (0x01, 0x01): return "IDE"
    case (0x01, 0x06): return "SATA (AHCI)"
    case (0x01, 0x08): return "NVMe"
    case (0x01, _): return "storage"
    case (0x02, _): return "network"
    case (0x03, _): return "display"
    case (0x04, _): return "multimedia"
    case (0x06, 0x00): return "host bridge"
    case (0x06, 0x01): return "ISA bridge"
    case (0x06, 0x04): return "PCI bridge"
    case (0x06, _): return "bridge"
    case (0x0C, 0x03): return "USB"
    case (0x0C, 0x05): return "SMBus"
    case (0x0C, _): return "serial bus"
    default: return "other"
    }
}

/// `lspci`: one line per function, e.g.
/// "00:02.0 1af4:1001 01.00 SCSI storage  io 0xc000+64  irq 11".
func lspciLines() -> [String] {
    if pciDevices.isEmpty { return ["no PCI devices"] }
    var lines: [String] = []
    for d in pciDevices {
        var l = "\(d.location) \(hexDigits(UInt64(d.vendorID), 4)):\(hexDigits(UInt64(d.deviceID), 4)) "
            + "\(hexDigits(UInt64(d.classCode), 2)).\(hexDigits(UInt64(d.subclass), 2)) \(pciClassName(d.classCode, d.subclass))"
        for bar in d.bars where bar.size > 0 {
            l += bar.isIO ? "  io 0x\(hexDigits(bar.address, 4))" : "  mem 0x\(hexDigits(bar.address, 8))"
            l += bar.size >= 1 << 20 ? "+\(bar.size >> 20)M" : bar.size >= 1 << 10 ? "+\(bar.size >> 10)K" : "+\(bar.size)"
        }
        if d.interruptPin != 0 { l += "  irq \(d.interruptLine)" }
        lines.append(l)
    }
    return lines
}

/// Lower-case hex, zero-padded to at least `width` digits, no prefix.
func hexDigits(_ value: UInt64, _ width: Int) -> String {
    var bytes: [UInt8] = []
    var v = value
    repeat {
        let nibble = UInt8(truncatingIfNeeded: v & 0xF)
        bytes.append(nibble < 10 ? 0x30 + nibble : 0x61 + nibble - 10)
        v >>= 4
    } while v != 0
    while bytes.count < width { bytes.append(0x30) }
    return String(decoding: bytes.reversed(), as: UTF8.self)
}

func pciTests(_ t: inout SelfTest) {
    t.check("pci: host bridge at 00:00.0", pciDevices.first.map { $0.bus == 0 && $0.device == 0 && $0.classCode == 0x06 } == true)
    t.check("pci: config read matches the cached IDs",
            pciDevices.allSatisfy { pciRead32($0.bus, $0.device, $0.function, 0) == UInt32($0.deviceID) << 16 | UInt32($0.vendorID) })
    t.check("pci: hexDigits", hexDigits(0x1af4, 4) == "1af4" && hexDigits(3, 2) == "03" && hexDigits(0, 1) == "0")
}
