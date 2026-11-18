// Part 5 (Phases W and X): FAT32 on a BlockDevice.
//
// Whole-disk ("superfloppy") FAT32 with 512-byte sectors: format, mount,
// list, read, write (create or replace), mkdir, remove, rename, sync and an
// fsck-style check(). VFAT long names are read and written; lookup folds
// ASCII case (FAT is case-insensitive) and names keep their case. A name
// that is a plain 8.3 name in one case per part ("readme.txt", "README.TXT",
// "notes.TXT") is stored as the 8.3 entry alone with the Windows NT case bits
// (0x08 base lower, 0x10 extension lower); anything else gets LFN entries and
// a generated short name (NAME~1.TXT).
//
// Nothing is cached between operations except clean FAT sectors: each call
// re-reads the directories on its path. Dirty FAT sectors are written back
// (to every FAT copy) before the operation returns, then FSInfo, then the
// device is flushed.
//
// Crash safety (ROADMAP Part 5): a file write puts the data into newly
// allocated clusters and writes their FAT links first, then points the
// directory entry at them (that single-sector write is the commit point),
// then frees the old chain. New directory entries go in with the 8.3 entry's
// sector written last; deletions write the 8.3 entry's sector first. A
// directory grows by writing a zeroed cluster, marking it end-of-chain, and
// only then linking it in. So an interruption leaks clusters at worst (check()
// reports them), and never damages an existing file.
//
// Errors: an operation that throws has not reached its commit point, so the
// volume reads as before (it re-reads the FAT free count from disk, dropping
// anything unflushed). Errors after the commit point (freeing the old
// chain, deleting the old entry of a rename) are not reported: they can only
// leak clusters or leave orphaned long-name entries.
//
// Everything read from disk is bounds-checked: a damaged volume gives
// .corrupt or .notFAT32, never a trap. CPU 0 only, like the RAM fs.

enum FATError: Error, Equatable {
    case notFAT32
    case corrupt
    case notFound
    case exists
    case notADirectory
    case isADirectory
    case notEmpty
    /// Characters FAT can't store, an empty or over-long name, a name
    /// ending in a space or dot, an empty path where a name is needed, or a
    /// directory moved into itself.
    case invalidName
    /// No free clusters (or directory slots, or short names); also a volume
    /// too small to format as FAT32.
    case noSpace
    case io(BlockError)

    var message: String {
        switch self {
        case .notFAT32: return "not a FAT32 filesystem"
        case .corrupt: return "filesystem is corrupt"
        case .notFound: return "no such file or directory"
        case .exists: return "already exists"
        case .notADirectory: return "not a directory"
        case .isADirectory: return "is a directory"
        case .notEmpty: return "directory not empty"
        case .invalidName: return "invalid name"
        case .noSpace: return "no space left on device"
        case .io(let e): return e.message
        }
    }
}

struct FATEntry: Equatable {
    var name: String
    var isDirectory: Bool
    /// Bytes in a file; 0 for a directory.
    var size: Int
}

struct FATTimestamp: Equatable {
    var year = 2026
    var month = 1
    var day = 1
    var hour = 0
    var minute = 0
    var second = 0
}

func fatDefaultClock() -> FATTimestamp { FATTimestamp() }

/// Where FAT timestamps come from. Phase Y points it at the CMOS RTC; until
/// then it is always 2026-01-01 00:00.
var fatClock: () -> FATTimestamp = fatDefaultClock

/// FAT's packed (date, time) for `t`: date = years since 1980 << 9 | month
/// << 5 | day, time = hour << 11 | minute << 5 | seconds / 2.
func fatDateTime(_ t: FATTimestamp) -> (date: Int, time: Int) {
    let year = min(max(t.year, 1980), 2107)
    let month = min(max(t.month, 1), 12), day = min(max(t.day, 1), 31)
    let date = (year - 1980) << 9 | month << 5 | day
    let time = min(max(t.hour, 0), 23) << 11 | min(max(t.minute, 0), 59) << 5 | min(max(t.second, 0), 59) / 2
    return (date, time)
}

// MARK: On-disk constants

let fatEntryMask: UInt32 = 0x0FFF_FFFF
/// What we write to end a chain; anything >= fatEndMin ends one.
let fatEndOfChain: UInt32 = 0x0FFF_FFFF
let fatEndMin: UInt32 = 0x0FFF_FFF8
let fatBadCluster: UInt32 = 0x0FFF_FFF7
/// FAT32 is defined by cluster count: fewer than this is FAT12/16.
let fatMinClusters = 65_525
/// A directory may hold at most 65,536 32-byte entries (2 MiB).
let fatMaxDirSlots = 65_536
let fatSlotSize = 32

let fatAttrReadOnly: UInt8 = 0x01
let fatAttrVolumeID: UInt8 = 0x08
let fatAttrDirectory: UInt8 = 0x10
let fatAttrArchive: UInt8 = 0x20
/// read-only | hidden | system | volume ID: marks a long-name entry.
let fatAttrLongName: UInt8 = 0x0F

let fatCaseLowerBase: UInt8 = 0x08
let fatCaseLowerExt: UInt8 = 0x10

let fatFSInfoLead: UInt32 = 0x4161_5252
let fatFSInfoStruct: UInt32 = 0x6141_7272
let fatFSInfoTrail: UInt32 = 0xAA55_0000

