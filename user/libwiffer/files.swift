// libwiffer, Phase 6E: files, directories, pipes, wait and child processes
// (the syscalls of sysfile.swift in Swift).
//
//   File.open(path, flags:)     throws(SysError) -> File; read/write/seek/
//                               close/stat; File.stdin/.stdout/.stderr
//   file.readAll()              the rest of the file as [UInt8]
//   File.pipe()                 (read, write)
//   file.dup2(onto:)
//   FS.list(path)               [DirEntry], sorted as the kernel gives them
//   FS.stat/mkdir/unlink/rename/getcwd/chdir
//   wait(&fds, timeoutMs:)      poll-like multiplexer; WaitFD, WaitEvent
//   Console.setMode(_:)         ConsoleMode.raw / .passInterrupt; returns the old mode
//   Process.spawn/waitpid/kill  child processes, with optional fds for 0-2
//
// Errors are `SysError(errno)`; `message` matches the shell's wording
// ("no such file or directory"). Raw results (read, write, seek) are
// negative errno values, like the syscalls.

struct SysError: Error {
    let errno: Int

    var message: String { errnoMessage(errno) }
}

func errnoMessage(_ e: Int) -> String {
    switch e {
    case Errno.ENOENT: return "no such file or directory"
    case Errno.EEXIST: return "already exists"
    case Errno.ENOTDIR: return "not a directory"
    case Errno.EISDIR: return "is a directory"
    case Errno.ENOTEMPTY: return "directory not empty"
    case Errno.EINVAL: return "invalid path"
    case Errno.EIO: return "I/O error"
    case Errno.ENOSPC: return "no space left on device"
    case Errno.EXDEV: return "can't move across filesystems"
    case Errno.EBUSY: return "mount point busy"
    case Errno.EBADF: return "bad file descriptor"
    case Errno.EFAULT: return "bad address"
    case Errno.EPIPE: return "broken pipe"
    case Errno.EINTR: return "interrupted"
    case Errno.EMFILE: return "too many open files"
    case Errno.ENOMEM: return "out of memory"
    case Errno.ENOEXEC: return "not an executable"
    case Errno.ENAMETOOLONG: return "name too long"
    default: return "error \(e)"
    }
}

/// Call `body` with a string's UTF-8 bytes as (address, length).
func withPath<R>(_ s: String, _ body: (UInt64, UInt64) -> R) -> R {
    var copy = s
    return copy.withUTF8 { b in
        body(UInt64(UInt(bitPattern: b.baseAddress)), UInt64(b.count))
    }
}

func checked(_ r: Int) throws(SysError) -> Int {
    if r < 0 { throw SysError(errno: -r) }
    return r
}

extension File {
    static let stdin = File(fd: 0)

    /// The fd as a syscall argument (any Int, even a bad one, is representable).
    var fdArg: UInt64 { UInt64(bitPattern: Int64(fd)) }

    static func open(_ path: String, flags: UInt64 = OpenFlags.read) throws(SysError) -> File {
        let r = withPath(path) { syscall(SyscallNumber.open, $0, $1, flags) }
        return File(fd: try checked(r))
    }

    /// Bytes read (0: end of file), or -errno.
    func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        return syscall(SyscallNumber.read, fdArg, UInt64(UInt(bitPattern: base)), UInt64(buffer.count))
    }

    /// Up to `max` bytes (empty at end of file).
    func read(max: Int) throws(SysError) -> [UInt8] {
        var failure = 0
        let bytes = [UInt8](unsafeUninitializedCapacity: max) { buf, count in
            let r = read(into: UnsafeMutableRawBufferPointer(buf))
            if r < 0 { failure = -r; count = 0 } else { count = r }
        }
        if failure != 0 { throw SysError(errno: failure) }
        return bytes
    }

    /// Everything up to end of file.
    func readAll() throws(SysError) -> [UInt8] {
        var out: [UInt8] = []
        while true {
            let chunk = try read(max: 4096)
            if chunk.isEmpty { return out }
            out.append(contentsOf: chunk)
        }
    }

    /// Write all of `bytes` (a loop over short writes). Negative errno on failure.
    @discardableResult
    func writeAll(_ bytes: [UInt8]) -> Int {
        var done = 0
        while done < bytes.count {
            let r = bytes.withUnsafeBytes { raw in
                sysWrite(fd, raw.baseAddress! + done, raw.count - done)
            }
            if r < 0 { return r }
            if r == 0 { break }
            done += r
        }
        return done
    }

    @discardableResult
    func close() -> Int { syscall(SyscallNumber.close, fdArg) }

    /// New position, or -errno.
    @discardableResult
    func seek(_ offset: Int, whence: UInt64 = SeekWhence.set) -> Int {
        syscall(SyscallNumber.seek, fdArg, UInt64(bitPattern: Int64(offset)), whence)
    }

    func stat() throws(SysError) -> StatInfo {
        var info = StatInfo()
        let r = withUnsafeMutablePointer(to: &info) { syscall(SyscallNumber.fstat, fdArg, UInt64(UInt(bitPattern: $0))) }
        _ = try checked(r)
        return info
    }

    /// Make `onto` refer to this file too (closing what it was).
    @discardableResult
    func dup2(onto: Int) -> Int { syscall(SyscallNumber.dup2, fdArg, UInt64(bitPattern: Int64(onto))) }

    static func pipe() throws(SysError) -> (read: File, write: File) {
        var pair: [Int64] = [0, 0]
        let r = pair.withUnsafeMutableBytes { syscall(SyscallNumber.pipe, UInt64(UInt(bitPattern: $0.baseAddress))) }
        _ = try checked(r)
        return (File(fd: Int(pair[0])), File(fd: Int(pair[1])))
    }

    /// A directory opened with open(): the entries, until the end.
    func readDirectory() throws(SysError) -> [DirEntry] {
        var entries: [DirEntry] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes {
                syscall(SyscallNumber.readdir, fdArg, UInt64(UInt(bitPattern: $0.baseAddress)), UInt64($0.count))
            }
            let got = try checked(n)
            if got == 0 { return entries }
            var at = 0
            while at + DirRecord.headerSize <= got {
                let kind = UInt64(buffer[at])
                let nameLen = Int(buffer[at + 1])
                var size: UInt64 = 0
                for i in 0..<8 { size |= UInt64(buffer[at + 8 + i]) << UInt64(8 * i) }
                let name = String(decoding: buffer[(at + DirRecord.headerSize)..<(at + DirRecord.headerSize + nameLen)],
                                  as: UTF8.self)
                entries.append(DirEntry(name: name, kind: kind, size: size))
                at += (DirRecord.headerSize + nameLen + 7) & ~7
            }
        }
    }
}

