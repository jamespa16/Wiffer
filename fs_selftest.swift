// Phase M selftests: path resolution, the FileSystem API and its errors,
// ustar parsing (archives built here, plus the boot module), and the shell
// commands on a scripted shell over a scratch FileSystem. Called from
// runSelfTests.

func bytes(_ s: StaticString) -> [UInt8] { s.withUTF8Buffer { Array($0) } }

@inline(never)
func pathResolution() -> Bool {
    FileSystem.normalize("/a/./b/../c") == "/a/c"
        && FileSystem.normalize("//a//b/") == "/a/b"
        && FileSystem.normalize("../..", cwd: "/x") == "/"
        && FileSystem.normalize("/..") == "/"
        && FileSystem.normalize("b/c", cwd: "/a") == "/a/b/c"
        && FileSystem.normalize("", cwd: "/a") == "/a"
        && FileSystem.normalize("../d", cwd: "/a/b") == "/a/d"
        && FileSystem.components("/") == []
        && FileSystem.components("x/./y", cwd: "/") == ["x", "y"]
}

/// Does `body` throw exactly `want`?
func fails<R>(_ want: FSError, _ body: () throws(FSError) -> R) -> Bool {
    do throws(FSError) {
        _ = try body()
        return false
    } catch {
        return error == want
    }
}

/// Create, write, read, rename, list and remove on a fresh tree, every
/// error case included. Everything it allocates is freed on return.
@inline(never)
func fsOperations() -> Bool {
    let fs = FileSystem()
    do throws(FSError) {
        let a = try fs.mkdir("/a")
        try fs.mkdir("b", cwd: "/a")
        let f = try fs.create("/a/b/file")
        guard f.size == 0, !f.isDirectory, a.isDirectory, fs.path(of: f) == "/a/b/file" else { return false }
        try fs.write("file", bytes("hello"), cwd: "/a/b")
        try fs.write("/a/b/file", bytes(", world"), append: true)
        guard try fs.read("/a/b/../b/file") == bytes("hello, world") else { return false }
        try fs.write("/a/new", bytes("x")) // write creates
        try fs.touch("/a/empty")
        try fs.touch("/a/new") // existing: contents kept
        guard try fs.read("/a/new") == bytes("x") else { return false }

        // Errors, not traps.
        guard fails(.exists, { () throws(FSError) in try fs.create("/a/new") }),
              fails(.exists, { () throws(FSError) in try fs.mkdir("/a/b") }),
              fails(.notFound, { () throws(FSError) in try fs.read("/a/missing") }),
              fails(.notFound, { () throws(FSError) in try fs.create("/nope/x") }),
              fails(.notADirectory, { () throws(FSError) in try fs.create("/a/new/x") }),
              fails(.notADirectory, { () throws(FSError) in try fs.lookup("/a/new/x") }),
              fails(.notADirectory, { () throws(FSError) in try fs.mkdir("/a/new/y", parents: true) }),
              fails(.isADirectory, { () throws(FSError) in try fs.read("/a") }),
              fails(.isADirectory, { () throws(FSError) in try fs.write("/a/b", []) }),
              fails(.notEmpty, { () throws(FSError) in try fs.remove("/a") }),
              fails(.invalidPath, { () throws(FSError) in try fs.remove("/") }),
              fails(.invalidPath, { () throws(FSError) in try fs.create("/") }),
              fails(.invalidMove, { () throws(FSError) in try fs.rename("/a", to: "/a/b/a") }),
              fails(.exists, { () throws(FSError) in try fs.rename("/a/new", to: "/a/empty") }),
              fails(.notFound, { () throws(FSError) in try fs.rename("/zz", to: "/yy") })
        else { return false }

        // mkdir -p over existing and new levels.
        try fs.mkdir("/a/b/c/d", parents: true)
        try fs.mkdir("/a/b", parents: true)
        guard try fs.lookup("/a/b/c/d").isDirectory else { return false }

        // Rename a file, then move a directory (its subtree goes with it).
        try fs.rename("/a/b/file", to: "/a/renamed")
        try fs.rename("/a/b", to: "/moved")
        try fs.rename("/moved", to: "/moved") // no-op
        guard try fs.read("/a/renamed") == bytes("hello, world"),
              !fs.exists("/a/b/file"), !fs.exists("/a/b"),
              try fs.lookup("/moved/c/d").isDirectory,
              fs.path(of: try fs.lookup("/moved/c/d")) == "/moved/c/d" else { return false }

        let names = try fs.list("/a").map { $0.name }
        guard names == ["empty", "new", "renamed"], try fs.list("/a/new").count == 1 else { return false }
        guard fs.usage == FileSystem.Usage(bytes: 13, files: 3, directories: 5) else { return false }

        // Remove: files, an empty directory, then a tree.
        let held = try fs.lookup("/moved/c")
        try fs.remove("/a/renamed")
        try fs.remove("/moved/c/d")
        try fs.remove("/moved", recursive: true)
        guard !fs.exists("/moved"), held.parent == nil, fs.path(of: held) == "/" else { return false }
        return fs.usage == FileSystem.Usage(bytes: 1, files: 2, directories: 2)
    } catch {
        return false
    }
}