extension Array where Element == UInt8 {
    func le16(_ i: Int) -> Int { Int(self[i]) | Int(self[i + 1]) << 8 }
    func le32(_ i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    mutating func put16(_ i: Int, _ v: Int) {
        self[i] = UInt8(truncatingIfNeeded: v)
        self[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    mutating func put32(_ i: Int, _ v: UInt32) {
        for k in 0..<4 { self[i + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(k))) }
    }
    mutating func put(_ i: Int, _ bytes: [UInt8]) {
        for (k, b) in bytes.enumerated() { self[i + k] = b }
    }
}

// MARK: Names

func fatUpper(_ b: UInt8) -> UInt8 { b >= 0x61 && b <= 0x7A ? b - 0x20 : b }
func fatLower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 0x20 : b }

/// FAT's name comparison: ASCII letters fold, every other byte must match.
func fatNamesMatch(_ a: String, _ b: String) -> Bool {
    var i = a.utf8.makeIterator(), j = b.utf8.makeIterator()
    while true {
        let x = i.next(), y = j.next()
        if x == nil && y == nil { return true }
        guard let x, let y, fatUpper(x) == fatUpper(y) else { return false }
    }
}

/// A byte allowed in a short (8.3) name we write: A-Z, 0-9 and
/// ! # $ % & ' ( ) - @ ^ _ ` { } ~.
func fatShortChar(_ b: UInt8) -> Bool {
    switch b {
    case 0x41...0x5A, 0x30...0x39: return true
    case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2D, 0x40, 0x5E, 0x5F, 0x60, 0x7B, 0x7D, 0x7E: return true
    default: return false
    }
}

/// A name FAT can store as a long name: 1-255 UTF-16 units, no control
/// characters or " * / : < > ? \ |, not "." or "..", and (as Windows would
/// silently strip them) no trailing space or dot.
func fatValidName(_ name: String) -> Bool {
    guard let last = name.utf8.last, last != 0x20, last != 0x2E, name.utf16.count <= 255 else { return false }
    for b in name.utf8 {
        switch b {
        case 0x00..<0x20, 0x22, 0x2A, 0x2F, 0x3A, 0x3C, 0x3E, 0x3F, 0x5C, 0x7C: return false
        default: continue
        }
    }
    return true
}

/// `name` as an 8.3 entry with no long name (11 bytes, space padded, and
/// the NT case bits), or nil if it needs one.
func fatPlainShortName(_ name: String) -> (short: [UInt8], caseBits: UInt8)? {
    var short = [UInt8](repeating: 0x20, count: 11)
    var inExt = false, len = 0
    var baseLower = false, baseUpper = false, extLower = false, extUpper = false
    for b in name.utf8 {
        if b == 0x2E {
            guard !inExt, len > 0 else { return nil }
            inExt = true
            len = 0
            continue
        }
        guard len < (inExt ? 3 : 8) else { return nil }
        var c = b
        if c >= 0x61 && c <= 0x7A {
            c -= 0x20
            if inExt { extLower = true } else { baseLower = true }
        } else if c >= 0x41 && c <= 0x5A {
            if inExt { extUpper = true } else { baseUpper = true }
        }
        guard fatShortChar(c) else { return nil }
        short[(inExt ? 8 : 0) + len] = c
        len += 1
    }
    guard len > 0, !(baseLower && baseUpper), !(extLower && extUpper) else { return nil }
    return (short, (baseLower ? fatCaseLowerBase : 0) | (extLower ? fatCaseLowerExt : 0))
}

/// The basis of a generated short name: up to 8 base and 3 extension
/// characters, uppercased, spaces and extra dots dropped, anything else
/// FAT can't hold in a short name turned into '_'.
func fatShortBasis(_ name: String) -> (base: [UInt8], ext: [UInt8]) {
    let scalars = Array(name.unicodeScalars)
    var start = 0
    while start < scalars.count && scalars[start].value == 0x2E { start += 1 }
    var dot = -1
    for i in start..<scalars.count where scalars[i].value == 0x2E { dot = i }
    func convert(_ range: Range<Int>, _ limit: Int) -> [UInt8] {
        var out: [UInt8] = []
        for i in range where out.count < limit {
            let v = scalars[i].value
            if v == 0x20 || v == 0x2E { continue }
            if v < 0x80, fatShortChar(fatUpper(UInt8(v))) { out.append(fatUpper(UInt8(v))) } else { out.append(0x5F) }
        }
        return out
    }
    var base = convert(start..<(dot >= 0 ? dot : scalars.count), 8)
    let ext = dot >= 0 ? convert((dot + 1)..<scalars.count, 3) : []
    if base.isEmpty { base = [0x5F] }
    return (base, ext)
}

/// BASIS~N.EXT as 11 bytes.
func fatNumberedShortName(_ base: [UInt8], _ ext: [UInt8], _ n: Int) -> [UInt8] {
    var tail: [UInt8] = []
    var v = n
    repeat { tail.insert(0x30 + UInt8(v % 10), at: 0); v /= 10 } while v > 0
    tail.insert(0x7E, at: 0)
    var short = [UInt8](repeating: 0x20, count: 11)
    let keep = min(base.count, 8 - tail.count)
    for i in 0..<keep { short[i] = base[i] }
    for (i, b) in tail.enumerated() { short[keep + i] = b }
    for (i, b) in ext.enumerated() { short[8 + i] = b }
    return short
}

/// The checksum an LFN entry carries of its 8.3 name (bytes at..<at+11).
func fatChecksum(_ bytes: [UInt8], _ at: Int) -> UInt8 {
    var sum: UInt8 = 0
    for i in 0..<11 { sum = ((sum & 1) << 7) &+ (sum >> 1) &+ bytes[at + i] }
    return sum
}

/// Byte offset of UTF-16 unit `j` (0..<13) inside an LFN entry.
func fatLFNOffset(_ j: Int) -> Int { j < 5 ? 1 + 2 * j : j < 11 ? 14 + 2 * (j - 5) : 28 + 2 * (j - 11) }

/// An 8.3 name for display: base, then "." and extension if there is one,
/// with the NT case bits applied. Bytes above 0x7F are shown as Latin-1.
func fatShortDisplay(_ data: [UInt8], _ o: Int) -> String {
    let bits = data[o + 12]
    var units: [UInt16] = []
    var baseEnd = 8, extEnd = 11
    while baseEnd > 0 && data[o + baseEnd - 1] == 0x20 { baseEnd -= 1 }
    while extEnd > 8 && data[o + extEnd - 1] == 0x20 { extEnd -= 1 }
    for i in 0..<baseEnd {
        var b = data[o + i]
        if i == 0 && b == 0x05 { b = 0xE5 } // 0xE5 as a first byte is stored as 0x05
        units.append(UInt16(bits & fatCaseLowerBase != 0 ? fatLower(b) : b))
    }
    if extEnd > 8 {
        units.append(0x2E)
        for i in 8..<extEnd { units.append(UInt16(bits & fatCaseLowerExt != 0 ? fatLower(data[o + i]) : data[o + i])) }
    }
    return String(decoding: units, as: UTF16.self)
}

/// A volume label as 11 space-padded bytes, or nil if `label` has more
/// than 11 characters or ones a short name can't hold (spaces are allowed
/// inside; letters are uppercased).
func fatLabelBytes(_ label: String) -> [UInt8]? {
    var out = [UInt8](repeating: 0x20, count: 11)
    var n = 0
    for b in label.utf8 {
        let c = fatUpper(b)
        guard n < 11, fatShortChar(c) || (c == 0x20 && n > 0) else { return nil }
        out[n] = c
        n += 1
    }
    return out
}

func fatLabelString(_ bytes: [UInt8], _ o: Int) -> String {
    var end = 11
    while end > 0 && bytes[o + end - 1] == 0x20 { end -= 1 }
    var units: [UInt16] = []
    for i in 0..<end { units.append(UInt16(bytes[o + i])) }
    let s = String(decoding: units, as: UTF16.self)
    return s == "NO NAME" ? "" : s
}

/// What a new directory entry looks like on disk: a short name, its case
/// bits, and the long name if one is needed.
struct FATNamePlan {
    var short: [UInt8]
    var caseBits: UInt8
    var long: [UInt16]?

    /// LFN entries plus the 8.3 entry.
    var slots: Int { 1 + ((long?.count ?? 0) + 12) / 13 }