struct DirEntry {
    let name: String
    /// StatKind.file or .directory.
    let kind: UInt64
    let size: UInt64

    var isDirectory: Bool { kind == StatKind.directory }
}

enum FS {
    static func stat(_ path: String) throws(SysError) -> StatInfo {
        var info = StatInfo()
        let r = withPath(path) { p, n in
            withUnsafeMutablePointer(to: &info) { syscall(SyscallNumber.stat, p, n, UInt64(UInt(bitPattern: $0))) }
        }
        _ = try checked(r)
        return info
    }

    static func list(_ path: String) throws(SysError) -> [DirEntry] {
        let dir = try File.open(path)
        defer { dir.close() }
        return try dir.readDirectory()
    }

    static func mkdir(_ path: String) throws(SysError) {
        _ = try checked(withPath(path) { syscall(SyscallNumber.mkdir, $0, $1) })
    }

    /// Remove a file or an empty directory.
    static func unlink(_ path: String) throws(SysError) {
        _ = try checked(withPath(path) { syscall(SyscallNumber.unlink, $0, $1) })
    }

    static func rename(_ from: String, to: String) throws(SysError) {
        let r = withPath(from) { a, an in withPath(to) { b, bn in syscall(SyscallNumber.rename, a, an, b, bn) } }
        _ = try checked(r)
    }

    static func getcwd() throws(SysError) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBytes {
            syscall(SyscallNumber.getcwd, UInt64(UInt(bitPattern: $0.baseAddress)), UInt64($0.count))
        }
        return String(decoding: buffer[0..<(try checked(n))], as: UTF8.self)
    }

    static func chdir(_ path: String) throws(SysError) {
        _ = try checked(withPath(path) { syscall(SyscallNumber.chdir, $0, $1) })
    }
}

/// wait(fds, timeout): how many entries have `revents` set (0: timed out).
/// `timeoutMs` -1 waits forever, 0 only polls. Negative: -errno.
func wait(_ fds: inout [WaitFD], timeoutMs: Int) -> Int {
    fds.withUnsafeMutableBytes {
        syscall(SyscallNumber.wait, UInt64(UInt(bitPattern: $0.baseAddress)), UInt64($0.count / 8),
                UInt64(bitPattern: Int64(timeoutMs)))
    }
}

enum Console {
    /// Set the console mode of fd 0 (ConsoleMode bits); the old mode, or -errno.
    @discardableResult
    static func setMode(_ mode: UInt64, fd: Int = 0) -> Int {
        syscall(SyscallNumber.consoleMode, UInt64(bitPattern: Int64(fd)), mode)
    }
}

extension Process {
    /// Start /bin/x or any path with `args` (args[0] first). `stdio` gives
    /// this process's fds for the child's 0, 1, 2 (nil: the child gets none);
    /// without it the child inherits 0-2. Returns the pid.
    static func spawn(_ path: String, args: [String], stdio: (Int?, Int?, Int?)? = nil) throws(SysError) -> Int {
        var blob: [UInt8] = []
        for a in args {
            blob.append(contentsOf: Array(a.utf8))
            blob.append(0)
        }
        var fds: [Int64] = []
        if let s = stdio { fds = [Int64(s.0 ?? -1), Int64(s.1 ?? -1), Int64(s.2 ?? -1)] }
        let r = withPath(path) { p, n in
            blob.withUnsafeBytes { b in
                fds.withUnsafeBytes { f in
                    syscall(SyscallNumber.spawn, p, n, UInt64(UInt(bitPattern: b.baseAddress)), UInt64(b.count),
                            stdio == nil ? 0 : UInt64(UInt(bitPattern: f.baseAddress)))
                }
            }
        }
        return try checked(r)
    }

    /// Wait for a child (pid -1: any). Returns (pid, status); status is
    /// the exit code, or 0x100 | vector << 16 for a fault, or 0x200 killed
    /// (WaitStatus). With `noHang`, pid 0 means none has exited yet.
    static func waitpid(_ pid: Int = -1, noHang: Bool = false) throws(SysError) -> (pid: Int, status: Int) {
        var status: Int64 = 0
        let r = withUnsafeMutablePointer(to: &status) {
            syscall(SyscallNumber.waitpid, UInt64(bitPattern: Int64(pid)), UInt64(UInt(bitPattern: $0)),
                    noHang ? WaitFlag.noHang : 0)
        }
        return (try checked(r), Int(status))
    }

    @discardableResult
    static func kill(_ pid: Int) -> Int { syscall(SyscallNumber.kill, UInt64(pid)) }
}