/// Modification ticks move forward on write.
@inline(never)
func modificationTicks() -> Bool {
    let fs = FileSystem()
    guard let f = try? fs.create("/t") else { return false }
    let t0 = f.modified
    let wait = ticks
    while ticks < wait + 2 { hlt() }
    _ = try? fs.write("/t", [1])
    return f.modified > t0 && fs.root.modified >= t0
}

// MARK: ustar

/// A minimal ustar writer for tests: one header (+ data) per entry.
struct TarBuilder {
    var data: [UInt8] = []

    mutating func entry(_ name: StaticString, type: UInt8 = 0x30, _ body: [UInt8] = [], prefix: StaticString = "") {
        var h = [UInt8](repeating: 0, count: ustarBlock)
        func put(_ at: Int, _ s: [UInt8]) { for (i, b) in s.enumerated() { h[at + i] = b } }
        func octal(_ at: Int, _ width: Int, _ value: Int) {
            var digits = [UInt8](repeating: 0x30, count: width - 1)
            var v = value, i = width - 2
            while v > 0 && i >= 0 { digits[i] = 0x30 + UInt8(v & 7); v >>= 3; i -= 1 }
            put(at, digits) // then a NUL
        }
        put(0, bytes(name))
        octal(100, 8, 0o644)
        octal(124, 12, body.count)
        h[156] = type
        put(257, bytes("ustar"))
        put(263, bytes("00"))
        put(345, bytes(prefix))
        octal(148, 7, h.withUnsafeBytes { ustarChecksum($0) })
        h[155] = 0x20
        data += h + body
        let pad = (ustarBlock - body.count % ustarBlock) % ustarBlock
        data += [UInt8](repeating: 0, count: pad)
    }

    mutating func end() { data += [UInt8](repeating: 0, count: 2 * ustarBlock) }
}

func unpack(_ tar: [UInt8], into fs: FileSystem) throws(UstarError) -> UstarStats {
    // withUnsafeBytes rethrows untyped errors: carry the typed one out in a Result.
    let r = tar.withUnsafeBytes { buf -> Result<UstarStats, UstarError> in
        do throws(UstarError) { return .success(try unpackUstar(buf, into: fs)) } catch { return .failure(error) }
    }
    return try r.get()
}