    /// The entries in disk order: LFN entries (highest sequence first, the
    /// first flagged 0x40), then `template` (a 32-byte 8.3 entry) renamed.
    func entryBytes(_ template: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        if let long {
            let n = (long.count + 12) / 13
            let sum = fatChecksum(short, 0)
            var k = n
            while k >= 1 {
                var e = [UInt8](repeating: 0, count: fatSlotSize)
                e[0] = UInt8(k) | (k == n ? 0x40 : 0)
                e[11] = fatAttrLongName
                e[13] = sum
                for j in 0..<13 {
                    let i = (k - 1) * 13 + j
                    e.put16(fatLFNOffset(j), i < long.count ? Int(long[i]) : i == long.count ? 0 : 0xFFFF)
                }
                out += e
                k -= 1
            }
        }
        var e = template
        e.put(0, short)
        e[12] = caseBits
        return out + e
    }
}

// MARK: Directories

/// A parsed directory entry (the long name's run and its 8.3 entry).
struct FATDirEntry {
    var name: String
    var attr: UInt8
    var cluster: UInt32
    var size: Int
    /// The first slot of the entry: its first LFN entry, or `slot`.
    var first: Int
    /// The 8.3 entry's slot.
    var slot: Int

    var isDirectory: Bool { attr & fatAttrDirectory != 0 }
}

/// A whole directory in memory: its cluster chain, raw bytes and entries.
struct FATDir {
    var cluster: UInt32
    var chain: [UInt32]
    var data: [UInt8]
    /// Entries, in disk order, without ".", ".." and the volume label.
    var entries: [FATDirEntry] = []
    /// The first end-of-directory (0x00) slot, or `slots` if there is none.
    var end = 0
    var dot: Int? = nil
    var dotdot: Int? = nil
    /// Slot of the volume label entry (in the root).
    var labelSlot: Int? = nil

    init(cluster: UInt32, chain: [UInt32], data: [UInt8]) {
        self.cluster = cluster
        self.chain = chain
        self.data = data
        parse()
    }

    var slots: Int { data.count / fatSlotSize }

    func clusterAt(_ slot: Int) -> UInt32 {
        let o = slot * fatSlotSize
        return UInt32(data.le16(o + 20)) << 16 | UInt32(data.le16(o + 26))
    }

    mutating func parse() {
        entries = []
        end = slots
        dot = nil
        dotdot = nil
        labelSlot = nil
        var units: [UInt16] = []
        var need = 0, complete = false, sum: UInt8 = 0, start = 0
        for slot in 0..<slots {
            let o = slot * fatSlotSize
            let b0 = data[o], attr = data[o + 11]
            if b0 == 0 { end = slot; break }
            if b0 == 0xE5 { need = 0; complete = false; continue }
            if attr & 0x3F == fatAttrLongName {
                let seq = Int(b0 & 0x1F)
                if b0 & 0x40 != 0 {
                    guard seq >= 1 && seq <= 20 else { need = 0; complete = false; continue }
                    units = [UInt16](repeating: 0xFFFF, count: seq * 13)
                    sum = data[o + 13]
                    start = slot
                } else if complete || need == 0 || seq != need || data[o + 13] != sum {
                    need = 0
                    complete = false
                    continue
                }
                for j in 0..<13 {
                    let p = o + fatLFNOffset(j)
                    units[(seq - 1) * 13 + j] = UInt16(data[p]) | UInt16(data[p + 1]) << 8
                }
                need = seq - 1
                complete = need == 0
                continue
            }
            let hadLong = complete && fatChecksum(data, o) == sum
            need = 0
            complete = false
            if attr & fatAttrVolumeID != 0 {
                if labelSlot == nil && attr & fatAttrDirectory == 0 { labelSlot = slot }
                continue
            }
            if b0 == 0x2E {
                if data[o + 1] == 0x2E { dotdot = slot } else { dot = slot }
                continue
            }
            var name = ""
            if hadLong {
                var n = 0
                while n < units.count && units[n] != 0 { n += 1 }
                if n > 0 { name = String(decoding: units[0..<n], as: UTF16.self) }
            }
            if name.isEmpty { name = fatShortDisplay(data, o) }
            if name.isEmpty { continue } // a blank 8.3 name: damaged, skip it
            entries.append(FATDirEntry(name: name, attr: attr, cluster: clusterAt(slot), size: Int(data.le32(o + 28)),
                                       first: hadLong ? start : slot, slot: slot))
        }
    }

    /// Index into `entries` of `name` (case folded).
    func find(_ name: String) -> Int? {
        for (i, e) in entries.enumerated() where fatNamesMatch(e.name, name) { return i }
        return nil
    }

    /// Is `short` used by any 8.3 entry here other than the one at `except`?
    func shortTaken(_ short: [UInt8], except: Int?) -> Bool {
        for slot in 0..<end where slot != except {
            let o = slot * fatSlotSize
            if data[o] == 0xE5 || data[o + 11] & 0x3F == fatAttrLongName || data[o + 11] & fatAttrVolumeID != 0 { continue }
            var same = true
            for i in 0..<11 where data[o + i] != short[i] { same = false; break }
            if same { return true }
        }
        return false
    }

    func isFree(_ slot: Int) -> Bool { slot >= end || data[slot * fatSlotSize] == 0xE5 }

    /// The first run of `count` free slots (deleted, or past the end).
    func freeRun(_ count: Int) -> Int? {
        var run = 0
        for slot in 0..<slots {
            if isFree(slot) {
                run += 1
                if run == count { return slot - count + 1 }
            } else {
                run = 0
            }
        }
        return nil
    }

    var trailingFree: Int {
        var n = 0
        while n < slots && isFree(slots - 1 - n) { n += 1 }
        return n
    }
}

/// One FAT sector in the cache.
final class FATSector {
    var bytes: [UInt8]
    var dirty = false
    init(_ bytes: [UInt8]) { self.bytes = bytes }
}

// Device access with BlockError wrapped.
func fatRead(_ dev: BlockDevice, _ lba: Int, _ count: Int) throws(FATError) -> [UInt8] {
    do throws(BlockError) { return try dev.read(UInt64(lba), count: count) } catch { throw .io(error) }
}

func fatWrite(_ dev: BlockDevice, _ lba: Int, _ bytes: [UInt8]) throws(FATError) {
    do throws(BlockError) { try dev.write(UInt64(lba), bytes) } catch { throw .io(error) }
}

func fatFlush(_ dev: BlockDevice) throws(FATError) {
    do throws(BlockError) { try dev.flush() } catch { throw .io(error) }
}

func fatFSInfoBytes(free: UInt32, next: UInt32) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: sectorSize)
    b.put32(0, fatFSInfoLead)
    b.put32(484, fatFSInfoStruct)
    b.put32(488, free)
    b.put32(492, next)
    b.put32(508, fatFSInfoTrail)
    return b
}

// MARK: The volume

