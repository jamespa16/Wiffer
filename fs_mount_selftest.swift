// Phase Y selftests: FAT32 volumes mounted in a FileSystem. Each test mounts
// a sparse RamDisk volume in a scratch FileSystem: changes reach the disk
// (checked by remounting the same RamDisk elsewhere and comparing trees), a
// failing disk (failWritesAfter) leaves the RAM tree as it was, FAT's case
// folding, .crossDevice/.busy/.noSpace, the editor saving through a mount,
// the shell's mkfs/mount/umount/sync/fsck/df/disks, and the Phase Z fixture
// (an image written by tests/fat32.py, loaded as a Limine module) read back
// exactly. Called from runSelfTests.

/// A cheap checksum for tree listings.
func fsSum(_ bytes: [UInt8]) -> UInt32 {
    var h: UInt32 = 2_166_136_261
    for b in bytes { h = (h ^ UInt32(b)) &* 16_777_619 }
    return h
}

/// Every node below `n`, sorted: "/dir/" or "/dir/file <size> <sum>".
func fsTreeLines(_ n: FSNode, _ path: String, _ out: inout [String]) {
    for c in n.sortedChildren {
        let p = path + "/" + c.name
        if c.isDirectory {
            out.append(p + "/")
            fsTreeLines(c, p, &out)
        } else {
            out.append(p + " \(c.size) \(fsSum(c.contents))")
        }
    }
}

func fsTree(_ fs: FileSystem, _ path: String) -> [String] {
    guard let n = try? fs.lookup(path) else { return ["(missing)"] }
    var out: [String] = []
    fsTreeLines(n, "", &out)
    return out
}

/// A fresh volume mounted at `at` (made) in a new FileSystem.
func mountedFresh(at: String = "/m") -> (RamDisk, FATVolume, FileSystem)? {
    guard let (d, v) = fatFresh() else { return nil }
    let fs = FileSystem()
    guard (try? fs.mkdir(at, parents: true)) != nil, (try? fs.mount(v, at: at)) != nil else { return nil }
    return (d, v, fs)
}

/// The tree of `d`'s volume, mounted afresh in another FileSystem.
func remountedTree(_ d: RamDisk) -> [String] {
    guard let v = try? FATVolume.mount(d) else { return ["(mount failed)"] }
    let fs = FileSystem()
    guard (try? fs.mkdir("/again")) != nil, (try? fs.mount(v, at: "/again")) != nil else { return ["(mount failed)"] }
    return fsTree(fs, "/again")
}

func mountScript(_ fs: FileSystem) throws(FSError) {
    try fs.create("/m/empty")
    try fs.mkdir("/m/new")
    try fs.mkdir("/m/p/q/r", parents: true)
    try fs.mkdir("/m/docs/sub", parents: true) // docs is already there
    try fs.write("/m/new/f.txt", bytes("one\n"))
    try fs.write("/m/new/f.txt", bytes("two\n"), append: true)
    try fs.write("/m/docs/a.bin", fatPattern(700, 2)) // shrink
    try fs.touch("/m/empty")
    try fs.touch("/m/t")
    try fs.rename("/m/new/f.txt", to: "/m/p/q/moved.txt")
    try fs.rename("/m/p", to: "/m/docs/p") // a directory, to another parent
    try fs.rename("/m/t", to: "/m/Touched")
    try fs.remove("/m/Read Me.txt")
    try fs.mkdir("/m/tmp/a/b", parents: true)
    try fs.write("/m/tmp/a/b/x", fatPattern(2000, 3))
    try fs.write("/m/tmp/a/y", bytes("y"))
    try fs.remove("/m/tmp", recursive: true)
    try fs.remove("/m/new")
}

