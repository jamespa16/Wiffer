// Part 5 (Phase U): block devices. The contract between disk drivers
// (virtio-blk, Phase V) and filesystems (FAT32, Phases W/X).
//
// A BlockDevice is a numbered array of 512-byte sectors. Drivers subclass it
// (a class hierarchy, not a protocol: the FAT volume stores "some device"
// and existentials are limited in Embedded Swift). Reads and writes are
// synchronous: a driver may spin or yield() inside, but returns only once
// the transfer is complete (for a write: the device has accepted the data;
// flush() makes it durable).
//
// Like the RAM fs, block devices are CPU-0-only (ROADMAP Part 4 affinity):
// serialized by diskOperationLock across operations that may sleep.

/// CPU-0 cooperative, task-recursive mutex. The filesystem takes this for
/// complete operations, not just individual transfers: a sleeping DMA request
/// must not let another task enter partially updated FAT/VFS state.
final class DiskOperationLock {
    private var owner: Task? = nil
    private var depth = 0
    private var waiters: [Task] = []

    func acquire() {
        let me = scheduler.current
        while depth != 0 && owner !== me {
            if let me, !me.isMain {
                if !waiters.contains(where: { $0 === me }) { waiters.append(me) }
                park()
            } else {
                // Task 0 cannot park, but can run the task owning the mutex.
                yield()
            }
        }
        owner = me
        depth += 1
    }

    func release() {
        guard depth > 0, owner === scheduler.current else { taskPanic("disk mutex ownership") }
        depth -= 1
        if depth != 0 { return }
        owner = nil
        let waking = waiters
        waiters = []
        for task in waking { unpark(task) }
    }
}

let diskOperationLock = DiskOperationLock()

let sectorSize = 512

enum BlockError: Error, Equatable {
    /// lba + count runs past the end of the device, or count is 0.
    case outOfRange
    /// The device reported an error, or didn't answer.
    case io
    /// A write to a read-only device.
    case readOnly

    var message: String {
        switch self {
        case .outOfRange: return "sector out of range"
        case .io: return "I/O error"
        case .readOnly: return "read-only device"
        }
    }
}

class BlockDevice {
    /// Short name for `disks` and messages, e.g. "vda" or "ram0".
    let name: String
    let sectorCount: UInt64
    let readOnly: Bool
    /// Counters for `disks` and selftests.
    var sectorsRead: UInt64 = 0
    var sectorsWritten: UInt64 = 0

    init(name: String, sectorCount: UInt64, readOnly: Bool = false) {
        self.name = name
        self.sectorCount = sectorCount
        self.readOnly = readOnly
    }

    var byteCount: UInt64 { sectorCount * UInt64(sectorSize) }

    /// `count` sectors from `lba`, as count * 512 bytes.
    func read(_ lba: UInt64, count: Int) throws(BlockError) -> [UInt8] {
        try check(lba, count)
        var out = [UInt8](repeating: 0, count: count * sectorSize)
        var failure: BlockError? = nil
        out.withUnsafeMutableBytes { buf in
            do throws(BlockError) { try readSectors(lba, count: count, into: buf) } catch { failure = error }
        }
        if let failure { throw failure }
        sectorsRead += UInt64(count)
        return out
    }

    /// Write whole sectors from `lba`: bytes.count must be a non-zero
    /// multiple of 512.
    func write(_ lba: UInt64, _ bytes: [UInt8]) throws(BlockError) {
        guard bytes.count % sectorSize == 0 else { throw .outOfRange }
        let count = bytes.count / sectorSize
        try check(lba, count)
        guard !readOnly else { throw .readOnly }
        var failure: BlockError? = nil
        bytes.withUnsafeBytes { buf in
            do throws(BlockError) { try writeSectors(lba, count: count, from: buf) } catch { failure = error }
        }
        if let failure { throw failure }
        sectorsWritten += UInt64(count)
    }

    /// Make every completed write durable.
    func flush() throws(BlockError) {}

    private func check(_ lba: UInt64, _ count: Int) throws(BlockError) {
        guard count > 0, lba < sectorCount, UInt64(count) <= sectorCount - lba else { throw .outOfRange }
    }