@inline(never)
func ustarUnpacks() -> Bool {
    var tar = TarBuilder()
    tar.entry("./", type: 0x35)
    tar.entry("./docs/", type: 0x35)
    tar.entry("./docs/a.txt", Array(repeating: 0x61, count: 700)) // two data blocks
    tar.entry("./implicit/dir/b", bytes("b\n")) // parents made on the way
    tar.entry("./empty", type: 0x00)
    tar.entry("./link", type: 0x32) // symlink: skipped
    tar.entry("long-name", bytes("p"), prefix: "pre/fix")
    tar.end()
    let fs = FileSystem()
    guard let s = try? unpack(tar.data, into: fs) else { return false }
    return s == UstarStats(files: 4, directories: 1, bytes: 703, skipped: 1)
        && (try? fs.read("/docs/a.txt"))?.count == 700
        && (try? fs.read("/implicit/dir/b")) == bytes("b\n")
        && (try? fs.read("/pre/fix/long-name")) == bytes("p")
        && (try? fs.read("/empty")) == []
        && !fs.exists("/link")
}

@inline(never)
func ustarRejectsDamage() -> Bool {
    var tar = TarBuilder()
    tar.entry("./ok", bytes("fine"))
    tar.entry("./big", Array(repeating: 0x62, count: 1000))
    tar.end()
    var bad = tar.data
    bad[1024 + 10] ^= 1
    let truncated = Array(tar.data[..<(3 * ustarBlock + 100)]) // second body cut short
    var notTar = tar.data
    notTar[257] = 0x58 // magic
    let fs = FileSystem()
    var ok = true
    do throws(UstarError) { _ = try unpack(bad, into: fs); ok = false } catch { ok = ok && error == .badHeader(offset: 1024) }
    do throws(UstarError) { _ = try unpack(truncated, into: fs); ok = false } catch { ok = ok && error == .truncated(offset: 1024) }
    do throws(UstarError) { _ = try unpack(notTar, into: fs); ok = false } catch { ok = ok && error == .badHeader(offset: 0) }
    // A file where the archive needs a directory.
    var clash = TarBuilder()
    clash.entry("./x", bytes("file"))
    clash.entry("./x/y", bytes("under a file"))
    do throws(UstarError) { _ = try unpack(clash.data, into: fs); ok = false } catch {
        ok = ok && error == .conflict(offset: 1024, .notADirectory)
    }
    func octal(_ field: [UInt8]) -> Int? { field.withUnsafeBytes { ustarOctal($0) } }
    return ok && octal(bytes("  0017 \0")) == 15 && octal(bytes("0018\0")) == nil && octal(bytes("\0\0\0")) == nil
}

/// The packed rootfs/ arrived through the Limine module.
@inline(never)
func bootModuleLoaded() -> Bool {
    guard rootfsModule() != nil, let readme = try? vfs.read("/README"),
          let hello = try? vfs.lookup("/src/hello.swift") else { return false }
    return readme.starts(with: bytes("Wiffer RAM filesystem\n")) && hello.size > 0 && vfs.exists("/motd")
}

// MARK: Shell commands

/// Run `lines` on a scripted shell over `fs`; return its output (echoes dropped).
func fsTranscript(_ fs: FileSystem, _ lines: StaticString, cwd: String = "/") -> String {
    var sh = scriptedShell(chars(lines))
    sh.fs = fs
    sh.cwd = cwd
    while sh.term.next < sh.term.keys.count { sh.step() }
    var result = ""
    for l in outputLines(sh.term.take()) where l.utf8.first != 0x1B { result += l + "\n" }
    return result
}

@inline(never)
func fsCommandsWork() -> Bool {
    let fs = FileSystem()
    let made = fsTranscript(fs, "mkdir -p /a/b\rcd a\rpwd\rwrite b/f two  words\rcat b/f\rtouch e\rls\rls b /\rdf\r")
    guard made == "/a\ntwo  words\n          b/\n       0  e\nb:\n      11  f\n/:\n          a/\nfs: 11 bytes in 2 files, 3 directories\n" else {
        return false
    }
    // cwd /a: mv into a directory, then a relative rename; cd .. to /.
    let moved = fsTranscript(fs, "mv /a/b/f /a\rmv /a/f g\rls /a\rcat /a/g /a/e\rrm /a\rrm -r /a/b\rcd /a/e\rcd ..\rpwd\r", cwd: "/a")
    return moved == "          b/\n       0  e\n      11  g\ntwo  words\nrm: /a: directory not empty\ncd: /a/e: not a directory\n/\n"
        && !fs.exists("/a/b") && fs.usage == FileSystem.Usage(bytes: 11, files: 2, directories: 2)
}

