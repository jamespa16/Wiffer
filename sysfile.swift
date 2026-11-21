// Phase 6E: the file, pipe, wait and process-control system calls.
//
// Every user pointer goes through copyIn/copyOut (syscall.swift); nothing
// here dereferences one, and every number a program passes (fds, lengths,
// counts, flags) is checked before use. Paths are (pointer, length) pairs,
// at most 4096 bytes, with no NUL, resolved against the process's cwd.
//
// Blocking: an object's tryRead/tryWrite never block (fileobject.swift);
// `blockingIO` registers the task on the object's wait list, re-checks
// readiness and parks, so a kill (which unparks) turns a blocked call into
// -EINTR. VFS work runs under onCPU0 (the filesystem is unlocked, CPU 0
// data); everything else runs on whatever CPU the process is on.

let maxPathBytes = 4096
let maxIOChunk = 64 * 1024
let maxWaitFDs = 64
let maxProcesses = 256
let maxChildren = 64

/// A path argument: the string, or nil (the caller answers -EFAULT/-EINVAL).
func userString(_ ptr: UInt64, _ len: UInt64) -> (String?, Int) {
    guard len > 0 else { return (nil, Errno.EINVAL) }
    guard len <= UInt64(maxPathBytes) else { return (nil, Errno.ENAMETOOLONG) }
    guard let bytes = copyIn(ptr, Int(len)) else { return (nil, Errno.EFAULT) }
    guard !bytes.contains(0) else { return (nil, Errno.EINVAL) }
    return (String(decoding: bytes, as: UTF8.self), 0)
}

func absolutePath(_ p: Process, _ path: String) -> String {
    FileSystem.normalize(path, cwd: p.cwd)
}

/// Run `attempt` until it stops saying `.wouldBlock`, parked in between.
/// A kill ends the wait with -EINTR.
func blockingIO(_ p: Process, _ file: FileObject, _ events: Int16, _ attempt: () -> IOResult) -> IOResult {
    while true {
        let r = file.needsCPU0 ? onCPU0(attempt) : attempt()
        if case .wouldBlock = r {} else { return r }
        if p.killRequested { return .error(Errno.EINTR) }
        guard let me = scheduler.current else { return .error(Errno.EINTR) }
        file.waits.add(me)
        if file.ready() & (events | WaitEvent.hangup) == 0 { park() }
        file.waits.remove(me)
        if p.killRequested { return .error(Errno.EINTR) }
    }
}

// MARK: open, close, read, write, seek, stat

func sysOpen(_ p: Process, _ pathPtr: UInt64, _ pathLen: UInt64, _ flagBits: UInt64) -> Int {
    let (maybe, err) = userString(pathPtr, pathLen)
    guard let raw = maybe else { return fail(err) }
    let known = OpenFlags.read | OpenFlags.write | OpenFlags.create | OpenFlags.truncate | OpenFlags.append
        | OpenFlags.exclusive
    guard flagBits & ~known == 0, flagBits & (OpenFlags.read | OpenFlags.write) != 0 else { return fail(Errno.EINVAL) }
    let wantsWrite = flagBits & OpenFlags.write != 0
    let path = absolutePath(p, raw)
    var file: VFSFile?
    var errno = 0
    onCPU0 {
        diskOperationLock.acquire()
        defer { diskOperationLock.release() }
        var node: FSNode? = try? vfs.lookup(path)
        if node == nil {
            guard flagBits & OpenFlags.create != 0 else { errno = Errno.ENOENT; return }
            do throws(FSError) {
                node = try vfs.create(path)
            } catch {
                errno = errnoFor(error)
                return
            }
        } else if flagBits & OpenFlags.create != 0 && flagBits & OpenFlags.exclusive != 0 {
            errno = Errno.EEXIST
            return
        }
        guard let n = node else { errno = Errno.ENOENT; return }
        if n.isDirectory && wantsWrite { errno = Errno.EISDIR; return }
        // Readable handles and writable snapshots must retain their bytes even
        // if the file is later unlinked. Truncation does not need old contents.
        if !n.isDirectory && !(wantsWrite && flagBits & OpenFlags.truncate != 0) {
            do throws(FSError) { _ = try n.readContents() }
            catch { errno = errnoFor(error); return }
        }
        file = VFSFile(node: n, path: path, read: flagBits & OpenFlags.read != 0, write: wantsWrite,
                       append: flagBits & OpenFlags.append != 0, truncate: flagBits & OpenFlags.truncate != 0)
    }
    guard let file else { return fail(errno) }
    guard let fd = p.fds.install(file) else { return fail(Errno.EMFILE) }
    return fd
}