    // MARK: Driver hooks (range already checked; buffers are count * 512 bytes)

    func readSectors(_ lba: UInt64, count: Int, into buf: UnsafeMutableRawBufferPointer) throws(BlockError) {
        throw .io
    }

    func writeSectors(_ lba: UInt64, count: Int, from buf: UnsafeRawBufferPointer) throws(BlockError) {
        throw .io
    }
}

/// A device in heap memory, for selftests (format, fill, corrupt, remount).
/// Sparse: only sectors that were written with non-zero bytes are stored, so
/// a full-size FAT32 volume (at least ~33 MiB) costs only what it holds.
final class RamDisk: BlockDevice {
    /// Non-zero sectors by LBA; a missing sector reads as zeros.
    var sectors: [UInt64: [UInt8]] = [:]
    /// Fault injection: after this many more sector writes succeed, every
    /// write throws .io (a "power cut" mid-operation). nil = never.
    var failWritesAfter: Int? = nil

    init(name: String = "ram0", sectors count: UInt64) {
        super.init(name: name, sectorCount: count)
    }

    override func readSectors(_ lba: UInt64, count: Int, into buf: UnsafeMutableRawBufferPointer) throws(BlockError) {
        for s in 0..<count {
            let base = s * sectorSize
            if let data = sectors[lba + UInt64(s)] {
                for i in 0..<sectorSize { buf[base + i] = data[i] }
            } else {
                for i in 0..<sectorSize { buf[base + i] = 0 }
            }
        }
    }

    override func writeSectors(_ lba: UInt64, count: Int, from buf: UnsafeRawBufferPointer) throws(BlockError) {
        for s in 0..<count {
            if let n = failWritesAfter {
                guard n > 0 else { throw .io }
                failWritesAfter = n - 1
            }
            let base = s * sectorSize
            var zero = true
            for i in 0..<sectorSize where buf[base + i] != 0 { zero = false; break }
            if zero {
                sectors[lba + UInt64(s)] = nil
            } else {
                sectors[lba + UInt64(s)] = Array(buf[base..<(base + sectorSize)])
            }
        }
    }
}

/// Every block device found at boot (drivers append in their init).
var blockDevices: [BlockDevice] = []

func blockTests(_ t: inout SelfTest) {
    let d = RamDisk(sectors: 8)
    let big = RamDisk(sectors: 1 << 17) // 64 MiB, sparse
    var pattern = [UInt8](repeating: 0, count: 2 * sectorSize)
    for i in 0..<pattern.count { pattern[i] = UInt8(truncatingIfNeeded: i &* 7) }
    let wrote = (try? d.write(3, pattern)) != nil
    let back = try? d.read(3, count: 2)
    t.check("block: RamDisk write/read round trip", wrote && back == pattern && d.sectorsWritten == 2 && d.sectorsRead == 2)
    t.check("block: out-of-range read/write", (try? d.read(7, count: 2)) == nil && (try? d.read(8, count: 1)) == nil
        && (try? d.read(0, count: 0)) == nil && (try? d.write(7, pattern)) == nil)
    t.check("block: partial-sector write rejected", (try? d.write(0, [1, 2, 3])) == nil)
    d.failWritesAfter = 1
    let torn = (try? d.write(0, pattern)) == nil
    let first = try? d.read(0, count: 1)
    let bigOK = (try? big.write(big.sectorCount - 1, pattern[0..<sectorSize].map { $0 })) != nil
        && (try? big.read(big.sectorCount - 1, count: 1)) == Array(pattern[0..<sectorSize])
        && (try? big.read(5, count: 1)) == [UInt8](repeating: 0, count: sectorSize) && big.sectors.count == 1
    let zeroed = (try? big.write(big.sectorCount - 1, [UInt8](repeating: 0, count: sectorSize))) != nil && big.sectors.isEmpty
    t.check("block: sparse RamDisk", bigOK && zeroed)
    t.check("block: injected write failure", torn && first.map { Array($0) == Array(pattern[0..<sectorSize]) } == true)
}