final class FATVolume {
    let device: BlockDevice
    /// From the root directory's label entry, else the boot sector ("" for NO NAME).
    private(set) var label: String
    /// Bytes per cluster.
    let clusterSize: Int
    /// Data clusters (numbered 2 ..< totalClusters + 2).
    let totalClusters: Int
    /// Counted from the FAT at mount, then kept up to date.
    private(set) var freeClusters: Int = 0

    // Geometry from the boot sector.
    let sectorsPerCluster: Int
    let reservedSectors: Int
    let fatCount: Int
    /// Sectors per FAT.
    let fatSectors: Int
    let firstDataSector: Int
    let rootCluster: UInt32
    /// 0 when there is none.
    let fsInfoSector: Int
    let backupBootSector: Int
    /// FAT copy that is read; all copies are written unless mirroring is off.
    let activeFAT: Int
    let mirrorFATs: Bool

    private var nextFree: UInt32 = 2
    private var fatCache: [Int: FATSector] = [:]
    private var fsInfoDirty = false

    private init(device: BlockDevice, label: String, sectorsPerCluster: Int, reservedSectors: Int, fatCount: Int,
                 fatSectors: Int, totalClusters: Int, rootCluster: UInt32, fsInfoSector: Int, backupBootSector: Int,
                 activeFAT: Int, mirrorFATs: Bool) {
        self.device = device
        self.label = label
        self.sectorsPerCluster = sectorsPerCluster
        self.clusterSize = sectorsPerCluster * sectorSize
        self.reservedSectors = reservedSectors
        self.fatCount = fatCount
        self.fatSectors = fatSectors
        self.firstDataSector = reservedSectors + fatCount * fatSectors
        self.totalClusters = totalClusters
        self.rootCluster = rootCluster
        self.fsInfoSector = fsInfoSector
        self.backupBootSector = backupBootSector
        self.activeFAT = activeFAT
        self.mirrorFATs = mirrorFATs
    }

    // MARK: Format and mount

    /// Make an empty FAT32 volume covering the whole device. Sectors per
    /// cluster come from Microsoft's FAT32 table (512 B clusters up to 260
    /// MB, 4 KiB to 8 GB, ...); a device too small for 65,525 clusters gives
    /// .noSpace, a bad label .invalidName.
    static func format(_ dev: BlockDevice, label: String) throws(FATError) {
        guard let labelBytes = fatLabelBytes(label) else { throw .invalidName }
        let total = Int(min(dev.sectorCount, 0xFFFF_FFFF))
        let spc: Int
        switch total {
        case ...66_600: throw .noSpace
        case ...532_480: spc = 1
        case ...16_777_216: spc = 8
        case ...33_554_432: spc = 16
        case ...67_108_864: spc = 32
        default: spc = 64
        }
        let reserved = 32, fats = 2
        let perFATSector = (256 * spc + fats) / 2 // Microsoft's FAT size formula
        let fatSize = (total - reserved + perFATSector - 1) / perFATSector
        let clusters = (total - reserved - fats * fatSize) / spc
        guard clusters >= fatMinClusters, clusters <= 0x0FFF_FFF5, fatSize * 128 >= clusters + 2 else { throw .noSpace }
        let firstData = reserved + fats * fatSize
        let now = fatDateTime(fatClock())

        // Zero the reserved area, both FATs and the root cluster; the boot
        // sector, written last, makes it a volume.
        let chunk = 64
        let zeros = [UInt8](repeating: 0, count: chunk * sectorSize)
        var lba = 0
        while lba < firstData + spc {
            let n = min(chunk, firstData + spc - lba)
            try fatWrite(dev, lba, n == chunk ? zeros : [UInt8](repeating: 0, count: n * sectorSize))
            lba += n
        }
        var fat = [UInt8](repeating: 0, count: sectorSize)
        fat.put32(0, 0x0FFF_FFF8) // media byte F8
        fat.put32(4, 0x0FFF_FFFF)
        fat.put32(8, fatEndOfChain) // the root directory
        for f in 0..<fats { try fatWrite(dev, reserved + f * fatSize, fat) }
        if labelBytes[0] != 0x20 {
            var root = [UInt8](repeating: 0, count: sectorSize)
            root.put(0, labelBytes)
            root[11] = fatAttrVolumeID
            root.put16(22, now.time)
            root.put16(24, now.date)
            try fatWrite(dev, firstData, root)
        }
        let info = fatFSInfoBytes(free: UInt32(clusters - 1), next: 3)
        try fatWrite(dev, 1, info)
        try fatWrite(dev, 7, info)

        var b = [UInt8](repeating: 0, count: sectorSize)
        b.put(0, [0xEB, 0x58, 0x90])
        b.put(3, Array("WIFFER  ".utf8))
        b.put16(11, sectorSize)
        b[13] = UInt8(spc)
        b.put16(14, reserved)
        b[16] = UInt8(fats)
        b[21] = 0xF8
        b.put16(24, 63) // sectors per track, heads: nominal
        b.put16(26, 255)
        b.put32(32, UInt32(total))
        b.put32(36, UInt32(fatSize))
        b.put32(44, 2) // root cluster
        b.put16(48, 1) // FSInfo
        b.put16(50, 6) // backup boot sector
        b[64] = 0x80
        b[66] = 0x29
        b.put32(67, UInt32(now.date) << 16 | UInt32(now.time)) // volume serial
        b.put(71, labelBytes[0] == 0x20 ? Array("NO NAME    ".utf8) : labelBytes)
        b.put(82, Array("FAT32   ".utf8))
        b.put(90, [0xCD, 0x18, 0xEB, 0xFE]) // not bootable: int 18h, then spin
        b[510] = 0x55
        b[511] = 0xAA
        try fatWrite(dev, 6, b)
        try fatWrite(dev, 0, b)
        try fatFlush(dev)
    }

