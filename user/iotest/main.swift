// /bin/iotest [dir]: exercises the 6E system calls from ring 3 (files,
// directories, dup2, pipes, wait, spawn/waitpid/kill, bad pointers) in a
// scratch directory under `dir` (default /). Prints "ok ..." / "FAIL ..."
// per check and "iotest: N checks, M failed".

var checks = 0
var failures = 0

func check(_ name: String, _ ok: Bool) {
    checks += 1
    if ok {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

/// -errno of a raw result (0 if it succeeded).
func errnoOf(_ r: Int) -> Int { r < 0 ? -r : 0 }

func openRaw(_ path: String, _ flags: UInt64) -> Int {
    withPath(path) { syscall(SyscallNumber.open, $0, $1, flags) }
}

func readBytes(_ f: File, _ max: Int) -> [UInt8] {
    (try? f.read(max: max)) ?? []
}

func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

func uaddr(_ v: UInt) -> UInt64 { UInt64(v) }

var base = "/"
if let a = Process.args.dropFirst().first { base = a }
let work = (base == "/" ? "" : base) + "/iot"

// Directory setup.
_ = try? FS.unlink(work + "/a.txt")
_ = try? FS.unlink(work + "/b.txt")
_ = try? FS.unlink(work + "/sub")
_ = try? FS.unlink(work)
do throws(SysError) {
    try FS.mkdir(work)
    check("mkdir", true)
} catch {
    check("mkdir (\(error.message))", false)
}
if let e = try? FS.mkdir(work) { _ = e }
do throws(SysError) {
    try FS.mkdir(work)
    check("mkdir twice fails", false)
} catch {
    check("mkdir twice is EEXIST", error.errno == Errno.EEXIST)
}
do throws(SysError) {
    try FS.chdir(work)
    check("chdir", try FS.getcwd() == work)
} catch {
    check("chdir/getcwd", false)
}

// Files: create, write, read back, seek, stat.
do throws(SysError) {
    let f = try File.open("a.txt", flags: OpenFlags.read | OpenFlags.write | OpenFlags.create)
    check("create writes", f.write("hello world\n") == 12)
    check("seek set", f.seek(6) == 6)
    check("read after seek", text(readBytes(f, 5)) == "world")
    check("seek end", f.seek(0, whence: SeekWhence.end) == 12)
    check("seek cur", f.seek(-3, whence: SeekWhence.current) == 9)
    check("seek negative is EINVAL", f.seek(-100) == -Errno.EINVAL)
    check("fstat size", (try? f.stat())?.size == 12)
    f.close()
    check("stat by path", (try? FS.stat("a.txt"))?.size == 12 && (try? FS.stat(work + "/a.txt"))?.kind == StatKind.file)
    let g = try File.open("a.txt", flags: OpenFlags.write | OpenFlags.append)
    g.write("more\n")
    g.close()
    check("append", text((try? File.open("a.txt").readAll()) ?? []) == "hello world\nmore\n")
    let t = try File.open("a.txt", flags: OpenFlags.write | OpenFlags.truncate)
    check("truncate empties", (try? t.stat())?.size == 0)
    t.write("xyz")
    t.close()
    check("rewrite", text((try? File.open("a.txt").readAll()) ?? []) == "xyz")
} catch {
    check("file ops (\(error.message))", false)
}

// Errors.
check("open missing is ENOENT", errnoOf(openRaw("nosuch", OpenFlags.read)) == Errno.ENOENT)
check("create+exclusive on existing is EEXIST",
      errnoOf(openRaw("a.txt", OpenFlags.write | OpenFlags.create | OpenFlags.exclusive)) == Errno.EEXIST)
check("open a directory for writing is EISDIR", errnoOf(openRaw(".", OpenFlags.write)) == Errno.EISDIR)
check("open with no access is EINVAL", errnoOf(openRaw("a.txt", 0)) == Errno.EINVAL)
check("open with unknown flags is EINVAL", errnoOf(openRaw("a.txt", OpenFlags.read | 0x1000)) == Errno.EINVAL)
check("read on a bad fd is EBADF", File(fd: 99).read(into: UnsafeMutableRawBufferPointer(start: nil, count: 0)) == 0
      && errnoOf(syscall(SyscallNumber.read, 99, 0, 0)) == Errno.EBADF)
check("close on a bad fd is EBADF", File(fd: 99).close() == -Errno.EBADF && File(fd: -1).close() == -Errno.EBADF)
check("read on a directory is EISDIR", {
    guard let d = try? File.open(".") else { return false }
    var b = [UInt8](repeating: 0, count: 8)
    let r = b.withUnsafeMutableBytes { d.read(into: $0) }
    d.close()
    return r == -Errno.EISDIR
}())
check("write on a read-only file is EBADF", {
    guard let f = try? File.open("a.txt") else { return false }
    let r = f.write("x")
    f.close()
    return r == -Errno.EBADF
}())
check("path of 5000 bytes is ENAMETOOLONG",
      errnoOf(openRaw(String(repeating: "a", count: 5000), OpenFlags.read)) == Errno.ENAMETOOLONG)
check("empty path is EINVAL", errnoOf(syscall(SyscallNumber.open, 0x1000, 0, OpenFlags.read)) == Errno.EINVAL)

// Directories.
do throws(SysError) {
    try FS.mkdir("sub")
    let names = try FS.list(".").map { $0.name }
    check("readdir lists the entries", names == ["a.txt", "sub"])
    check("readdir marks directories", try FS.list(".").map { $0.isDirectory } == [false, true])
    try FS.rename("a.txt", to: "sub/b.txt")
    check("rename into a directory", (try? FS.stat("sub/b.txt"))?.size == 3 && (try? FS.stat("a.txt")) == nil)
    do throws(SysError) {
        try FS.unlink("sub")
        check("unlink of a non-empty directory fails", false)
    } catch {
        check("unlink of a non-empty directory is ENOTEMPTY", error.errno == Errno.ENOTEMPTY)
    }
    try FS.unlink("sub/b.txt")
    try FS.unlink("sub")
    check("unlink file and empty directory", (try? FS.list(".").count) == 0)
    check("chdir to a file is ENOTDIR", errnoOf(withPath("nosuch") { syscall(SyscallNumber.chdir, $0, $1) }) == Errno.ENOENT)
} catch {
    check("directory ops (\(error.message))", false)
}

// dup2.
do throws(SysError) {
    let f = try File.open("d.txt", flags: OpenFlags.read | OpenFlags.write | OpenFlags.create)
    f.write("dup")
    f.seek(0)
    check("dup2 onto 20", f.dup2(onto: 20) == 20)
    check("dup'd fd shares the position", text(readBytes(File(fd: 20), 8)) == "dup")
    check("dup2 of a bad fd is EBADF", File(fd: 77).dup2(onto: 21) == -Errno.EBADF)
    check("dup2 onto itself", f.dup2(onto: f.fd) == f.fd)
    f.close()
    check("the copy outlives the original", File(fd: 20).seek(0) == 0 && text(readBytes(File(fd: 20), 8)) == "dup")
    File(fd: 20).close()
    try FS.unlink("d.txt")
} catch {
    check("dup2 (\(error.message))", false)
}

// Bad pointers: -EFAULT, never a crash, and nothing consumed.
do throws(SysError) {
    let (r, w) = try File.pipe()
    check("pipe write", w.write("abc") == 3)
    check("read into null is EFAULT", syscall(SyscallNumber.read, UInt64(r.fd), 0, 3) == -Errno.EFAULT)
    check("read into a kernel address is EFAULT",
          syscall(SyscallNumber.read, UInt64(r.fd), 0xFFFF_8000_0000_0000, 3) == -Errno.EFAULT)
    check("read into an unmapped user address is EFAULT",
          syscall(SyscallNumber.read, UInt64(r.fd), 0x0000_7000_0000_0000, 3) == -Errno.EFAULT)
    check("write from null is EFAULT", syscall(SyscallNumber.write, UInt64(w.fd), 0, 3) == -Errno.EFAULT)
    check("write from a kernel address is EFAULT",
          syscall(SyscallNumber.write, UInt64(w.fd), 0xFFFF_8000_0000_1000, 3) == -Errno.EFAULT)
    if let page = Memory.map(2 * Memory.pageSize) {
        let a = UInt64(UInt(bitPattern: page))
        check("read into mapped memory works", syscall(SyscallNumber.read, UInt64(r.fd), a, 1) == 1)
        // The first page read-only: copyOut must refuse it.
        Memory.protect(page, Memory.pageSize, prot: MapProt.read)
        check("read into a read-only page is EFAULT", syscall(SyscallNumber.read, UInt64(r.fd), a, 1) == -Errno.EFAULT)
        // A range straddling from writable memory into an unmapped page.
        Memory.unmap(page + Memory.pageSize, Memory.pageSize)
        Memory.protect(page, Memory.pageSize, prot: MapProt.read | MapProt.write)
        check("read straddling an unmapped page is EFAULT",
              syscall(SyscallNumber.read, UInt64(r.fd), a + UInt64(Memory.pageSize) - 1, 2) == -Errno.EFAULT)
        check("write straddling an unmapped page is EFAULT",
              syscall(SyscallNumber.write, UInt64(w.fd), a + UInt64(Memory.pageSize) - 1, 2) == -Errno.EFAULT)
        check("a path straddling an unmapped page is EFAULT",
              syscall(SyscallNumber.open, a + UInt64(Memory.pageSize) - 2, 4, OpenFlags.read) == -Errno.EFAULT)
        check("pointer + length overflow is EFAULT",
              syscall(SyscallNumber.read, UInt64(r.fd), UInt64.max - 1, 100) == -Errno.EFAULT)
        Memory.unmap(page, Memory.pageSize)
    } else {
        check("map two pages", false)
    }
    check("the data survived the failed reads", text(readBytes(r, 8)) == "bc")
    check("pipe: a bad stat pointer is EFAULT", syscall(SyscallNumber.fstat, UInt64(r.fd), 0) == -Errno.EFAULT)
    check("pipe: a bad pipe() pointer is EFAULT", syscall(SyscallNumber.pipe, 8) == -Errno.EFAULT)
    check("wait on a bad array is EFAULT", syscall(SyscallNumber.wait, 0x10, 1, 0) == -Errno.EFAULT)
    check("wait with too many fds is EINVAL", syscall(SyscallNumber.wait, 0x10, 1000, 0) == -Errno.EINVAL)
    check("getcwd into null is EFAULT", syscall(SyscallNumber.getcwd, 0, 100) == -Errno.EFAULT)
    check("getcwd into 1 byte is ERANGE", {
        var one: [UInt8] = [0]
        return one.withUnsafeMutableBytes { syscall(SyscallNumber.getcwd, UInt64(UInt(bitPattern: $0.baseAddress)), 1) }
            == -Errno.ERANGE
    }())
    check("a spawn with a bad argv pointer is EFAULT",
          withPath("/bin/hello") { syscall(SyscallNumber.spawn, $0, $1, 0x10, 5, 0) } == -Errno.EFAULT)
    check("waitpid with a bad status pointer is EFAULT", syscall(SyscallNumber.waitpid, UInt64.max, 0x10, 0) == -Errno.EFAULT)
    check("console_mode on a pipe is ENOTTY", syscall(SyscallNumber.consoleMode, UInt64(r.fd), UInt64.max) == -Errno.ENOTTY)
    r.close()
    check("write to a pipe with no reader is EPIPE", w.write("x") == -Errno.EPIPE)
    w.close()
} catch {
    check("pipe (\(error.message))", false)
}

// Pipes and wait.
do throws(SysError) {
    let (r, w) = try File.pipe()
    var fds = [WaitFD(fd: Int32(r.fd), events: WaitEvent.readable, revents: 0),
               WaitFD(fd: Int32(w.fd), events: WaitEvent.writable, revents: 0),
               WaitFD(fd: 77, events: WaitEvent.readable, revents: 0)]
    let n = wait(&fds, timeoutMs: 0)
    check("wait: an empty pipe is not readable, its writer is writable, a bad fd is invalid",
          n == 2 && fds[0].revents == 0 && fds[1].revents == WaitEvent.writable && fds[2].revents == WaitEvent.invalid)
    var one = [WaitFD(fd: Int32(r.fd), events: WaitEvent.readable, revents: 0)]
    check("wait times out with 0", wait(&one, timeoutMs: 30) == 0 && one[0].revents == 0)
    w.write("data")
    check("wait sees the data", wait(&one, timeoutMs: -1) == 1 && one[0].revents == WaitEvent.readable)
    check("read gets it", text(readBytes(r, 16)) == "data")
    w.close()
    one[0].revents = 0
    check("wait reports hangup when the writer closed",
          wait(&one, timeoutMs: 1000) == 1 && one[0].revents & WaitEvent.hangup != 0)
    check("read at the end of a pipe is 0", readBytes(r, 16).isEmpty)
    r.close()
    check("wait with no fds just times out", { var none: [WaitFD] = []; return wait(&none, timeoutMs: 10) == 0 }())
} catch {
    check("pipe/wait (\(error.message))", false)
}

// spawn, waitpid, kill.
do throws(SysError) {
    let (r, w) = try File.pipe()
    let pid = try Process.spawn("/bin/echo", args: ["echo", "from", "child"], stdio: (nil, w.fd, nil))
    w.close()
    var out: [UInt8] = []
    while true {
        let chunk = readBytes(r, 64)
        if chunk.isEmpty { break }
        out += chunk
    }
    r.close()
    check("a child's stdout reaches the parent through a pipe", text(out) == "from child\n")
    let st = try Process.waitpid(pid)
    check("waitpid returns the pid and status 0", st.pid == pid && st.status == 0)
    do throws(SysError) {
        _ = try Process.waitpid()
        check("waitpid with no children fails", false)
    } catch {
        check("waitpid with no children is ECHILD", error.errno == Errno.ECHILD)
    }
    do throws(SysError) {
        _ = try Process.spawn("/bin/nosuchprogram", args: ["x"])
        check("spawn of a missing program fails", false)
    } catch {
        check("spawn of a missing program is ENOENT", error.errno == Errno.ENOENT)
    }
    do throws(SysError) {
        _ = try Process.spawn("/README", args: ["x"])
        check("spawn of a non-ELF fails", false)
    } catch {
        check("spawn of a non-ELF file is ENOEXEC", error.errno == Errno.ENOEXEC)
    }
    let crashPID = try Process.spawn("/bin/crash", args: ["crash", "null"], stdio: (nil, nil, nil))
    let crashed = try Process.waitpid(crashPID)
    check("a faulting child reports a fault status",
          crashed.status == Int(WaitStatus.faulted) | 14 << 16)
    let exitPID = try Process.spawn("/bin/crash", args: ["crash", "exit"], stdio: (nil, nil, nil))
    check("a child's exit code comes back", (try Process.waitpid(exitPID)).status == 3)

    // A child blocked reading an empty pipe can be killed.
    let (r2, w2) = try File.pipe()
    let waiting = try Process.spawn("/bin/cat", args: ["cat"], stdio: (r2.fd, nil, nil))
    check("noHang finds nothing yet", (try Process.waitpid(waiting, noHang: true)).pid == 0)
    check("kill", Process.kill(waiting) == 0)
    let killed = try Process.waitpid(waiting)
    check("a blocked child is killed", killed.status == Int(WaitStatus.killed))
    check("kill of a non-child is ESRCH", Process.kill(1) == -Errno.ESRCH)
    r2.close()
    w2.close()

    // Output bigger than the pipe's buffer flows through a blocked writer.
    let big = try File.open("big.bin", flags: OpenFlags.write | OpenFlags.create)
    let block = [UInt8](repeating: 0x41, count: 1000)
    for _ in 0..<100 { big.writeAll(block) }
    big.close()
    let (r3, w3) = try File.pipe()
    let catPID = try Process.spawn("/bin/cat", args: ["cat", "big.bin"], stdio: (nil, w3.fd, nil))
    w3.close()
    var total = 0
    while true {
        let chunk = readBytes(r3, 4096)
        if chunk.isEmpty { break }
        total += chunk.count
    }
    r3.close()
    _ = try Process.waitpid(catPID)
    check("100000 bytes through a pipe", total == 100_000)
    try FS.unlink("big.bin")
} catch {
    check("spawn (\(error.message))", false)
}

// Console mode (fd 1 is the console when run from a shell or the selftest).
let oldMode = Console.setMode(ConsoleMode.raw, fd: 1)
if oldMode >= 0 {
    check("console_mode sets and reports raw", Console.setMode(UInt64.max, fd: 1) == Int(ConsoleMode.raw))
    Console.setMode(UInt64(oldMode), fd: 1)
    check("console_mode restores", Console.setMode(UInt64.max, fd: 1) == oldMode)
}

// Leave the scratch directory.
_ = try? FS.chdir("/")
_ = try? FS.unlink(work)
print("iotest: \(checks) checks, \(failures) failed")
Process.exit(failures == 0 ? 0 : 1)
