// Phases W and X selftests: FAT32 format/mount/geometry, hand-built
// directories (LFN, 8.3 case bits, deleted and end markers), damaged boot
// sectors and chains, a scripted session checked against a RAM FileSystem
// model, a full disk, power cuts (failWritesAfter) during an overwrite, long
// and mixed-case names, timestamps. All on sparse RamDisks. Called from
// runSelfTests.

/// 34 MiB: just over FAT32's minimum at 512-byte clusters (68,520 clusters),
/// so check() and mount, which read the whole FAT, stay quick.
let fatSmallSectors: UInt64 = 69_632

/// Does `body` throw exactly `want`?
func fatFails<R>(_ want: FATError, _ body: () throws(FATError) -> R) -> Bool {
    do throws(FATError) {
        _ = try body()
        return false
    } catch {
        return error == want
    }
}

func fatPattern(_ count: Int, _ seed: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    for i in 0..<count { out[i] = UInt8(truncatingIfNeeded: i &* 31 &+ seed &* 7 &+ (i >> 8)) }
    return out
}

/// A disk holding a fresh volume, and the volume mounted.
func fatFresh(_ sectors: UInt64 = fatSmallSectors, label: String = "TEST") -> (RamDisk, FATVolume)? {
    let d = RamDisk(sectors: sectors)
    guard (try? FATVolume.format(d, label: label)) != nil, let v = try? FATVolume.mount(d) else { return nil }
    return (d, v)
}

/// The same sectors on a new device (copy-on-write: cheap until written).
func fatCopy(_ d: RamDisk) -> RamDisk {
    let c = RamDisk(name: d.name, sectors: d.sectorCount)
    c.sectors = d.sectors
    return c
}

/// Set FAT entry `c` in every copy, behind the volume's back.
func fatPoke(_ d: RamDisk, _ v: FATVolume, _ c: UInt32, _ value: UInt32) {
    for f in 0..<v.fatCount {
        let lba = UInt64(v.reservedSectors + f * v.fatSectors + Int(c) / 128)
        guard var s = try? d.read(lba, count: 1) else { continue }
        s.put32(Int(c) % 128 * 4, value)
        _ = try? d.write(lba, s)
    }
}

/// Report check() problems on serial (to explain a FAIL).
func fatClean(_ v: FATVolume, _ what: String) -> Bool {
    let problems = v.check()
    for p in problems { print("    fat: \(what): \(p)") }
    return problems.isEmpty
}

// MARK: Phase W

@inline(never)
func fatFormatGeometry() -> Bool {
    guard let (d, v) = fatFresh(1 << 17, label: "Wiffer"), // 64 MiB
          let boot = try? d.read(0, count: 1), let info = try? d.read(1, count: 1) else { return false }
    // Microsoft's formula: FAT = ceil((131072 - 32) / 129) - 1 = 1016 sectors,
    // leaving 131072 - 32 - 2 * 1016 = 129,008 clusters; the root has one.
    let geometry = v.clusterSize == 512 && v.totalClusters == 129_008 && v.freeClusters == 129_007
        && v.fatSectors == 1016 && v.reservedSectors == 32 && v.fatCount == 2 && v.rootCluster == 2
        && v.label == "WIFFER" && (try? v.list([])) == []
    let sectors = boot[510] == 0x55 && boot[511] == 0xAA && (try? d.read(6, count: 1)) == boot
        && info.le32(0) == fatFSInfoLead && info.le32(488) == 129_007 && (try? d.read(7, count: 1)) == info
        && boot.le16(11) == 512 && boot.le32(32) == 1 << 17
    // 293 MiB: 4 KiB clusters by the table.
    let big = fatFresh(600_000).map { $0.1.clusterSize == 4096 && $0.1.totalClusters == 74_849 } == true
    let refused = fatFails(.noSpace) { () throws(FATError) in try FATVolume.format(RamDisk(sectors: 60_000), label: "") }
        && fatFails(.invalidName) { () throws(FATError) in try FATVolume.format(RamDisk(sectors: fatSmallSectors), label: "TWELVE CHARS") }
        && fatFails(.invalidName) { () throws(FATError) in try FATVolume.format(RamDisk(sectors: fatSmallSectors), label: "a:b") }
    let unlabelled = fatFresh(label: "").map { $0.1.label == "" } == true
    return geometry && sectors && big && refused && unlabelled && fatClean(v, "format")
}