/// Mount shows what was on the volume; every kind of change reaches it.
@inline(never)
func mountMirrors() -> Bool {
    guard let (d, v) = fatFresh() else { return false }
    guard (try? v.write(["Read Me.txt"], bytes("hello\n"))) != nil, (try? v.mkdir(["docs"])) != nil,
          (try? v.write(["docs", "a.bin"], fatPattern(1500, 1))) != nil else { return false }
    let fs = FileSystem()
    _ = try? fs.mkdir("/m")
    guard (try? fs.mount(v, at: "/m")) != nil, fs.mounts.count == 1, fs.mountPoint(for: v) != nil,
          (try? fs.read("/m/Read Me.txt")) == bytes("hello\n"), (try? fs.read("/m/DOCS/A.BIN")) == fatPattern(1500, 1),
          fs.usage == FileSystem.Usage(bytes: 0, files: 0, directories: 1) else { return false }
    do throws(FSError) { try mountScript(fs) } catch {
        print("    mount script: \(error.message)")
        return false
    }
    let tree = fsTree(fs, "/m")
    let want = ["/Touched 0 2166136261", "/docs/", "/docs/a.bin 700 \(fsSum(fatPattern(700, 2)))", "/docs/p/", "/docs/p/q/",
                "/docs/p/q/moved.txt 8 \(fsSum(bytes("one\ntwo\n")))", "/docs/p/q/r/", "/docs/sub/", "/empty 0 2166136261"]
    guard tree == want, fatClean(v, "mount script"), (try? fs.unmount(at: "/m")) != nil, fs.mounts.isEmpty,
          (try? fs.lookup("/m"))?.children.isEmpty == true else { return false }
    return remountedTree(d) == want
}

/// With the disk failing, every change throws .io and the tree (RAM and
/// disk) stays as it was; a power-cut sweep over an overwrite keeps RAM
/// and disk equal.
@inline(never)
func mountErrorsChangeNothing() -> Bool {
    guard let (d, v, fs) = mountedFresh() else { return false }
    guard (try? fs.write("/m/keep", bytes("old\n"))) != nil, (try? fs.mkdir("/m/dir")) != nil,
          (try? fs.write("/m/dir/f", bytes("f"))) != nil else { return false }
    let before = fsTree(fs, "/m")
    d.failWritesAfter = 0
    let io = fails(.io) { () throws(FSError) in try fs.write("/m/keep", bytes("new")) }
        && fails(.io) { () throws(FSError) in try fs.write("/m/keep", bytes("more"), append: true) }
        && fails(.io) { () throws(FSError) in try fs.write("/m/fresh", bytes("x")) }
        && fails(.io) { () throws(FSError) in try fs.create("/m/n") }
        && fails(.io) { () throws(FSError) in try fs.touch("/m/n") }
        && fails(.io) { () throws(FSError) in try fs.mkdir("/m/d2") }
        && fails(.io) { () throws(FSError) in try fs.mkdir("/m/a/b", parents: true) }
        && fails(.io) { () throws(FSError) in try fs.remove("/m/keep") }
        && fails(.io) { () throws(FSError) in try fs.remove("/m/dir", recursive: true) }
        && fails(.io) { () throws(FSError) in try fs.rename("/m/keep", to: "/m/dir/keep2") }
        && fails(.io) { () throws(FSError) in try fs.rename("/m/keep", to: "/m/kept") }
    d.failWritesAfter = nil
    guard io, fsTree(fs, "/m") == before, remountedTree(d) == before else { return false }
    // Cut after k sector writes, k = 0, 1, ... until the overwrite succeeds.
    var current = bytes("old\n")
    var sweep = true, succeeded = false
    for k in 0..<64 where !succeeded {
        let new = fatPattern(3000, k)
        d.failWritesAfter = k
        succeeded = (try? fs.write("/m/keep", new)) != nil
        d.failWritesAfter = nil
        if succeeded { current = new }
        sweep = sweep && (try? fs.read("/m/keep")) == current && (try? v.read(["keep"])) == current
    }
    return sweep && succeeded && remountedTree(d) == fsTree(fs, "/m")
}

/// Under a mount names fold case; a create onto another entry's case
/// variant is .exists, and an entry can be renamed to its own variant.
@inline(never)
func mountCaseRule() -> Bool {
    guard let (d, v, fs) = mountedFresh() else { return false }
    guard (try? fs.write("/m/a", bytes("1"))) != nil, (try? fs.mkdir("/m/Dir")) != nil else { return false }
    let replaced = (try? fs.write("/m/A", bytes("2"))) != nil && (try? fs.read("/m/a")) == bytes("2")
        && fsTree(fs, "/m") == ["/Dir/", "/a 1 \(fsSum(bytes("2")))"]
    let refused = fails(.exists) { () throws(FSError) in try fs.create("/m/A") }
        && fails(.exists) { () throws(FSError) in try fs.mkdir("/m/DIR") }
        && fails(.exists) { () throws(FSError) in try fs.rename("/m/Dir", to: "/m/A") }
        && fails(.isADirectory) { () throws(FSError) in try fs.write("/m/dir", bytes("x")) }
    // mkdir -p walks into the existing spelling.
    let parents = (try? fs.mkdir("/m/DIR/sub", parents: true)) != nil && (try? fs.lookup("/m/Dir/sub")) != nil
    let renamed = (try? fs.rename("/m/a", to: "/m/A")) != nil && (try? fs.rename("/m/dir", to: "/m/dIR")) != nil
        && fsTree(fs, "/m") == ["/A 1 \(fsSum(bytes("2")))", "/dIR/", "/dIR/sub/"]
    // Outside the mount, lookups stay exact.
    let ram = (try? fs.write("/ram", bytes("r"))) != nil && !fs.exists("/RAM")
    let names = fails(.invalidName) { () throws(FSError) in try fs.write("/m/a*b", []) }
    return replaced && refused && parents && renamed && ram && names && fatClean(v, "case rule")
        && remountedTree(d) == fsTree(fs, "/m")
}