    /// Open the FAT32 volume on `dev`. The boot sector must describe 512-byte
    /// sectors, a power-of-two cluster size and at least 65,525 clusters
    /// (FAT32 is told by its cluster count, not the type string): otherwise
    /// .notFAT32. The free count is counted from the FAT.
    static func mount(_ dev: BlockDevice) throws(FATError) -> FATVolume {
        guard dev.sectorCount > 0 else { throw .notFAT32 }
        let b = try fatRead(dev, 0, 1)
        guard b[510] == 0x55, b[511] == 0xAA, b.le16(11) == sectorSize else { throw .notFAT32 }
        let spc = Int(b[13]), reserved = b.le16(14), fats = Int(b[16])
        guard spc > 0, spc & (spc - 1) == 0, reserved >= 1, fats >= 1, fats <= 4,
              b.le16(17) == 0, b.le16(22) == 0, b.le16(42) == 0 else { throw .notFAT32 }
        let total = b.le16(19) != 0 ? b.le16(19) : Int(b.le32(32))
        let fatSize = Int(b.le32(36))
        let firstData = reserved + fats * fatSize
        guard UInt64(total) <= dev.sectorCount, fatSize > 0, firstData < total else { throw .notFAT32 }
        let clusters = (total - firstData) / spc
        guard clusters >= fatMinClusters, clusters <= 0x0FFF_FFF5, fatSize * 128 >= clusters + 2 else { throw .notFAT32 }
        let ext = b.le16(40)
        let mirror = ext & 0x80 == 0
        let active = mirror ? 0 : ext & 0x0F
        let root = b.le32(44)
        guard active < fats, root >= 2, Int(root) < clusters + 2 else { throw .notFAT32 }
        let info = b.le16(48), backup = b.le16(50)
        let v = FATVolume(device: dev, label: fatLabelString(b, 71), sectorsPerCluster: spc, reservedSectors: reserved,
                          fatCount: fats, fatSectors: fatSize, totalClusters: clusters, rootCluster: root,
                          fsInfoSector: info >= 1 && info < reserved ? info : 0,
                          backupBootSector: backup >= 1 && backup < reserved ? backup : 0,
                          activeFAT: active, mirrorFATs: mirror)
        try v.recount()
        let rootDir = try v.loadDir(root)
        if let s = rootDir.labelSlot { v.label = fatLabelString(rootDir.data, s * fatSlotSize) }
        return v
    }

    // MARK: Reading

    /// The entries of the directory at `path` ([] = the root), in disk order.
    func list(_ path: [String]) throws(FATError) -> [FATEntry] {
        let dir = try directory(path[...])
        var out: [FATEntry] = []
        for e in dir.entries { out.append(FATEntry(name: e.name, isDirectory: e.isDirectory, size: e.isDirectory ? 0 : e.size)) }
        trimCache()
        return out
    }

    func read(_ path: [String]) throws(FATError) -> [UInt8] {
        guard !path.isEmpty else { throw .isADirectory }
        let (dir, name) = try parent(of: path)
        guard let i = dir.find(name) else { throw .notFound }
        let e = dir.entries[i]
        guard !e.isDirectory else { throw .isADirectory }
        return try contents(of: e)
    }

    /// A file entry's bytes (for read, and for the VFS loading a whole
    /// volume at mount without re-walking each file's path from the root).
    func contents(of e: FATDirEntry) throws(FATError) -> [UInt8] {
        defer { trimCache() }
        guard e.size > 0 else { return [] }
        let need = (e.size + clusterSize - 1) / clusterSize
        let clusters = try chain(e.cluster)
        guard clusters.count >= need else { throw .corrupt }
        var out = try readClusters(clusters[0..<need])
        out.removeLast(out.count - e.size)
        return out
    }

    // MARK: Writing

    /// Create or replace a file (an existing name keeps its spelling).
    /// Replacing needs room for the new contents while the old are still
    /// there (crash safety), so it can fail with .noSpace even if the new
    /// contents would fit in the old clusters.
    func write(_ path: [String], _ bytes: [UInt8]) throws(FATError) {
        try store(path, size: bytes.count, data: bytes)
    }

    /// Selftest helper: like write, but the clusters are only allocated, not
    /// written (the file holds whatever was on disk). Fills a volume cheaply.
    func reserve(_ path: [String], size: Int) throws(FATError) {
        try store(path, size: size, data: nil)
    }

    private func store(_ path: [String], size: Int, data: [UInt8]?) throws(FATError) {
        guard size <= 0xFFFF_FFFF else { throw .noSpace }
        try update { () throws(FATError) in
            var (dir, name) = try parent(of: path)
            let n = (size + clusterSize - 1) / clusterSize
            var existing: FATDirEntry? = nil
            var plan: FATNamePlan? = nil
            var grow = 0
            if let i = dir.find(name) {
                existing = dir.entries[i]
                guard !dir.entries[i].isDirectory else { throw .isADirectory }
            } else {
                let p = try namePlan(name, in: dir, except: nil)
                grow = try growthNeeded(dir, p.slots)
                plan = p
            }
            guard n + grow <= freeClusters else { throw .noSpace }
            let clusters = try allocateChain(n)
            let first = clusters.first ?? 0
            do throws(FATError) {
                if let data { try writeClusters(clusters, data) }
                if n > 0 {
                    try flushFAT()
                    try flushDevice()
                }
                if let e = existing {
                    // Commit: the entry now names the new chain.
                    let o = e.slot * fatSlotSize
                    let now = fatDateTime(fatClock())
                    dir.data[o + 11] |= fatAttrArchive
                    dir.data.put16(o + 18, now.date)
                    dir.data.put16(o + 20, Int(first >> 16))
                    dir.data.put16(o + 22, now.time)
                    dir.data.put16(o + 24, now.date)
                    dir.data.put16(o + 26, Int(first & 0xFFFF))
                    dir.data.put32(o + 28, UInt32(size))
                    try writeDirSector(dir, o / sectorSize)
                } else if let plan {
                    try addEntry(&dir, plan, template: entryTemplate(attr: fatAttrArchive, cluster: first, size: size))
                }
            } catch {
                if n > 0 { // best effort: give the new clusters back
                    try? freeChain(first)
                    try? flushFAT()
                }
                throw error
            }
            if let e = existing, e.cluster != 0 { try? freeChain(e.cluster) }
        }
    }

    /// A new empty directory, with "." and ".." (0 for the root's children).
    func mkdir(_ path: [String]) throws(FATError) {
        try update { () throws(FATError) in
            var (dir, name) = try parent(of: path)
            guard dir.find(name) == nil else { throw .exists }
            let plan = try namePlan(name, in: dir, except: nil)
            let grow = try growthNeeded(dir, plan.slots)
            guard 1 + grow <= freeClusters else { throw .noSpace }
            let c = try allocateChain(1)[0]
            do throws(FATError) {
                var block = [UInt8](repeating: 0, count: clusterSize)
                var dot = entryTemplate(attr: fatAttrDirectory, cluster: c, size: 0)
                dot.put(0, Array(".          ".utf8))
                block.put(0, dot)
                var dotdot = entryTemplate(attr: fatAttrDirectory, cluster: dir.cluster == rootCluster ? 0 : dir.cluster, size: 0)
                dotdot.put(0, Array("..         ".utf8))
                block.put(fatSlotSize, dotdot)
                try fatWrite(device, clusterLBA(c), block)
                try flushFAT()
                try flushDevice()
                try addEntry(&dir, plan, template: entryTemplate(attr: fatAttrDirectory, cluster: c, size: 0))
            } catch {
                try? freeChain(c)
                try? flushFAT()
                throw error
            }
        }
    }

    /// Remove a file or an empty directory.
    func remove(_ path: [String]) throws(FATError) {
        try update { () throws(FATError) in
            var (dir, name) = try parent(of: path)
            guard let i = dir.find(name) else { throw .notFound }
            let e = dir.entries[i]
            if e.isDirectory {
                guard try loadDir(e.cluster).entries.isEmpty else { throw .notEmpty }
            }
            try deleteEntry(&dir, e)
            if e.cluster != 0 { try? freeChain(e.cluster) }
        }
    }