/// A 32-byte 8.3 entry, built by hand.
func fatRawShort(_ name: StaticString, attr: UInt8, cluster: UInt32 = 0, size: UInt32 = 0, caseBits: UInt8 = 0) -> [UInt8] {
    var e = [UInt8](repeating: 0, count: 32)
    e.put(0, bytes(name))
    e[11] = attr
    e[12] = caseBits
    e.put16(20, Int(cluster >> 16))
    e.put16(26, Int(cluster & 0xFFFF))
    e.put32(28, size)
    return e
}

/// The LFN entries for `name`, in disk order, carrying `checksum`.
func fatRawLFN(_ name: String, checksum: UInt8) -> [UInt8] {
    var units = Array(name.utf16)
    units.append(0)
    while units.count % 13 != 0 { units.append(0xFFFF) }
    let count = units.count / 13
    var out: [UInt8] = []
    for seq in stride(from: count, through: 1, by: -1) {
        var e = [UInt8](repeating: 0, count: 32)
        e[0] = UInt8(seq) | (seq == count ? 0x40 : 0)
        e[11] = 0x0F
        e[13] = checksum
        let part = Array(units[((seq - 1) * 13)..<(seq * 13)])
        for j in 0..<5 { e.put16(1 + 2 * j, Int(part[j])) }
        for j in 0..<6 { e.put16(14 + 2 * j, Int(part[5 + j])) }
        for j in 0..<2 { e.put16(28 + 2 * j, Int(part[11 + j])) }
        out += e
    }
    return out
}

func fatRawChecksum(_ short: StaticString) -> UInt8 {
    var sum: UInt8 = 0
    for b in bytes(short) { sum = (sum >> 1 | sum << 7) &+ b }
    return sum
}