/// Moves across filesystems, and anything touching a mount point, refused.
@inline(never)
func mountBoundaries() -> Bool {
    guard let (_, v, fs) = mountedFresh(at: "/top/m"), let (_, v2) = fatFresh(label: "TWO") else { return false }
    guard (try? fs.write("/m-file", bytes("r"))) != nil, (try? fs.write("/top/m/f", bytes("d"))) != nil,
          (try? fs.mkdir("/m2")) != nil, (try? fs.mount(v2, at: "/m2")) != nil, (try? fs.mkdir("/full")) != nil,
          (try? fs.write("/full/x", [])) != nil else { return false }
    let cross = fails(.crossDevice) { () throws(FSError) in try fs.rename("/top/m/f", to: "/f") }
        && fails(.crossDevice) { () throws(FSError) in try fs.rename("/m-file", to: "/top/m/r") }
        && fails(.crossDevice) { () throws(FSError) in try fs.rename("/top/m/f", to: "/m2/f") }
    let busy = fails(.busy) { () throws(FSError) in try fs.remove("/top/m") }
        && fails(.busy) { () throws(FSError) in try fs.remove("/top/m", recursive: true) }
        && fails(.busy) { () throws(FSError) in try fs.remove("/top", recursive: true) }
        && fails(.busy) { () throws(FSError) in try fs.rename("/top/m", to: "/n") }
        && fails(.busy) { () throws(FSError) in try fs.rename("/top", to: "/top2") }
        && fails(.busy) { () throws(FSError) in try fs.mount(v, at: "/full") } // already mounted
        && fails(.busy) { () throws(FSError) in try fs.mount(v2, at: "/top/m") }
    let mkdirOK = (try? fs.mkdir("/top/m/inner")) != nil
    let mountErrors = fails(.busy) { () throws(FSError) in try fs.mount(v2, at: "/top/m/inner") }
        && fails(.notEmpty) { () throws(FSError) in
            try fs.unmount(at: "/m2")
            try fs.mount(v2, at: "/full")
        }
        && fails(.invalidPath) { () throws(FSError) in try fs.mount(v2, at: "/") }
        && fails(.notADirectory) { () throws(FSError) in try fs.mount(v2, at: "/m-file") }
        && fails(.notMounted) { () throws(FSError) in try fs.unmount(at: "/full") }
        && fails(.invalidMove) { () throws(FSError) in try fs.rename("/top/m/inner", to: "/top/m/INNER/x") }
    let still = (try? fs.read("/top/m/f")) == bytes("d") && (try? fs.read("/m-file")) == bytes("r")
        && fs.mounts.count == 1 && fatClean(v, "boundaries")
    return cross && busy && mkdirOK && mountErrors && still
}

/// A full volume: .noSpace, and the RAM tree unchanged.
@inline(never)
func mountFullDisk() -> Bool {
    guard let (_, v, fs) = mountedFresh() else { return false }
    guard (try? fs.write("/m/keep", fatPattern(400, 1))) != nil else { return false }
    // Fill all but two clusters behind the VFS's back (reserve: no data written).
    guard (try? v.reserve(["fill"], size: (v.freeClusters - 2) * v.clusterSize)) != nil, v.freeClusters == 2 else {
        return false
    }
    let before = fsTree(fs, "/m")
    let full = fails(.noSpace) { () throws(FSError) in try fs.write("/m/big", fatPattern(3 * v.clusterSize, 2)) }
        && fails(.noSpace) { () throws(FSError) in try fs.write("/m/keep", fatPattern(3 * v.clusterSize, 3)) }
        && fails(.noSpace) { () throws(FSError) in try fs.write("/m/keep", fatPattern(3 * v.clusterSize, 3), append: true) }
    let unchanged = fsTree(fs, "/m") == before && v.freeClusters == 2
    let fits = (try? fs.write("/m/small", fatPattern(10, 4))) != nil && (try? v.read(["small"])) == fatPattern(10, 4)
    return full && unchanged && fits && fatClean(v, "full disk")
}