    /// Move `from` to exactly `to`, whose parent must exist and which must
    /// not exist (a change of case only is allowed). Within one directory
    /// the entry is rewritten in place when the new name needs no more
    /// slots; otherwise the new entry is written, then the old one deleted.
    /// A moved directory gets its ".." updated. Moving a directory into
    /// itself gives .invalidName.
    func rename(_ from: [String], to: [String]) throws(FATError) {
        guard let oldName = from.last, let newName = to.last else { throw .invalidName }
        try update { () throws(FATError) in
            var src = try directory(from.dropLast())
            guard let si = src.find(oldName) else { throw .notFound }
            let e = src.entries[si]
            var dst = try loadDir(rootCluster)
            var onPath: [UInt32] = [rootCluster]
            for name in to.dropLast() {
                guard let i = dst.find(name) else { throw .notFound }
                guard dst.entries[i].isDirectory else { throw .notADirectory }
                dst = try loadDir(dst.entries[i].cluster)
                onPath.append(dst.cluster)
            }
            if e.isDirectory && onPath.contains(e.cluster) { throw .invalidName }
            let sameDir = dst.cluster == src.cluster
            if let ti = dst.find(newName) {
                guard sameDir && dst.entries[ti].slot == e.slot else { throw .exists }
                if e.name == newName { return } // renamed to itself
            }
            let o = e.slot * fatSlotSize
            let template = Array(src.data[o..<(o + fatSlotSize)])
            if sameDir {
                let inPlace = try namePlan(newName, in: src, except: e.slot)
                if inPlace.slots <= e.slot - e.first + 1 {
                    // In place: the new run ends at the old 8.3 slot.
                    let start = e.slot - inPlace.slots + 1
                    for s in e.first..<start { src.data[s * fatSlotSize] = 0xE5 }
                    src.data.put(start * fatSlotSize, inPlace.entryBytes(template))
                    for s in (e.first * fatSlotSize / sectorSize)...(o / sectorSize) { try writeDirSector(src, s) }
                    return
                }
                // Both entries exist for a moment: the short names must differ.
                let plan = try namePlan(newName, in: src, except: nil)
                guard try growthNeeded(src, plan.slots) <= freeClusters else { throw .noSpace }
                try addEntry(&src, plan, template: template)
                try? deleteEntry(&src, e)
                return
            }
            let plan = try namePlan(newName, in: dst, except: nil)
            guard try growthNeeded(dst, plan.slots) <= freeClusters else { throw .noSpace }
            try addEntry(&dst, plan, template: template)
            if e.isDirectory { try? setDotDot(e.cluster, dst.cluster == rootCluster ? 0 : dst.cluster) }
            try? deleteEntry(&src, e)
        }
    }

    /// Write FSInfo, then flush the device.
    func sync() throws(FATError) {
        try flushFAT()
        try writeFSInfo()
        try flushDevice()
    }

    // MARK: Checking

    /// fsck: walks every directory from the root and compares the FAT with
    /// what the entries reference. Reports broken chains, cross-links (a
    /// cluster in two chains, or a loop), files whose size doesn't match
    /// their chain, bad "." / ".." entries, lost clusters (allocated but
    /// unreferenced), FSInfo's free count against the real one, and the
    /// backup boot sector. [] when clean.
    func check() -> [String] {
        var problems: [String] = []
        func note(_ s: String) { if problems.count < 64 { problems.append(s) } }
        let entries = totalClusters + 2
        var fat: [UInt32] = []
        fat.reserveCapacity(entries)
        do throws(FATError) { try scanFAT { _, v in fat.append(v) } } catch { return ["FAT unreadable: " + error.message] }
        var actualFree = 0
        for c in 2..<entries where fat[c] == 0 { actualFree += 1 }

        if backupBootSector != 0 {
            let boot = try? fatRead(device, 0, 1), backup = try? fatRead(device, backupBootSector, 1)
            if boot == nil || boot != backup { note("backup boot sector differs from sector 0") }
        }
        if fsInfoSector != 0 {
            if let info = try? fatRead(device, fsInfoSector, 1) {
                if info.le32(0) != fatFSInfoLead || info.le32(484) != fatFSInfoStruct || info.le32(508) != fatFSInfoTrail {
                    note("FSInfo signatures bad")
                } else if info.le32(488) != 0xFFFF_FFFF && Int(info.le32(488)) != actualFree {
                    note("FSInfo free count \(info.le32(488)), actual \(actualFree)")
                }
            } else {
                note("FSInfo unreadable")
            }
        }
        if freeClusters != actualFree { note("free count \(freeClusters) in memory, actual \(actualFree)") }

        var owned = [Bool](repeating: false, count: entries)
        /// Follow and claim a chain: nil (noted) if it's broken or crosses another.
        func claim(_ start: UInt32, _ what: String) -> [UInt32]? {
            var out: [UInt32] = []
            var c = start
            while true {
                guard c >= 2, Int(c) < entries else { note("\(what): bad cluster \(c)"); return nil }
                guard !owned[Int(c)] else { note("\(what): cross-linked at cluster \(c)"); return nil }
                owned[Int(c)] = true
                out.append(c)
                let next = fat[Int(c)]
                if next >= fatEndMin { return out }
                guard next != 0 else { note("\(what): chain runs into free cluster after \(c)"); return nil }
                c = next
            }
        }
        var stack: [(UInt32, UInt32, String)] = [(rootCluster, 0, "/")]
        while let (cluster, parentCluster, path) = stack.popLast() {
            guard let clusters = claim(cluster, path) else { continue }
            guard clusters.count * clusterSize / fatSlotSize <= fatMaxDirSlots else { note("\(path): directory too large"); continue }
            guard let data = try? readClusters(clusters[...]) else { note("\(path): unreadable"); continue }
            let dir = FATDir(cluster: cluster, chain: clusters, data: data)
            if cluster != rootCluster {
                let up = parentCluster == rootCluster ? 0 : parentCluster
                if dir.dot.map({ dir.clusterAt($0) }) != cluster || dir.dotdot.map({ dir.clusterAt($0) }) != up {
                    note("\(path): bad . or .. entry")
                }
            }
            for e in dir.entries {
                if e.isDirectory {
                    stack.append((e.cluster, cluster, path + e.name + "/"))
                } else if e.size == 0 {
                    if e.cluster != 0 {
                        note("\(path)\(e.name): empty file holds clusters")
                        _ = claim(e.cluster, path + e.name)
                    }
                } else if let ch = claim(e.cluster, path + e.name) {
                    let need = (e.size + clusterSize - 1) / clusterSize
                    if ch.count != need { note("\(path)\(e.name): size \(e.size) needs \(need) clusters, chain has \(ch.count)") }
                }
            }
        }
        var lost = 0
        for c in 2..<entries where fat[c] != 0 && fat[c] != fatBadCluster && !owned[c] { lost += 1 }
        if lost > 0 { note("lost clusters: \(lost)") }
        return problems
    }