/// A root directory written sector by sector: label, case bits, LFN runs
/// (one across the cluster boundary), a bad checksum, an orphan, deleted
/// entries, a subdirectory, and garbage after the end marker.
@inline(never)
func fatHandBuiltDirectory() -> Bool {
    guard let (d, v0) = fatFresh() else { return false }
    let longName = "A long file name.text"
    let crossing = "This long name crosses a cluster boundary.txt" // 45 units: 4 LFN entries
    var root: [UInt8] = []
    root += fatRawShort("HANDMADE   ", attr: 0x08)                                     // 0
    root += fatRawShort("README  TXT", attr: 0x20, cluster: 5, size: 11, caseBits: 0x18) // 1
    root += fatRawLFN(longName, checksum: fatRawChecksum("ALONGF~1TEX"))               // 2-3
    root += fatRawShort("ALONGF~1TEX", attr: 0x20)                                     // 4
    root += fatRawLFN("Bad sum", checksum: fatRawChecksum("BADSUM     ") ^ 0x55)       // 5
    root += fatRawShort("BADSUM     ", attr: 0x20)                                     // 6
    var deleted = fatRawLFN("gone", checksum: fatRawChecksum("ELETED  TXT"))
    deleted[0] = 0xE5
    root += deleted                                                                    // 7
    root += [0xE5] + fatRawShort("ELETED  TXT", attr: 0x20)[1...]                      // 8
    root += fatRawShort("SUBDIR     ", attr: 0x10, cluster: 4)                         // 9
    root += fatRawLFN("orphan", checksum: fatRawChecksum("ORPHAN  TXT"))               // 10: no 8.3 follows
    root += [0xE5] + fatRawShort("ORPHAN  TXT", attr: 0x20)[1...]                      // 11
    root += [0xE5] + fatRawShort("DELETED2   ", attr: 0x20)[1...]                      // 12
    root += fatRawLFN(crossing, checksum: fatRawChecksum("THISLO~1TXT"))               // 13-16
    root += fatRawShort("THISLO~1TXT", attr: 0x20)                                     // 17
    root += [UInt8](repeating: 0, count: 32)                                           // 18: end
    root += fatRawShort("GARBAGE TXT", attr: 0x20)                                     // 19: ignored
    root += [UInt8](repeating: 0, count: 1024 - root.count)
    var sub: [UInt8] = []
    sub += fatRawShort(".          ", attr: 0x10, cluster: 4)
    sub += fatRawShort("..         ", attr: 0x10, cluster: 0)
    sub += fatRawShort("INNER   BIN", attr: 0x20, caseBits: 0x08)
    sub += [UInt8](repeating: 0, count: 512 - sub.count)
    var file = bytes("hello, fat\n")
    file += [UInt8](repeating: 0, count: 512 - file.count)
    var fat = [UInt8](repeating: 0, count: 512)
    for (i, e) in [0x0FFF_FFF8, 0x0FFF_FFFF, 3, 0x0FFF_FFFF, 0x0FFF_FFFF, 0x0FFF_FFFF].enumerated() { fat.put32(i * 4, UInt32(e)) }
    let data = UInt64(v0.firstDataSector)
    guard (try? d.write(UInt64(v0.reservedSectors), fat)) != nil,
          (try? d.write(UInt64(v0.reservedSectors + v0.fatSectors), fat)) != nil,
          (try? d.write(data, root + sub + file)) != nil, // clusters 2-3, 4, 5
          let v = try? FATVolume.mount(d) else { return false }
    let want = [FATEntry(name: "readme.txt", isDirectory: false, size: 11),
                FATEntry(name: longName, isDirectory: false, size: 0),
                FATEntry(name: "BADSUM", isDirectory: false, size: 0),
                FATEntry(name: "SUBDIR", isDirectory: true, size: 0),
                FATEntry(name: crossing, isDirectory: false, size: 0)]
    let listed = (try? v.list([])) == want && v.label == "HANDMADE"
        && (try? v.list(["subdir"])) == [FATEntry(name: "inner.BIN", isDirectory: false, size: 0)]
        && (try? v.read(["README.TXT"])) == bytes("hello, fat\n")
        && (try? v.read(["a LONG file NAME.TEXT"])) == []
        && v.freeClusters == v.totalClusters - 4
    // FSInfo still has format's count: check() says so, until sync().
    let stale = v.check()
    let reported = stale.count == 1 && stale[0].hasPrefix("FSInfo free count")
    let synced = (try? v.sync()) != nil && fatClean(v, "hand-built after sync")
    // New entries reuse deleted slots (7, 8, 11, 12), then the end: the
    // garbage after the old end marker must not come back.
    var added = true
    for n in ["n7.txt", "n8.txt", "n11.txt", "n12.txt", "n18.txt"] { added = added && (try? v.write([n], bytes("n"))) != nil }
    let reused = (try? v.loadDir(v.rootCluster)).map { dir in
        dir.entries.map { $0.slot } == [1, 4, 6, 7, 8, 9, 11, 12, 17, 18] && dir.end == 19
    } == true
    let remounted = try? FATVolume.mount(d)
    let after = (try? v.list([]))?.count == 10 && remounted.map { (try? $0.list([]))?.count == 10 } == true
    return listed && reported && synced && added && reused && after && fatClean(v, "hand-built")
}