func sysClose(_ p: Process, _ fd: UInt64) -> Int {
    guard fd < UInt64(FdTable.maxFDs), p.fds.close(Int(fd)) else { return fail(Errno.EBADF) }
    return 0
}

func sysRead(_ p: Process, _ fd: UInt64, _ buf: UInt64, _ len: UInt64) -> Int {
    guard fd < UInt64(FdTable.maxFDs), let file = p.fds.get(Int(fd)) else { return fail(Errno.EBADF) }
    guard len <= 1 << 40 else { return fail(Errno.EINVAL) }
    let n = min(Int(len), maxIOChunk)
    guard n > 0 else { return 0 }
    // Check the destination first: data taken from a pipe can't be put back.
    guard userRangeReady(p, UInt(buf), n, write: true) else { return fail(Errno.EFAULT) }
    switch blockingIO(p, file, WaitEvent.readable, { file.tryRead(n) }) {
    case .data(let bytes):
        guard copyOut(buf, bytes) else { return fail(Errno.EFAULT) }
        return bytes.count
    case .error(let e): return fail(e)
    default: return fail(Errno.EIO)
    }
}

func sysWrite(_ p: Process, _ fd: UInt64, _ buf: UInt64, _ len: UInt64) -> Int {
    guard fd < UInt64(FdTable.maxFDs), let file = p.fds.get(Int(fd)) else { return fail(Errno.EBADF) }
    guard len <= 1 << 30 else { return fail(Errno.EINVAL) }
    var done = 0
    while done < Int(len) {
        let n = min(Int(len) - done, maxIOChunk)
        guard let bytes = copyIn(buf + UInt64(done), n) else { return done > 0 ? done : fail(Errno.EFAULT) }
        var offset = 0
        while offset < n {
            let chunk = offset == 0 ? bytes : Array(bytes[offset...])
            switch blockingIO(p, file, WaitEvent.writable, { file.tryWrite(chunk) }) {
            case .count(let c): offset += c
            case .error(let e): return done + offset > 0 ? done + offset : fail(e)
            default: return done + offset > 0 ? done + offset : fail(Errno.EIO)
            }
        }
        done += n
        if p.killRequested { break }
    }
    return done
}

func sysSeek(_ p: Process, _ fd: UInt64, _ offset: UInt64, _ whence: UInt64) -> Int {
    guard fd < UInt64(FdTable.maxFDs), let file = p.fds.get(Int(fd)) else { return fail(Errno.EBADF) }
    let off = Int(Int64(bitPattern: offset))
    return file.needsCPU0 ? onCPU0 { file.seek(off, whence) } : file.seek(off, whence)
}

func copyOutStat(_ out: UInt64, _ info: StatInfo) -> Int {
    var s = info
    let bytes = withUnsafeBytes(of: &s) { Array($0) }
    return copyOut(out, bytes) ? 0 : fail(Errno.EFAULT)
}

func sysStat(_ p: Process, _ pathPtr: UInt64, _ pathLen: UInt64, _ out: UInt64) -> Int {
    let (maybe, err) = userString(pathPtr, pathLen)
    guard let raw = maybe else { return fail(err) }
    let path = absolutePath(p, raw)
    var info: StatInfo?
    onCPU0 {
        if let n = try? vfs.lookup(path) {
            info = StatInfo(size: UInt64(n.isDirectory ? 0 : n.size),
                            kind: n.isDirectory ? StatKind.directory : StatKind.file, modified: n.modified)
        }
    }
    guard let info else { return fail(Errno.ENOENT) }
    return copyOutStat(out, info)
}

func sysFstat(_ p: Process, _ fd: UInt64, _ out: UInt64) -> Int {
    guard fd < UInt64(FdTable.maxFDs), let file = p.fds.get(Int(fd)) else { return fail(Errno.EBADF) }
    let info = file.needsCPU0 ? onCPU0 { file.stat() } : file.stat()
    return copyOutStat(out, info)
}