@inline(never)
func fsCommandErrors() -> Bool {
    let fs = FileSystem()
    return fsTranscript(fs, "cat\rcat /x\rcd /x\rcd a b\rls /x\rmkdir\rmkdir /x/y\rrm\rrm /\rmv a\rmv /x /y\rtouch\rwrite\rcat /\r")
        == "usage: cat <file>...\ncat: /x: no such file or directory\ncd: /x: no such file or directory\nusage: cd [dir]\n"
        + "ls: /x: no such file or directory\nusage: mkdir [-p] <dir>...\nmkdir: /x/y: no such file or directory\n"
        + "usage: rm [-r] <path>...\nrm: /: invalid path\nusage: mv <from> <to>\nmv: /x: no such file or directory\n"
        + "usage: touch <file>...\nusage: write <file> <text>\ncat: /: is a directory\n"
}

/// Each shell keeps its own current directory over a shared tree.
@inline(never)
func perShellCwd() -> Bool {
    let fs = FileSystem()
    _ = try? fs.mkdir("/one")
    _ = try? fs.mkdir("/two")
    var a = scriptedShell(chars("cd /one\rwrite f from-a\r"))
    var b = scriptedShell(chars("cd /two\rwrite f from-b\r"))
    a.fs = fs
    b.fs = fs
    a.step(); b.step(); a.step(); b.step()
    return a.cwd == "/one" && b.cwd == "/two"
        && (try? fs.read("/one/f")) == bytes("from-a\n") && (try? fs.read("/two/f")) == bytes("from-b\n")
}

func fsTests(_ t: inout SelfTest) {
    let base = HeapUsage()
    t.check("copy-on-write: mutating a copied array leaves the original", copyOnWrite())
    t.check("fs: paths split, . and .. resolved, relative to cwd", pathResolution())
    t.check("fs: create/write/read/rename/list/remove and their errors", fsOperations())
    t.check("fs: create/write/rename/remove freed everything (live blocks)", HeapUsage() == base)
    t.check("fs: modification ticks advance", modificationTicks())
    t.check("ustar: files, dirs, prefix, multi-block, skipped types", ustarUnpacks())
    t.check("ustar: bad checksum, truncation, magic, clashes rejected", ustarRejectsDamage())
    t.check("ustar: boot module unpacked (/README, /src/hello.swift)", bootModuleLoaded())
    t.check("fs shell: mkdir -p, cd, pwd, write, cat, touch, ls, df", fsCommandsWork())
    t.check("fs shell: usage and error messages", fsCommandErrors())
    t.check("fs shell: each shell has its own cwd", perShellCwd())
    t.check("fs tests freed their memory", HeapUsage() == base)
}

/// Copy-on-write: mutating a copy must not touch the original. (Swift's own
/// LLVM ARC passes once moved the copy's retain after the inlined uniqueness
/// check, so both arrays changed: see -disable-swift-specific-llvm-optzns in
/// build.sh. The ustar damage test found it.)
@inline(never)
func copyOnWrite() -> Bool {
    let a = [UInt8](repeating: 0, count: 10)
    var b = a
    b[3] = 1
    var c = [Int](repeating: 0, count: 10)
    c.append(5)
    var d = c
    d[3] = 1
    var e = TarBuilder()
    e.entry("./x", bytes("y"))
    var f = e.data
    f[0] ^= 1
    return a[3] == 0 && b[3] == 1 && c[3] == 0 && d[3] == 1 && e.data[0] != f[0]
}