@inline(never)
func fatRejectsBadBootSector() -> Bool {
    guard let (base, _) = fatFresh() else { return false }
    func rejected(_ change: (inout [UInt8]) -> Void) -> Bool {
        let d = fatCopy(base)
        guard var b = try? d.read(0, count: 1) else { return false }
        change(&b)
        guard (try? d.write(0, b)) != nil else { return false }
        return fatFails(.notFAT32) { () throws(FATError) in try FATVolume.mount(d) }
    }
    return rejected { $0.put16(11, 1024) }      // sector size
        && rejected { $0[13] = 3 }              // sectors per cluster not a power of two
        && rejected { $0[13] = 0 }
        && rejected { $0[510] = 0 }             // signature
        && rejected { $0.put32(32, 40_000) }    // too few clusters for FAT32 (type string still says FAT32)
        && rejected { $0.put32(32, 1 << 20) }   // bigger than the device
        && rejected { $0.put16(17, 512) }       // FAT12/16 root directory entries
        && rejected { $0.put32(44, 999_999) }   // root cluster out of range
        && rejected { $0[16] = 0 }              // no FATs
        && rejected { $0.put32(36, 0) }         // no FAT sectors
        && fatFails(.notFAT32) { () throws(FATError) in try FATVolume.mount(RamDisk(sectors: 100)) } // blank
        && (try? FATVolume.mount(base)) != nil
}

/// Loops, chains into free or bad clusters, and wild cluster numbers give
/// .corrupt (and check() problems), not a hang or a trap.
@inline(never)
func fatDetectsDamage() -> Bool {
    guard let (base, v) = fatFresh(),
          (try? v.write(["loop.bin"], fatPattern(1500, 1))) != nil,
          (try? v.write(["ok.txt"], bytes("fine"))) != nil,
          (try? v.mkdir(["dir"])) != nil,
          let root = try? v.loadDir(v.rootCluster), let i = root.find("loop.bin"),
          let chain = try? v.chain(root.entries[i].cluster), chain.count == 3,
          let di = root.find("dir") else { return false }
    func damaged(_ change: (RamDisk) -> Void, _ failure: (FATVolume) -> Bool, _ problem: StaticString) -> Bool {
        let d = fatCopy(base)
        change(d)
        guard let w = try? FATVolume.mount(d) else { return false }
        var found = false
        for p in w.check() where containsBytes(Array(p.utf8), bytes(problem)) { found = true }
        return failure(w) && (try? w.read(["ok.txt"])) == bytes("fine") && found
    }
    let readCorrupt = { (w: FATVolume) -> Bool in fatFails(.corrupt) { () throws(FATError) in try w.read(["loop.bin"]) } }
    let loop = damaged({ fatPoke($0, v, chain[2], chain[0]) }, readCorrupt, "cross-linked")
    let selfLoop = damaged({ fatPoke($0, v, chain[1], chain[1]) }, readCorrupt, "cross-linked")
    let intoFree = damaged({ fatPoke($0, v, chain[1], 0) }, readCorrupt, "free cluster")
    let intoBad = damaged({ fatPoke($0, v, chain[0], fatBadCluster) }, readCorrupt, "bad cluster")
    let short = damaged({ fatPoke($0, v, chain[1], fatEndOfChain) }, readCorrupt, "lost clusters: 1")
    let wildDir = damaged({ d in
        var s = (try? d.read(UInt64(v.clusterLBA(v.rootCluster)), count: 1)) ?? []
        guard s.count == 512 else { return }
        s.put16(root.entries[di].slot * 32 + 20, 0x0FFF)
        _ = try? d.write(UInt64(v.clusterLBA(v.rootCluster)), s)
    }, { w in fatFails(.corrupt) { () throws(FATError) in try w.list(["dir"]) } }, "bad cluster")
    return loop && selfLoop && intoFree && intoBad && short && wildDir
}

// MARK: Phase X

/// Every file and directory on `v` under `path` matches `node`: names
/// (case kept), kinds, sizes and contents.
func fatMatches(_ v: FATVolume, _ node: FSNode, _ path: [String]) -> Bool {
    guard let listed = try? v.list(path) else { return false }
    let entries = listed.sorted { $0.name < $1.name }
    let kids = node.sortedChildren
    guard entries.count == kids.count else { return false }
    for i in 0..<kids.count {
        let e = entries[i], k = kids[i]
        guard e.name == k.name, e.isDirectory == k.isDirectory else { return false }
        if k.isDirectory {
            guard fatMatches(v, k, path + [e.name]) else { return false }
        } else {
            guard e.size == k.size, (try? v.read(path + [e.name])) == k.contents else { return false }
        }
    }
    return true
}