func sysReaddir(_ p: Process, _ fd: UInt64, _ buf: UInt64, _ len: UInt64) -> Int {
    guard fd < UInt64(FdTable.maxFDs), let file = p.fds.get(Int(fd)) else { return fail(Errno.EBADF) }
    guard len <= 1 << 20 else { return fail(Errno.EINVAL) }
    guard userRangeReady(p, UInt(buf), Int(len), write: true) else { return fail(Errno.EFAULT) }
    let r = file.needsCPU0 ? onCPU0 { file.readdir(Int(len)) } : file.readdir(Int(len))
    switch r {
    case .data(let bytes):
        guard copyOut(buf, bytes) else { return fail(Errno.EFAULT) }
        return bytes.count
    case .error(let e): return fail(e)
    default: return fail(Errno.EIO)
    }
}

// MARK: Namespace operations

func sysMkdir(_ p: Process, _ pathPtr: UInt64, _ pathLen: UInt64) -> Int {
    let (maybe, err) = userString(pathPtr, pathLen)
    guard let raw = maybe else { return fail(err) }
    let path = absolutePath(p, raw)
    return onCPU0 { () -> Int in
        do throws(FSError) {
            _ = try vfs.mkdir(path)
            return 0
        } catch {
            return fail(errnoFor(error))
        }
    }
}

func sysUnlink(_ p: Process, _ pathPtr: UInt64, _ pathLen: UInt64) -> Int {
    let (maybe, err) = userString(pathPtr, pathLen)
    guard let raw = maybe else { return fail(err) }
    let path = absolutePath(p, raw)
    return onCPU0 { () -> Int in
        do throws(FSError) {
            try vfs.remove(path)
            return 0
        } catch {
            return fail(errnoFor(error))
        }
    }
}

func sysRename(_ p: Process, _ fromPtr: UInt64, _ fromLen: UInt64, _ toPtr: UInt64, _ toLen: UInt64) -> Int {
    let (a, e1) = userString(fromPtr, fromLen)
    guard let from = a else { return fail(e1) }
    let (b, e2) = userString(toPtr, toLen)
    guard let to = b else { return fail(e2) }
    let fromPath = absolutePath(p, from), toPath = absolutePath(p, to)
    return onCPU0 { () -> Int in
        do throws(FSError) {
            try vfs.rename(fromPath, to: toPath)
            return 0
        } catch {
            return fail(errnoFor(error))
        }
    }
}

func sysGetcwd(_ p: Process, _ buf: UInt64, _ len: UInt64) -> Int {
    let bytes = Array(p.cwd.utf8)
    guard len <= 1 << 20 else { return fail(Errno.EINVAL) }
    guard bytes.count <= Int(len) else { return fail(Errno.ERANGE) }
    return copyOut(buf, bytes) ? bytes.count : fail(Errno.EFAULT)
}

func sysChdir(_ p: Process, _ pathPtr: UInt64, _ pathLen: UInt64) -> Int {
    let (maybe, err) = userString(pathPtr, pathLen)
    guard let raw = maybe else { return fail(err) }
    let path = absolutePath(p, raw)
    let e = onCPU0 { () -> Int in
        guard let n = try? vfs.lookup(path) else { return Errno.ENOENT }
        return n.isDirectory ? 0 : Errno.ENOTDIR
    }
    guard e == 0 else { return fail(e) }
    p.cwd = path
    return 0
}

// MARK: dup2, pipe, console mode

func sysDup2(_ p: Process, _ old: UInt64, _ new: UInt64) -> Int {
    guard old < UInt64(FdTable.maxFDs), let file = p.fds.get(Int(old)) else { return fail(Errno.EBADF) }
    guard new < UInt64(FdTable.maxFDs) else { return fail(Errno.EBADF) }
    if old == new { return Int(new) }
    return p.fds.set(Int(new), file) ? Int(new) : fail(Errno.EBADF)
}

func sysPipe(_ p: Process, _ out: UInt64) -> Int {
    guard userRangeReady(p, UInt(out), 16, write: true) else { return fail(Errno.EFAULT) }
    let (r, w) = PipeEnd.make()
    guard let rfd = p.fds.install(r) else { return fail(Errno.EMFILE) }
    guard let wfd = p.fds.install(w) else {
        _ = p.fds.close(rfd)
        return fail(Errno.EMFILE)
    }
    var pair: [Int64] = [Int64(rfd), Int64(wfd)]
    let bytes = pair.withUnsafeMutableBytes { Array($0) }
    guard copyOut(out, bytes) else {
        _ = p.fds.close(rfd)
        _ = p.fds.close(wfd)
        return fail(Errno.EFAULT)
    }
    return 0
}