    // MARK: Operations: wrapper, recovery

    /// Run a mutating operation. If it throws, nothing it did is kept in
    /// memory (unflushed FAT changes are dropped, the free count re-read);
    /// otherwise the FAT, FSInfo and the device are flushed.
    private func update(_ body: () throws(FATError) -> Void) throws(FATError) {
        do throws(FATError) {
            try body()
        } catch {
            abandon()
            throw error
        }
        do throws(FATError) {
            try flushFAT()
            if fsInfoDirty { try writeFSInfo() }
            try flushDevice()
        } catch {
            abandon() // after the commit point: at worst leaked clusters
        }
    }

    private func abandon() {
        fatCache = [:]
        try? recount()
        fsInfoDirty = true
    }

    private func trimCache() {
        if fatCache.count > 512 {
            for (_, s) in fatCache where s.dirty { return }
            fatCache = [:]
        }
    }

    private func flushDevice() throws(FATError) { try fatFlush(device) }

    private func writeFSInfo() throws(FATError) {
        guard fsInfoSector != 0 else { return }
        try fatWrite(device, fsInfoSector, fatFSInfoBytes(free: UInt32(freeClusters), next: nextFree))
        fsInfoDirty = false
    }

    // MARK: The FAT

    private var fatStart: Int { reservedSectors + activeFAT * fatSectors }

    func validCluster(_ c: UInt32) -> Bool { c >= 2 && Int(c) < totalClusters + 2 }

    private func fatSector(_ n: Int) throws(FATError) -> FATSector {
        if let s = fatCache[n] { return s }
        let s = FATSector(try fatRead(device, fatStart + n, 1))
        fatCache[n] = s
        return s
    }

    func fatEntry(_ c: UInt32) throws(FATError) -> UInt32 {
        guard validCluster(c) else { throw .corrupt }
        return try fatSector(Int(c) / 128).bytes.le32(Int(c) % 128 * 4) & fatEntryMask
    }

    private func setFATEntry(_ c: UInt32, _ v: UInt32) throws(FATError) {
        guard validCluster(c) else { throw .corrupt }
        let s = try fatSector(Int(c) / 128)
        let i = Int(c) % 128 * 4
        s.bytes.put32(i, s.bytes.le32(i) & ~fatEntryMask | v & fatEntryMask) // keep the top 4 bits
        s.dirty = true
    }

    /// Write dirty FAT sectors (runs of adjacent ones together) to every copy.
    private func flushFAT() throws(FATError) {
        var dirty: [Int] = []
        for (n, s) in fatCache where s.dirty { dirty.append(n) }
        guard !dirty.isEmpty else { return }
        dirty.sort()
        var i = 0
        while i < dirty.count {
            var j = i + 1
            while j < dirty.count && dirty[j] == dirty[j - 1] + 1 && j - i < 64 { j += 1 }
            var run: [UInt8] = []
            for k in i..<j { run += fatCache[dirty[k]]!.bytes }
            for f in 0..<fatCount where mirrorFATs || f == activeFAT {
                try fatWrite(device, reservedSectors + f * fatSectors + dirty[i], run)
            }
            for k in i..<j { fatCache[dirty[k]]!.dirty = false }
            i = j
        }
        trimCache()
    }

    /// Call `body(cluster, entry)` for every FAT entry 0 ..< totalClusters + 2,
    /// reading the FAT from disk (not the cache) in 32 KiB pieces.
    private func scanFAT(_ body: (Int, UInt32) -> Void) throws(FATError) {
        let entries = totalClusters + 2
        let sectors = (entries + 127) / 128
        var sector = 0
        while sector < sectors {
            let n = min(64, sectors - sector)
            let bytes = try fatRead(device, fatStart + sector, n)
            let first = sector * 128
            let count = min(n * 128, entries - first)
            bytes.withUnsafeBytes { buf in
                for i in 0..<count { body(first + i, buf.load(fromByteOffset: i * 4, as: UInt32.self) & fatEntryMask) }
            }
            sector += n
        }
    }

    /// Count free clusters from the on-disk FAT; the first becomes the
    /// allocation hint.
    private func recount() throws(FATError) {
        var free = 0
        var first = 0
        try scanFAT { c, v in
            if c >= 2 && v == 0 {
                if free == 0 { first = c }
                free += 1
            }
        }
        freeClusters = free
        nextFree = UInt32(first >= 2 ? first : 2)
    }

    /// The chain from `start`: .corrupt if it leaves the volume, runs into a
    /// free or bad cluster, or is longer than `limit` (or the volume: a loop).
    func chain(_ start: UInt32, limit: Int? = nil) throws(FATError) -> [UInt32] {
        let most = min(limit ?? totalClusters, totalClusters)
        var out: [UInt32] = []
        var c = start
        while true {
            guard validCluster(c), out.count < most else { throw .corrupt }
            out.append(c)
            let next = try fatEntry(c)
            if next >= fatEndMin { return out }
            c = next
        }
    }

    /// `n` free clusters linked into a chain ending in end-of-chain (in the
    /// cache: the caller flushes).
    func allocateChain(_ n: Int) throws(FATError) -> [UInt32] {
        guard n > 0 else { return [] }
        guard n <= freeClusters else { throw .noSpace }
        var out: [UInt32] = []
        out.reserveCapacity(n)
        var c = Int(nextFree), scanned = 0
        while out.count < n {
            if c < 2 || c >= totalClusters + 2 { c = 2 }
            guard scanned < totalClusters else { throw .noSpace } // the count was wrong
            if try fatEntry(UInt32(c)) == 0 { out.append(UInt32(c)) }
            c += 1
            scanned += 1
        }
        for i in 0..<n { try setFATEntry(out[i], i + 1 < n ? out[i + 1] : fatEndOfChain) }
        freeClusters -= n
        nextFree = UInt32(c < totalClusters + 2 ? c : 2)
        fsInfoDirty = true
        return out
    }

    /// Free the chain from `start` (in the cache). Stops quietly at a damaged
    /// link: freeing is cleanup after a commit.
    private func freeChain(_ start: UInt32) throws(FATError) {
        var c = start, count = 0
        while validCluster(c) && count < totalClusters {
            let next = try fatEntry(c)
            guard next != 0 else { break }
            try setFATEntry(c, 0)
            freeClusters += 1
            count += 1
            fsInfoDirty = true
            if c < nextFree { nextFree = c }
            if next >= fatEndMin { break }
            c = next
        }
    }

    // MARK: Clusters

    func clusterLBA(_ c: UInt32) -> Int { firstDataSector + (Int(c) - 2) * sectorsPerCluster }