/// Remove everything under `path`, bottom-up.
func fatRemoveAll(_ v: FATVolume, _ path: [String]) -> Bool {
    guard let entries = try? v.list(path) else { return false }
    for e in entries {
        if e.isDirectory && !fatRemoveAll(v, path + [e.name]) { return false }
        guard (try? v.remove(path + [e.name])) != nil else { return false }
    }
    return true
}

/// A script on the volume and on a RAM FileSystem side by side; check()
/// after every step.
final class FATScript {
    let disk: RamDisk
    let vol: FATVolume
    let model = FileSystem()
    var ok = true
    var step = 0

    init(_ disk: RamDisk, _ vol: FATVolume) {
        self.disk = disk
        self.vol = vol
    }

    func done(_ success: Bool) {
        step += 1
        if !success { print("    fat script: step \(step) failed") }
        ok = ok && success && fatClean(vol, "script step \(step)")
    }

    func write(_ p: [String], _ data: [UInt8], model m: String? = nil) {
        let r = (try? vol.write(p, data)) != nil
        done(r && (try? model.write(m ?? FileSystem.join(p), data)) != nil)
    }

    func mkdir(_ p: [String]) {
        let r = (try? vol.mkdir(p)) != nil
        done(r && (try? model.mkdir(FileSystem.join(p))) != nil)
    }

    func rename(_ a: [String], _ b: [String]) {
        let r = (try? vol.rename(a, to: b)) != nil
        done(r && (try? model.rename(FileSystem.join(a), to: FileSystem.join(b))) != nil)
    }

    func remove(_ p: [String]) {
        let r = (try? vol.remove(p)) != nil
        done(r && (try? model.remove(FileSystem.join(p))) != nil)
    }

    /// An operation that must fail with `want` and change nothing.
    func fails<R>(_ want: FATError, _ body: () throws(FATError) -> R) {
        let free = vol.freeClusters
        done(fatFails(want, body) && vol.freeClusters == free)
    }
}