func sysConsoleMode(_ p: Process, _ fd: UInt64, _ mode: UInt64) -> Int {
    guard fd < UInt64(FdTable.maxFDs), let file = p.fds.get(Int(fd)) else { return fail(Errno.EBADF) }
    guard let ch = file.consoleChannel else { return fail(Errno.ENOTTY) }
    let flags = outputLock.acquireIRQ()
    let old = ch.mode
    if mode != UInt64.max {
        ch.mode = mode & (ConsoleMode.raw | ConsoleMode.passInterrupt)
        if ch.mode & ConsoleMode.raw != 0 { ch.line = [] }
    }
    outputLock.releaseIRQ(flags)
    return Int(old)
}

// MARK: wait

/// wait(fds, count, timeoutMs): the poll-like multiplexer.
func sysWait(_ p: Process, _ fdsPtr: UInt64, _ count: UInt64, _ timeout: UInt64) -> Int {
    guard count <= UInt64(maxWaitFDs) else { return fail(Errno.EINVAL) }
    let n = Int(count)
    var entries: [WaitFD] = []
    if n > 0 {
        guard let raw = copyIn(fdsPtr, n * 8) else { return fail(Errno.EFAULT) }
        // Writable too, so a bad pointer fails now, not after the wait.
        guard userRangeReady(p, UInt(fdsPtr), n * 8, write: true) else { return fail(Errno.EFAULT) }
        for i in 0..<n {
            let b = i * 8
            let fd = Int32(bitPattern: UInt32(raw[b]) | UInt32(raw[b + 1]) << 8 | UInt32(raw[b + 2]) << 16
                           | UInt32(raw[b + 3]) << 24)
            let ev = Int16(bitPattern: UInt16(raw[b + 4]) | UInt16(raw[b + 5]) << 8)
            entries.append(WaitFD(fd: fd, events: ev, revents: 0))
        }
    }
    let timeoutMs = Int64(bitPattern: timeout)
    var deadline: UInt64? = nil
    if timeoutMs >= 0 { deadline = deadlineAfter(ms: min(UInt64(timeoutMs), 1 << 40)) }
    var objects: [FileObject?] = []
    for e in entries { objects.append(e.fd >= 0 ? p.fds.get(Int(e.fd)) : nil) }

    /// Fill in revents; how many fds are ready.
    func poll() -> Int {
        var ready = 0
        for i in 0..<entries.count {
            guard let o = objects[i] else {
                entries[i].revents = WaitEvent.invalid
                ready += 1
                continue
            }
            let r = o.ready()
            entries[i].revents = (r & entries[i].events) | (r & WaitEvent.hangup)
            if entries[i].revents != 0 { ready += 1 }
        }
        return ready
    }

    var result = 0
    while true {
        guard let me = scheduler.current else { return fail(Errno.EINTR) }
        for o in objects { o?.waits.add(me) }
        result = poll()
        let timedOut = timeoutMs == 0 || (deadline != nil && ticks >= deadline!)
        var interrupted = false
        if result == 0 && !timedOut {
            if p.killRequested {
                interrupted = true
            } else if let deadline {
                _ = parkUntil(deadline)
            } else {
                park()
            }
        }
        for o in objects { o?.waits.remove(me) }
        if interrupted { return fail(Errno.EINTR) }
        if result > 0 || timedOut || (deadline != nil && ticks >= deadline!) {
            if result == 0 { result = poll() }
            break
        }
        if p.killRequested { return fail(Errno.EINTR) }
    }
    var out: [UInt8] = []
    for e in entries {
        let fd = UInt32(bitPattern: e.fd), ev = UInt16(bitPattern: e.events), rv = UInt16(bitPattern: e.revents)
        out += [UInt8(truncatingIfNeeded: fd), UInt8(truncatingIfNeeded: fd >> 8), UInt8(truncatingIfNeeded: fd >> 16),
                UInt8(truncatingIfNeeded: fd >> 24), UInt8(truncatingIfNeeded: ev), UInt8(truncatingIfNeeded: ev >> 8),
                UInt8(truncatingIfNeeded: rv), UInt8(truncatingIfNeeded: rv >> 8)]
    }
    if !out.isEmpty && !copyOut(fdsPtr, out) { return fail(Errno.EFAULT) }
    return result
}

// MARK: spawn, waitpid, kill

func errnoFor(_ e: ExecError) -> Int {
    switch e {
    case .notFound: return Errno.ENOENT
    case .notExecutable: return Errno.ENOEXEC
    case .noMemory: return Errno.ENOMEM
    case .tooManyArguments: return Errno.E2BIG
    }
}