    /// The bytes of `clusters`, reading runs of adjacent ones together.
    private func readClusters(_ clusters: ArraySlice<UInt32>) throws(FATError) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(clusters.count * clusterSize)
        var i = clusters.startIndex
        while i < clusters.endIndex {
            var j = i + 1
            while j < clusters.endIndex && clusters[j] == clusters[j - 1] &+ 1 && (j - i) * sectorsPerCluster < 128 { j += 1 }
            out += try fatRead(device, clusterLBA(clusters[i]), (j - i) * sectorsPerCluster)
            i = j
        }
        return out
    }

    /// `bytes` into `clusters` in order, the last one zero padded.
    private func writeClusters(_ clusters: [UInt32], _ bytes: [UInt8]) throws(FATError) {
        var i = 0
        while i < clusters.count {
            var j = i + 1
            while j < clusters.count && clusters[j] == clusters[j - 1] &+ 1 && (j - i) * sectorsPerCluster < 128 { j += 1 }
            let from = i * clusterSize, to = j * clusterSize
            var chunk = Array(bytes[min(from, bytes.count)..<min(to, bytes.count)])
            if chunk.count < to - from { chunk += [UInt8](repeating: 0, count: to - from - chunk.count) }
            try fatWrite(device, clusterLBA(clusters[i]), chunk)
            i = j
        }
    }

    // MARK: Directories

    func loadDir(_ cluster: UInt32) throws(FATError) -> FATDir {
        let clusters = try chain(cluster, limit: fatMaxDirSlots * fatSlotSize / clusterSize)
        return FATDir(cluster: cluster, chain: clusters, data: try readClusters(clusters[...]))
    }

    /// The directory at `path` ([] = the root).
    func directory(_ path: ArraySlice<String>) throws(FATError) -> FATDir {
        var dir = try loadDir(rootCluster)
        for name in path {
            guard let i = dir.find(name) else { throw .notFound }
            guard dir.entries[i].isDirectory else { throw .notADirectory }
            dir = try loadDir(dir.entries[i].cluster)
        }
        return dir
    }

    private func parent(of path: [String]) throws(FATError) -> (FATDir, String) {
        guard let name = path.last else { throw .invalidName }
        return (try directory(path.dropLast()), name)
    }

    private func namePlan(_ name: String, in dir: FATDir, except: Int?) throws(FATError) -> FATNamePlan {
        guard fatValidName(name) else { throw .invalidName }
        if let p = fatPlainShortName(name), !dir.shortTaken(p.short, except: except) {
            return FATNamePlan(short: p.short, caseBits: p.caseBits, long: nil)
        }
        let basis = fatShortBasis(name)
        for n in 1...999_999 {
            let short = fatNumberedShortName(basis.base, basis.ext, n)
            if !dir.shortTaken(short, except: except) { return FATNamePlan(short: short, caseBits: 0, long: Array(name.utf16)) }
        }
        throw .noSpace
    }

    /// Clusters `dir` must grow by to fit `slots` more entries.
    private func growthNeeded(_ dir: FATDir, _ slots: Int) throws(FATError) -> Int {
        if dir.freeRun(slots) != nil { return 0 }
        let perCluster = clusterSize / fatSlotSize
        let grow = (slots - dir.trailingFree + perCluster - 1) / perCluster
        guard dir.slots + grow * perCluster <= fatMaxDirSlots else { throw .noSpace }
        return grow
    }

    /// Append a zeroed cluster to `dir`: written, marked end-of-chain, and
    /// only then linked in.
    private func growDir(_ dir: inout FATDir) throws(FATError) {
        guard dir.slots + clusterSize / fatSlotSize <= fatMaxDirSlots, let last = dir.chain.last else { throw .noSpace }
        let c = try allocateChain(1)[0]
        let zeros = [UInt8](repeating: 0, count: clusterSize)
        try fatWrite(device, clusterLBA(c), zeros)
        try flushFAT()
        try setFATEntry(last, c)
        try flushFAT()
        dir.chain.append(c)
        dir.data += zeros
        dir.parse()
    }

    private func writeDirSector(_ dir: FATDir, _ s: Int) throws(FATError) {
        let lba = clusterLBA(dir.chain[s / sectorsPerCluster]) + s % sectorsPerCluster
        try fatWrite(device, lba, Array(dir.data[(s * sectorSize)..<((s + 1) * sectorSize)]))
    }

    /// Write `plan`'s entries into free slots of `dir` (growing it if need
    /// be), the 8.3 entry's sector last: that write is the commit.
    private func addEntry(_ dir: inout FATDir, _ plan: FATNamePlan, template: [UInt8]) throws(FATError) {
        while dir.freeRun(plan.slots) == nil { try growDir(&dir) }
        guard let start = dir.freeRun(plan.slots) else { throw .noSpace }
        let after = start + plan.slots
        // Past the old end, the slot after the new entries must end the
        // directory (whatever followed the 0x00 marker is free garbage).
        if after < dir.slots && after > dir.end && dir.data[after * fatSlotSize] != 0 {
            dir.data[after * fatSlotSize] = 0
            try writeDirSector(dir, after * fatSlotSize / sectorSize)
        }
        dir.data.put(start * fatSlotSize, plan.entryBytes(template))
        for s in (start * fatSlotSize / sectorSize)...((after * fatSlotSize - 1) / sectorSize) { try writeDirSector(dir, s) }
        dir.parse()
    }

    /// Mark `e`'s slots deleted, the 8.3 entry's sector first (the commit);
    /// a failure on the long-name sectors after it only leaves orphans.
    private func deleteEntry(_ dir: inout FATDir, _ e: FATDirEntry) throws(FATError) {
        for s in e.first...e.slot { dir.data[s * fatSlotSize] = 0xE5 }
        let last = e.slot * fatSlotSize / sectorSize, first = e.first * fatSlotSize / sectorSize
        try writeDirSector(dir, last)
        if first < last { for s in first..<last { try? writeDirSector(dir, s) } }
        dir.parse()
    }

    private func setDotDot(_ dirCluster: UInt32, _ parent: UInt32) throws(FATError) {
        var d = try loadDir(dirCluster)
        guard let s = d.dotdot else { return }
        d.data.put16(s * fatSlotSize + 20, Int(parent >> 16))
        d.data.put16(s * fatSlotSize + 26, Int(parent & 0xFFFF))
        try writeDirSector(d, s * fatSlotSize / sectorSize)
    }

    /// A 32-byte 8.3 entry (name left blank) stamped with the clock.
    private func entryTemplate(attr: UInt8, cluster: UInt32, size: Int) -> [UInt8] {
        let now = fatDateTime(fatClock())
        var e = [UInt8](repeating: 0, count: fatSlotSize)
        e[11] = attr
        e.put16(14, now.time)
        e.put16(16, now.date)
        e.put16(18, now.date)
        e.put16(20, Int(cluster >> 16))
        e.put16(22, now.time)
        e.put16(24, now.date)
        e.put16(26, Int(cluster & 0xFFFF))
        e.put32(28, UInt32(size))
        return e
    }
}