@inline(never)
func fatScriptMatchesModel() -> Bool {
    guard let (d, v) = fatFresh() else { return false }
    let s = FATScript(d, v)
    s.write(["a.txt"], bytes("hello"))
    s.write(["Readme.TXT"], fatPattern(700, 1))
    s.mkdir(["docs"])
    s.write(["docs", "big.bin"], fatPattern(5000, 2))
    s.write(["a.txt"], fatPattern(2000, 3))             // grow
    s.write(["docs", "big.bin"], fatPattern(100, 4))    // shrink
    s.write(["docs", "empty"], [])
    s.write(["docs", "empty"], [9])
    s.write(["docs", "EMPTY"], [], model: "/docs/empty") // case-insensitive: replaces, keeps the name
    s.mkdir(["docs", "sub"])
    s.write(["docs", "sub", "deep.txt"], bytes("deep"))
    s.rename(["a.txt"], ["docs", "sub", "A Long Name.txt"])           // across directories, gains an LFN
    s.rename(["docs", "sub"], ["moved"])                              // a directory: its .. changes
    s.rename(["moved", "A Long Name.txt"], ["moved", "a long name.TXT"]) // case only, in place
    s.rename(["Readme.TXT"], ["readme2.txt"])                         // in place, fewer slots
    s.rename(["readme2.txt"], ["A much longer name than before, with spaces.txt"]) // more slots
    for i in 0..<20 { s.write(["docs", "f\(i)"], fatPattern(i * 40, i)) } // docs grows a cluster
    for i in 0..<8 { s.remove(["docs", "f\(i)"]) }
    s.write(["docs", "Long name reusing deleted slots.bin"], fatPattern(600, 5))
    s.mkdir(["moved", "inner"])
    s.rename(["moved"], ["docs", "moved"])                            // .. becomes docs
    s.write(["docs", "moved", "inner", "x"], bytes("x"))
    s.fails(.isADirectory) { () throws(FATError) in try v.write(["docs"], []) }
    s.fails(.exists) { () throws(FATError) in try v.mkdir(["DOCS"]) }
    s.fails(.exists) { () throws(FATError) in try v.mkdir(["docs", "big.bin"]) }
    s.fails(.notEmpty) { () throws(FATError) in try v.remove(["docs"]) }
    s.fails(.exists) { () throws(FATError) in try v.rename(["docs", "big.bin"], to: ["docs", "Empty"]) }
    s.fails(.invalidName) { () throws(FATError) in try v.rename(["docs"], to: ["docs", "moved", "docs"]) }
    s.fails(.invalidName) { () throws(FATError) in try v.write(["bad:name"], []) }
    s.fails(.invalidName) { () throws(FATError) in try v.write(["trailing."], []) }
    s.fails(.invalidName) { () throws(FATError) in try v.write([""], []) }
    s.fails(.invalidName) { () throws(FATError) in try v.mkdir([String(repeating: "y", count: 256)]) }
    s.fails(.invalidName) { () throws(FATError) in try v.remove([]) }
    s.fails(.invalidName) { () throws(FATError) in try v.rename([], to: ["x"]) }
    s.fails(.notFound) { () throws(FATError) in try v.read(["nope"]) }
    s.fails(.notFound) { () throws(FATError) in try v.write(["nope", "x"], []) }
    s.fails(.notFound) { () throws(FATError) in try v.rename(["nope"], to: ["x"]) }
    s.fails(.notFound) { () throws(FATError) in try v.remove(["docs", "f0"]) }
    s.fails(.notADirectory) { () throws(FATError) in try v.read(["docs", "big.bin", "x"]) }
    s.fails(.notADirectory) { () throws(FATError) in try v.list(["docs", "big.bin"]) }
    s.fails(.isADirectory) { () throws(FATError) in try v.read(["docs"]) }
    s.remove(["docs", "big.bin"])
    s.rename(["docs", "f19"], ["docs", "f19"])                        // to itself: nothing
    guard s.ok, let w = try? FATVolume.mount(d), fatMatches(w, s.model.root, []), fatClean(w, "script remount") else { return false }
    // Take it all down again: every cluster comes back.
    return fatRemoveAll(w, []) && (try? w.list([])) == [] && w.freeClusters == w.totalClusters - 1
        && fatClean(w, "script emptied") && (try? FATVolume.mount(d))?.freeClusters == w.totalClusters - 1
}

/// Fill the volume: .noSpace before anything is written, nothing leaked.
@inline(never)
func fatFullDisk() -> Bool {
    guard let (d, v) = fatFresh(), (try? v.write(["keep.txt"], bytes("k"))) != nil else { return false }
    let free0 = v.freeClusters
    guard (try? v.reserve(["big"], size: (free0 - 2) * 512)) != nil, v.freeClusters == 2,
          let before = try? v.list([]) else { return false }
    let tooBig = fatFails(.noSpace) { () throws(FATError) in try v.write(["x"], fatPattern(1025, 1)) }
        && v.freeClusters == 2 && (try? v.list([])) == before && fatClean(v, "full: too big")
    let exact = (try? v.write(["x"], fatPattern(1024, 2))) != nil && v.freeClusters == 0
    let full = fatFails(.noSpace) { () throws(FATError) in try v.mkdir(["d"]) }
        && fatFails(.noSpace) { () throws(FATError) in try v.write(["y"], [1]) }
        && fatFails(.noSpace) { () throws(FATError) in try v.write(["x"], [1]) } // replacing needs new clusters first
        && fatFails(.noSpace) { () throws(FATError) in try v.reserve(["z"], size: 1) }
        && (try? v.read(["x"])) == fatPattern(1024, 2)
    // Empty files only need a slot: the root's one cluster has 12 left.
    var slots = true
    for i in 0..<12 { slots = slots && (try? v.write(["e\(i)"], [])) != nil }
    let noSlot = fatFails(.noSpace) { () throws(FATError) in try v.write(["e12"], []) }
        && fatFails(.noSpace) { () throws(FATError) in try v.rename(["keep.txt"], to: ["a much longer name.txt"]) }
    guard tooBig && exact && full && slots && noSlot && v.freeClusters == 0 && fatClean(v, "full") else { return false }
    guard let w = try? FATVolume.mount(d), w.freeClusters == 0, fatClean(w, "full remount"),
          (try? w.remove(["big"])) != nil, w.freeClusters == free0 - 2 else { return false }
    return fatRemoveAll(w, []) && w.freeClusters == w.totalClusters - 1 && fatClean(w, "full emptied")
}