/// spawn(path, pathLen, argv, argvLen, fds) -> pid.
func sysSpawn(_ p: Process, _ pathPtr: UInt64, _ pathLen: UInt64, _ argvPtr: UInt64, _ argvLen: UInt64,
              _ fdsPtr: UInt64) -> Int {
    let (maybe, err) = userString(pathPtr, pathLen)
    guard let path = maybe else { return fail(err) }
    guard argvLen <= UInt64(UserLayout.maxArgBytes) else { return fail(Errno.E2BIG) }
    var argv: [String] = []
    if argvLen > 0 {
        guard let blob = copyIn(argvPtr, Int(argvLen)) else { return fail(Errno.EFAULT) }
        guard blob.last == 0 else { return fail(Errno.EINVAL) }
        for part in blob.dropLast().split(separator: 0, omittingEmptySubsequences: false) {
            argv.append(String(decoding: part, as: UTF8.self))
        }
    }
    guard argv.count <= UserLayout.maxArgs else { return fail(Errno.E2BIG) }
    if argv.isEmpty { argv = [path] }
    var stdio: [FileObject?] = []
    if fdsPtr == 0 {
        for i in 0..<3 { stdio.append(p.fds.get(i)) }
    } else {
        guard let raw = copyIn(fdsPtr, 24) else { return fail(Errno.EFAULT) }
        for i in 0..<3 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(raw[i * 8 + k]) << UInt64(8 * k) }
            let fd = Int64(bitPattern: v)
            if fd == -1 {
                stdio.append(nil)
            } else {
                guard fd >= 0, fd < Int64(FdTable.maxFDs), let o = p.fds.get(Int(fd)) else { return fail(Errno.EBADF) }
                stdio.append(o)
            }
        }
    }
    let (total, kids) = onCPU0 { (processTable.count, p.children.count) }
    guard total < maxProcesses, kids < maxChildren else { return fail(Errno.EAGAIN) }
    do throws(ExecError) {
        let child = try spawnProcess(path: path, cwd: p.cwd, argv: argv, output: p.output, waiter: p.thread,
                                     stdio: stdio)
        return child.pid
    } catch {
        return fail(errnoFor(error))
    }
}

func waitStatusValue(_ s: ExitStatus?) -> Int64 {
    switch s {
    case .exited(let n)?: return Int64(n & 0xFF)
    case .faulted(let v)?: return WaitStatus.faulted | Int64(v) << 16
    default: return WaitStatus.killed
    }
}

/// waitpid(pid, statusOut, flags).
func sysWaitpid(_ p: Process, _ pidArg: UInt64, _ statusOut: UInt64, _ flags: UInt64) -> Int {
    guard flags & ~WaitFlag.noHang == 0 else { return fail(Errno.EINVAL) }
    let want = Int(Int64(bitPattern: pidArg))
    guard want == -1 || want > 0 else { return fail(Errno.EINVAL) }
    if statusOut != 0 && !userRangeReady(p, UInt(statusOut), 8, write: true) { return fail(Errno.EFAULT) }
    while true {
        // 0: nothing yet; >0: a reaped pid; <0: -errno.
        var reaped = 0
        var status: Int64 = 0
        onCPU0 {
            var any = false
            for c in p.children where want == -1 || c == want {
                guard let child = findProcess(c) else { continue }
                any = true
                if child.state == .zombie {
                    status = waitStatusValue(child.status)
                    reaped = child.pid
                    child.waiter = nil
                    reap(child)
                    return
                }
            }
            if !any { reaped = -Errno.ECHILD }
        }
        if reaped < 0 { return reaped }
        if reaped > 0 {
            if statusOut != 0 {
                var v = status
                let bytes = withUnsafeBytes(of: &v) { Array($0) }
                guard copyOut(statusOut, bytes) else { return fail(Errno.EFAULT) }
            }
            return reaped
        }
        if flags & WaitFlag.noHang != 0 { return 0 }
        if p.killRequested { return fail(Errno.EINTR) }
        park() // the child's exit unparks its waiter, this thread
    }
}

func sysKill(_ p: Process, _ pidArg: UInt64) -> Int {
    guard pidArg > 0, pidArg < UInt64(1 << 40) else { return fail(Errno.EINVAL) }
    let pid = Int(pidArg)
    let ok = onCPU0 { () -> Bool in
        guard pid == p.pid || p.children.contains(pid) else { return false }
        return killProcess(pid)
    }
    return ok ? 0 : fail(Errno.ESRCH)
}