/// The editor saves through a mount; a failing disk shows
/// "save: <path>: I/O error" and keeps the buffer dirty.
@inline(never)
func editorSavesToMount() -> Bool {
    guard let (d, v, fs) = mountedFresh() else { return false }
    var m = EditorModel(rows: 10, cols: 40)
    guard m.open("/m/notes.txt", fs: fs) else { return false }
    feed(&m, chars("on disk"), fs)
    let saved = feed(&m, [ctrl(0x53)], fs) == .redraw && !m.dirty && m.message.hasPrefix("saved")
        && (try? v.read(["notes.txt"])) == bytes("on disk\n")
    feed(&m, chars("!"), fs)
    d.failWritesAfter = 0
    feed(&m, [ctrl(0x53)], fs)
    d.failWritesAfter = nil
    let failed = m.message == "save: /m/notes.txt: I/O error" && m.dirty
        && (try? v.read(["notes.txt"])) == bytes("on disk\n") && (try? fs.read("/m/notes.txt")) == bytes("on disk\n")
    let retried = feed(&m, [ctrl(0x53)], fs) == .redraw && !m.dirty
        && (try? v.read(["notes.txt"])) == bytes("on disk!\n")
    return saved && failed && retried && fatClean(v, "editor")
}

/// mkfs, mount, umount, sync, fsck, df and disks on a scripted shell, with a
/// RamDisk briefly in blockDevices as "ram9".
@inline(never)
func mountCommandsWork() -> Bool {
    let ram = RamDisk(name: "ram9", sectors: fatSmallSectors)
    blockDevices.append(ram)
    defer { blockDevices.removeAll(where: { $0 === ram }) }
    let fs = FileSystem()
    _ = try? fs.mkdir("/mnt")
    let out = fsTranscript(fs, """
        mount ram9 /mnt\rmkfs ram9 bad*label\rmkfs ram9 Nine\rmount ram9 /mnt\rmkfs ram9\r\
        mount ram9 /mnt\rmount\rwrite /mnt/Hi.txt hey\rcat /mnt/HI.TXT\rmv /mnt/hi.txt /\rdf\rfsck /mnt\rsync\rdisks\r\
        rm /mnt\rumount /mnt\rumount /mnt\rls /mnt\rfsck /\rmkfs nope\r
        """)
    let lines = out.split(separator: "\n").map { String($0) }
    let want: [String] = [
        "ram9: no FAT32 filesystem (mkfs ram9)",
        "mkfs: ram9: bad label (up to 11 letters, digits, spaces)",
        "mkfs: ram9: FAT32 'NINE', 0.0 of 33.5 MiB used, 68520 clusters of 512 bytes",
        "ram9: FAT32 'NINE' mounted at /mnt, 0.0 of 33.5 MiB used, 68520 clusters of 512 bytes",
        "mkfs: ram9: mounted at /mnt (umount first)",
        "mount: ram9: already mounted at /mnt",
        "ram9 on /mnt: FAT32 'NINE'",
        "hey",
        "mv: /mnt/hi.txt: can't move across filesystems",
        "fs: 0 bytes in 0 files, 1 directories",
        "/mnt: ram9 'NINE', 0.0 of 33.5 MiB used, 68520 clusters of 512 bytes",
        "fsck: /mnt: clean",
        "rm: /mnt: mount point busy",
        "umount: /mnt: not a mount point",
        "fsck: /: not a mount point",
        "mkfs: nope: no such disk",
    ]
    var ok = lines.count >= want.count
    var at = 0
    for w in want { // in order, other lines (the disks table) between
        while at < lines.count && lines[at] != w { at += 1 }
        if at == lines.count {
            print("    mount commands: missing '\(w)'")
            ok = false
            at = 0
        }
    }
    let disks = lines.contains(where: { $0.hasPrefix("ram9  34 MiB") && $0.hasSuffix("  /mnt") })
    if !disks { print("    mount commands: no disks line for ram9 at /mnt") }
    let after = (try? FATVolume.mount(ram)).map { (try? $0.read(["hi.txt"])) == bytes("hey\n") } == true
    return ok && disks && after && fs.mounts.isEmpty && lines.last == "mkfs: nope: no such disk"
}