/// Cut the power after every possible number of sector writes during one
/// overwrite: a thrown error means the old contents (on this volume and
/// after a remount), success means the new, and check() finds at most
/// leaked clusters (and FSInfo's hint not yet updated).
@inline(never)
func fatSurvivesPowerCuts() -> Bool {
    let old = fatPattern(1200, 7), new = fatPattern(2600, 9)
    guard let (base, v) = fatFresh(), (try? v.write(["keep.txt"], bytes("keep"))) != nil,
          (try? v.write(["f.bin"], old)) != nil else { return false }
    let probe = fatCopy(base)
    guard let pv = try? FATVolume.mount(probe) else { return false }
    let w0 = probe.sectorsWritten
    guard (try? pv.write(["f.bin"], new)) != nil else { return false }
    let writes = Int(probe.sectorsWritten - w0)
    var sawOld = false, sawNew = false
    func onlyLeaks(_ w: FATVolume) -> Bool {
        for p in w.check() where !p.hasPrefix("lost clusters") && !p.hasPrefix("FSInfo free count") {
            print("    fat power cut: \(p)")
            return false
        }
        return true
    }
    for k in 0..<writes {
        let d = fatCopy(base)
        guard let w = try? FATVolume.mount(d) else { return false }
        d.failWritesAfter = k
        let wrote = (try? w.write(["f.bin"], new)) != nil
        d.failWritesAfter = nil
        let want = wrote ? new : old
        if wrote { sawNew = true } else { sawOld = true }
        guard (try? w.read(["f.bin"])) == want, onlyLeaks(w),
              let again = try? FATVolume.mount(d), (try? again.read(["f.bin"])) == want,
              (try? again.read(["keep.txt"])) == bytes("keep"), onlyLeaks(again),
              (try? again.write(["after"], bytes("works"))) != nil, (try? again.read(["after"])) == bytes("works") else {
            print("    fat power cut after \(k) of \(writes) writes")
            return false
        }
    }
    return writes >= 8 && sawOld && sawNew
}

@inline(never)
func fatNamesRoundTrip() -> Bool {
    guard let (d, v) = fatFresh() else { return false }
    let names = ["lower.txt", "UPPER.TXT", "notes.TXT", "MiXeD.txt", "Mixed Case.Txt", "café ☕.txt", "a.b.c.d",
                 ".hidden", "~tilde", "longfilename1.txt", "longfilename2.txt", "LONGFI~1.TXT",
                 String(repeating: "x", count: 255), "with+plus;semi=eq[1].txt", "two  spaces", "NOEXT", "lowext.c"]
    for (i, n) in names.enumerated() {
        guard (try? v.write([n], fatPattern(i * 3 + 1, i))) != nil else { print("    fat names: write \(n)"); return false }
    }
    guard let w = try? FATVolume.mount(d), let listed = try? w.list([]), listed.map({ $0.name }) == names,
          let root = try? w.loadDir(w.rootCluster) else { return false }
    for (i, n) in names.enumerated() where (try? w.read([n])) != fatPattern(i * 3 + 1, i) { return false }
    /// The raw 8.3 entry: short name, case bits, whether an LFN run precedes it.
    func raw(_ n: String, _ short: StaticString, _ bits: UInt8, long: Bool) -> Bool {
        guard let i = root.find(n) else { return false }
        let e = root.entries[i], o = e.slot * 32
        return Array(root.data[o..<(o + 11)]) == bytes(short) && root.data[o + 12] == bits && (e.first < e.slot) == long
    }
    let shorts = raw("lower.txt", "LOWER   TXT", 0x18, long: false)
        && raw("UPPER.TXT", "UPPER   TXT", 0, long: false)
        && raw("notes.TXT", "NOTES   TXT", 0x08, long: false)
        && raw("lowext.c", "LOWEXT  C  ", 0x18, long: false)
        && raw("NOEXT", "NOEXT      ", 0, long: false)
        && raw("MiXeD.txt", "MIXED~1 TXT", 0, long: true)
        && raw("longfilename1.txt", "LONGFI~1TXT", 0, long: true)
        && raw("longfilename2.txt", "LONGFI~2TXT", 0, long: true)
        && raw("LONGFI~1.TXT", "LONGFI~3TXT", 0, long: true) // a valid 8.3 name, but taken
        && raw("café ☕.txt", "CAF__~1 TXT", 0, long: true)
        && raw(".hidden", "HIDDEN~1   ", 0, long: true)
    let folded = (try? w.read(["MIXED CASE.TXT"])) == fatPattern(13, 4) && (try? w.read(["mixed.TXT"])) == fatPattern(10, 3)
        && fatFails(.notFound) { () throws(FATError) in try w.read(["CAFÉ ☕.TXT"]) } // only ASCII folds
    var invalid = true
    for n in ["a*b", "a?b", "a\\b", "a|b", "a<b", "a>b", "q\"", "a/b", "tab\t", "end ", "end.", ".", "..", "",
              String(repeating: "z", count: 256)] {
        invalid = invalid && fatFails(.invalidName) { () throws(FATError) in try w.write([n], []) }
    }
    return shorts && folded && invalid && fatClean(w, "names")
}

@inline(never)
func fatTimestamps() -> Bool {
    guard let (_, v) = fatFresh() else { return false }
    fatClock = { FATTimestamp(year: 2030, month: 6, day: 15, hour: 13, minute: 45, second: 30) }
    let wrote = (try? v.write(["t.txt"], [1])) != nil && (try? v.mkdir(["dir"])) != nil
    fatClock = fatDefaultClock
    guard wrote, let root = try? v.loadDir(v.rootCluster), let i = root.find("t.txt"), let j = root.find("dir"),
          let sub = try? v.loadDir(root.entries[j].cluster), let dot = sub.dot else { return false }
    let date = 50 << 9 | 6 << 5 | 15, time = 13 << 11 | 45 << 5 | 15
    let o = root.entries[i].slot * 32
    return root.data.le16(o + 24) == date && root.data.le16(o + 22) == time && root.data.le16(o + 16) == date
        && sub.data.le16(dot * 32 + 24) == date && fatDateTime(FATTimestamp()) == (date: 46 << 9 | 1 << 5 | 1, time: 0)
}

func fatTests(_ t: inout SelfTest) {
    let base = HeapUsage()
    t.check("fat32: format 64 MiB, mount, geometry, free count, boot/FSInfo copies", fatFormatGeometry())
    t.check("fat32: hand-built LFN/8.3/deleted/end entries listed; slots reused", fatHandBuiltDirectory())
    t.check("fat32: bad boot sectors give .notFAT32", fatRejectsBadBootSector())
    t.check("fat32: FAT loops, bad links, wild clusters give .corrupt", fatDetectsDamage())
    t.check("fat32: scripted session matches a RAM fs model after remount", fatScriptMatchesModel())
    t.check("fat32: full disk gives .noSpace, nothing leaked", fatFullDisk())
    t.check("fat32: power cut during overwrite leaves old or new contents", fatSurvivesPowerCuts())
    t.check("fat32: long, mixed-case and 8.3 names round-trip", fatNamesRoundTrip())
    t.check("fat32: timestamps come from fatClock", fatTimestamps())
    t.check("fat32: volumes and disks freed (live blocks)", HeapUsage() == base)
}