/// A RamDisk holding the sectors of a FATSPRS1 file (tests/fat32.py
/// write_sparse): "FATSPRS1", u32 total sectors, u32 extent count, then per
/// extent u32 LBA, u32 count and the sectors (little-endian).
func ramDiskFromSparse(_ m: UnsafeRawBufferPointer) -> RamDisk? {
    func u32(_ o: Int) -> Int { Int(m[o]) | Int(m[o + 1]) << 8 | Int(m[o + 2]) << 16 | Int(m[o + 3]) << 24 }
    guard m.count >= 16, m[0..<8].elementsEqual(Array("FATSPRS1".utf8)) else { return nil }
    let total = u32(8), extents = u32(12)
    let d = RamDisk(name: "fix0", sectors: UInt64(total))
    var at = 16
    for _ in 0..<extents {
        guard at + 8 <= m.count else { return nil }
        let lba = u32(at), n = u32(at + 4)
        at += 8
        guard n <= (m.count - at) / sectorSize, lba + n <= total else { return nil }
        for s in 0..<n {
            let o = at + s * sectorSize
            d.sectors[UInt64(lba + s)] = Array(UnsafeRawBufferPointer(rebasing: m[o..<(o + sectorSize)]))
        }
        at += n * sectorSize
    }
    return at == m.count ? d : nil
}

/// The Phase Z fixture, written on the host by tests/fat32.py (FIXTURE_TREE
/// there), mounted here: every name, size and byte as the host wrote it.
@inline(never)
func mountHostFixture() -> Bool {
    guard let module = bootModule(named: "fat32-lfn") else {
        print("    fixture: no fat32-lfn boot module")
        return false
    }
    guard let d = ramDiskFromSparse(module), let v = try? FATVolume.mount(d) else {
        print("    fixture: not a FATSPRS1 FAT32 image")
        return false
    }
    let fs = FileSystem()
    guard v.label == "WIFFERFIX", v.clusterSize == 512, v.totalClusters == 66_504, fatClean(v, "fixture"),
          (try? fs.mkdir("/fix")) != nil, (try? fs.mount(v, at: "/fix")) != nil else { return false }
    var big = [UInt8](repeating: 0, count: 5000)
    for i in 0..<big.count { big[i] = UInt8(truncatingIfNeeded: 7 * i + i / 512) }
    func file(_ path: String, _ data: [UInt8]) -> String { path + " \(data.count) \(fsSum(data))" }
    let want = [
        file("/README.TXT", bytes("Wiffer FAT32 fixture\n")),
        file("/hello.txt", bytes("hello, world\n")),
        file("/Mixed Case Name.md", bytes("# Mixed\n")),
        file("/A Very Long File Name That Goes Past Thirteen Characters.txt", bytes("long\n")),
        file("/longfilename1.txt", bytes("one\n")),
        file("/longfilename2.txt", bytes("two\n")),
        file("/a+b=c.txt", bytes("lossy\n")),
        file("/empty.txt", []),
        "/docs/",
        file("/docs/big.bin", big),
        "/docs/Notes/",
        "/docs/Notes/deep/",
        file("/docs/Notes/deep/leaf.txt", bytes("leaf\n")),
    ].sorted()
    let got = fsTree(fs, "/fix").sorted()
    if got != want { for l in got { print("    fixture has: \(l)") } }
    let bigOK = (try? fs.read("/fix/DOCS/BIG.BIN")) == big
    return got == want && bigOK
}

func fsMountTests(_ t: inout SelfTest) {
    blockDevices.reserveCapacity(blockDevices.count + 1) // mountCommandsWork adds one
    let base = HeapUsage()
    t.check("mount: loads the volume; every change reaches it (remount matches)", mountMirrors())
    t.check("mount: disk errors leave RAM and disk unchanged; power-cut sweep", mountErrorsChangeNothing())
    t.check("mount: case-folded names; collisions give .exists", mountCaseRule())
    t.check("mount: .crossDevice, .busy, mount/unmount errors", mountBoundaries())
    t.check("mount: full volume gives .noSpace, tree unchanged", mountFullDisk())
    t.check("mount: editor saves to disk; I/O error keeps it dirty", editorSavesToMount())
    t.check("mount: mkfs/mount/umount/sync/fsck/df/disks commands", mountCommandsWork())
    t.check("mount: host-written fixture (tests/fat32.py) reads back exactly", mountHostFixture())
    t.check("mount: volumes and trees freed after unmount (live blocks)", HeapUsage() == base)
}

