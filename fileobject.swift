// Phase 6E1: file objects and file descriptors.
//
// A process's fds are slots of `FdTable`, each holding a `FileObject`. The
// class hierarchy: VFSFile (a file or directory of the VFS), ConsoleFile
// (fds 0-2: the terminal that started the program), PipeEnd; 6F's windows
// and 7E's sockets subclass it too.
//
// The interface a subclass implements (everything but `ready` and the
// waiter list is optional; the defaults fail with -EBADF/-ESPIPE):
//
//   tryRead(max)     -> .data(bytes) (empty = end of file) / .wouldBlock / .error
//   tryWrite(bytes)  -> .count(n) / .wouldBlock / .error
//   ready()          -> WaitEvent bits (readable, writable, hangup): what
//                       would not block right now
//   waits            -> the WaitList to register on; call `waits.wake()` (or
//                       `notify()`) whenever `ready()` may have changed
//   lastClose()      -> the last fd referring to it closed
//   needsCPU0        -> true if tryRead/tryWrite/... touch CPU-0-only data
//                       (the VFS): the syscall layer hops there first
//
// Methods never block: the syscall layer (sysfile.swift) loops, registering
// the task on `waits`, re-checking `ready()` and parking, so one mechanism
// serves read, write and `wait`. Methods may be called on any CPU, so an
// object that isn't CPU-0-only needs its own lock.
//
// References: each fd slot holds one count (`fdRefs`), plus any a kernel
// owner takes with `addRef` (the shell, while it builds a pipeline). The
// object's `lastClose` runs when the count returns to zero, which is how a
// pipe learns that its last writer is gone.

enum IOResult {
    case data([UInt8])
    case count(Int)
    case wouldBlock
    case error(Int)
}

/// Tasks waiting for a file's readiness to change. Short critical sections;
/// never held while unparking.
final class WaitList {
    var lock = SpinLock()
    var tasks: [Task] = []

    func add(_ t: Task) {
        let flags = lock.acquireIRQ()
        tasks.append(t)
        lock.releaseIRQ(flags)
    }

    func remove(_ t: Task) {
        let flags = lock.acquireIRQ()
        if let i = tasks.firstIndex(where: { $0 === t }) { tasks.remove(at: i) }
        lock.releaseIRQ(flags)
    }

    func wake() {
        let flags = lock.acquireIRQ()
        let list = tasks
        lock.releaseIRQ(flags)
        for t in list { unpark(t) }
    }
}

var fileRefLock = SpinLock()

class FileObject {
    /// Open fd slots (and kernel owners) referring to this object.
    var fdRefs = 0
    private let ownWaits = WaitList()
    var waits: WaitList { ownWaits }

    func tryRead(_ max: Int) -> IOResult { .error(Errno.EBADF) }
    func tryWrite(_ bytes: [UInt8]) -> IOResult { .error(Errno.EBADF) }
    /// What would not block now (WaitEvent bits).
    func ready() -> Int16 { 0 }
    func seek(_ offset: Int, _ whence: UInt64) -> Int { fail(Errno.ESPIPE) }
    func stat() -> StatInfo { StatInfo(size: 0, kind: StatKind.device, modified: 0) }
    /// Whole DirRecords that fit in `max` bytes; empty at the end.
    func readdir(_ max: Int) -> IOResult { .error(Errno.ENOTDIR) }
    func lastClose() {}
    var needsCPU0: Bool { false }
    /// The console behind this object, if it is one (console_mode).
    var consoleChannel: ConsoleChannel? { nil }

    func notify() { waits.wake() }

    func addRef() {
        let flags = fileRefLock.acquireIRQ()
        fdRefs += 1
        fileRefLock.releaseIRQ(flags)
    }

    /// Drop one count; the last one runs `lastClose` (on CPU 0 if needed).
    func dropRef() {
        let flags = fileRefLock.acquireIRQ()
        fdRefs -= 1
        let last = fdRefs == 0
        fileRefLock.releaseIRQ(flags)
        guard last else { return }
        if needsCPU0 { onCPU0 { self.lastClose() } } else { lastClose() }
    }
}

// MARK: The fd table

struct FdTable {
    static let maxFDs = 256
    var slots: [FileObject?] = []

    func get(_ fd: Int) -> FileObject? {
        fd >= 0 && fd < slots.count ? slots[fd] : nil
    }

    var openCount: Int {
        var n = 0
        for s in slots where s != nil { n += 1 }
        return n
    }

    /// Put `object` in the lowest free slot at or above `from`; nil if the
    /// table is full.
    mutating func install(_ object: FileObject, from: Int = 0) -> Int? {
        var fd = from
        while fd < slots.count && slots[fd] != nil { fd += 1 }
        guard fd < FdTable.maxFDs else { return nil }
        while slots.count <= fd { slots.append(nil) }
        object.addRef()
        slots[fd] = object
        return fd
    }

    /// Put `object` in slot `fd`, closing what was there.
    mutating func set(_ fd: Int, _ object: FileObject) -> Bool {
        guard fd >= 0 && fd < FdTable.maxFDs else { return false }
        while slots.count <= fd { slots.append(nil) }
        object.addRef()
        let old = slots[fd]
        slots[fd] = object
        old?.dropRef()
        return true
    }

    mutating func close(_ fd: Int) -> Bool {
        guard fd >= 0 && fd < slots.count, let o = slots[fd] else { return false }
        slots[fd] = nil
        o.dropRef()
        return true
    }

    mutating func closeAll() {
        let old = slots
        slots = []
        for o in old { o?.dropRef() }
    }
}

// MARK: Errors

func errnoFor(_ e: FSError) -> Int {
    switch e {
    case .notFound: return Errno.ENOENT
    case .exists: return Errno.EEXIST
    case .notADirectory: return Errno.ENOTDIR
    case .isADirectory: return Errno.EISDIR
    case .notEmpty: return Errno.ENOTEMPTY
    case .invalidPath, .invalidName, .invalidMove, .notMounted: return Errno.EINVAL
    case .io, .corrupt: return Errno.EIO
    case .noSpace: return Errno.ENOSPC
    case .crossDevice: return Errno.EXDEV
    case .busy: return Errno.EBUSY
    }
}

// MARK: VFSFile

/// A file or directory of the VFS, opened. CPU 0 only (needsCPU0). A file
/// opened for writing works on a private copy of the bytes and writes it
/// through (`vfs.write`, which reaches /disk) when its last fd closes.
final class VFSFile: FileObject {
    let node: FSNode
    /// Absolute path, for the write-back.
    let path: String
    let canRead: Bool
    let canWrite: Bool
    let append: Bool
    var position = 0
    /// The working copy of a file opened for writing.
    var copy: [UInt8] = []
    var dirty = false
    /// A handle that only extends its original snapshot can commit the delta.
    private var appendOnly = true
    private var originalSize = 0
    private var originalRevision: UInt64 = 0
    private var appendDelta: [UInt8]?
    /// A directory's entries, taken at the first readdir.
    var entries: [FSNode]?
    var entryIndex = 0

    init(node: FSNode, path: String, read: Bool, write: Bool, append: Bool, truncate: Bool) {
        self.node = node
        self.path = path
        canRead = read
        canWrite = write
        self.append = append
        super.init()
        if write && !node.isDirectory {
            copy = truncate ? [] : node.contents
            dirty = truncate
            appendOnly = !truncate
            originalSize = copy.count
            originalRevision = node.contentRevision
            if append && !read && !truncate { appendDelta = [] }
        }
    }

    override var needsCPU0: Bool { true }
    var size: Int { canWrite ? (appendDelta.map { originalSize + $0.count } ?? copy.count) : node.size }

    override func ready() -> Int16 { WaitEvent.readable | WaitEvent.writable }

    override func tryRead(_ max: Int) -> IOResult {
        guard canRead else { return .error(Errno.EBADF) }
        guard !node.isDirectory else { return .error(Errno.EISDIR) }
        let n = min(max, size - position)
        guard n > 0 else { return .data([]) }
        let out = canWrite ? Array(copy[position..<position + n]) : Array(node.contents[position..<position + n])
        position += n
        return .data(out)
    }

    override func tryWrite(_ bytes: [UInt8]) -> IOResult {
        guard canWrite else { return .error(Errno.EBADF) }
        if appendDelta != nil {
            guard bytes.count <= (1 << 30) - size else { return .error(Errno.ENOSPC) }
            appendDelta!.append(contentsOf: bytes)
            position = size
            dirty = true
            return .count(bytes.count)
        }
        if append { position = copy.count }
        if position < copy.count { appendOnly = false }
        guard position <= 1 << 30, bytes.count <= 1 << 30 else { return .error(Errno.ENOSPC) }
        if position > copy.count { copy += [UInt8](repeating: 0, count: position - copy.count) }
        let end = position + bytes.count
        if end > copy.count { copy += [UInt8](repeating: 0, count: end - copy.count) }
        for i in 0..<bytes.count { copy[position + i] = bytes[i] }
        position = end
        dirty = true
        return .count(bytes.count)
    }

    override func seek(_ offset: Int, _ whence: UInt64) -> Int {
        guard !node.isDirectory else { return fail(Errno.ESPIPE) }
        var base = 0
        switch whence {
        case SeekWhence.set: base = 0
        case SeekWhence.current: base = position
        case SeekWhence.end: base = size
        default: return fail(Errno.EINVAL)
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, target >= 0, target <= 1 << 40 else { return fail(Errno.EINVAL) }
        position = target
        return target
    }

    override func stat() -> StatInfo {
        StatInfo(size: UInt64(node.isDirectory ? 0 : size), kind: node.isDirectory ? StatKind.directory : StatKind.file,
                 modified: node.modified)
    }

    override func readdir(_ max: Int) -> IOResult {
        guard node.isDirectory else { return .error(Errno.ENOTDIR) }
        if entries == nil { entries = node.sortedChildren }
        var out: [UInt8] = []
        while entryIndex < entries!.count {
            let e = entries![entryIndex]
            let name = Array(e.name.utf8.prefix(255))
            let total = (DirRecord.headerSize + name.count + 7) & ~7
            if out.count + total > max { break }
            out.append(e.isDirectory ? UInt8(StatKind.directory) : UInt8(StatKind.file))
            out.append(UInt8(name.count))
            out += [0, 0, 0, 0, 0, 0]
            let size = UInt64(e.isDirectory ? 0 : e.size)
            for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: size >> UInt64(8 * i))) }
            out += name
            while out.count % 8 != 0 { out.append(0) }
            entryIndex += 1
        }
        if out.isEmpty && entryIndex < entries!.count { return .error(Errno.EINVAL) } // buffer too small
        return .data(out)
    }

    override func lastClose() {
        diskOperationLock.acquire()
        defer { diskOperationLock.release() }
        guard dirty else { return }
        dirty = false
        // Not if it was removed or replaced while open.
        guard let now = try? vfs.lookup(path), now === node else { return }
        // Concurrent modifications preserve the previous replacement semantics;
        // the delta path applies only while the original snapshot is current.
        if appendOnly && node.contentRevision == originalRevision {
            let delta = appendDelta ?? Array(copy[originalSize...])
            // Release the original snapshot before extending the VFS buffer,
            // keeping its append amortized rather than triggering a full COW.
            copy = []
            _ = try? vfs.write(path, delta, append: true)
        } else {
            if let delta = appendDelta { copy += delta }
            _ = try? vfs.write(path, copy)
        }
    }
}

// MARK: Pipes

/// The shared state of a pipe: a bounded byte queue.
final class Pipe {
    static let capacity = 16 * 1024
    var lock = SpinLock()
    var buffer: [UInt8] = []
    var head = 0
    /// Set when the last fd of that end closed.
    var writerClosed = false
    var readerClosed = false
    let waits = WaitList()

    var count: Int { buffer.count - head }
}

final class PipeEnd: FileObject {
    let pipe: Pipe
    let isWriter: Bool

    init(pipe: Pipe, isWriter: Bool) {
        self.pipe = pipe
        self.isWriter = isWriter
    }

    /// A new pipe's (read end, write end).
    static func make() -> (PipeEnd, PipeEnd) {
        let p = Pipe()
        return (PipeEnd(pipe: p, isWriter: false), PipeEnd(pipe: p, isWriter: true))
    }

    override var waits: WaitList { pipe.waits }

    override func ready() -> Int16 {
        let flags = pipe.lock.acquireIRQ()
        defer { pipe.lock.releaseIRQ(flags) }
        var r: Int16 = 0
        if isWriter {
            if pipe.readerClosed { r |= WaitEvent.hangup | WaitEvent.writable }
            if pipe.count < Pipe.capacity { r |= WaitEvent.writable }
        } else {
            if pipe.count > 0 { r |= WaitEvent.readable }
            if pipe.writerClosed { r |= WaitEvent.hangup | WaitEvent.readable }
        }
        return r
    }

    override func tryRead(_ max: Int) -> IOResult {
        guard !isWriter else { return .error(Errno.EBADF) }
        let flags = pipe.lock.acquireIRQ()
        var result = IOResult.wouldBlock
        if pipe.count > 0 {
            let n = min(max, pipe.count)
            result = .data(Array(pipe.buffer[pipe.head..<pipe.head + n]))
            pipe.head += n
            if pipe.head == pipe.buffer.count {
                pipe.buffer.removeAll(keepingCapacity: true)
                pipe.head = 0
            } else if pipe.head > Pipe.capacity {
                pipe.buffer.removeFirst(pipe.head)
                pipe.head = 0
            }
        } else if pipe.writerClosed {
            result = .data([])
        }
        pipe.lock.releaseIRQ(flags)
        if case .data(let d) = result, !d.isEmpty { pipe.waits.wake() } // room for a writer
        return result
    }

    override func tryWrite(_ bytes: [UInt8]) -> IOResult {
        guard isWriter else { return .error(Errno.EBADF) }
        let flags = pipe.lock.acquireIRQ()
        var result = IOResult.wouldBlock
        if pipe.readerClosed {
            result = .error(Errno.EPIPE)
        } else if bytes.isEmpty {
            result = .count(0)
        } else {
            let room = Pipe.capacity - pipe.count
            if room > 0 {
                let n = min(room, bytes.count)
                pipe.buffer.append(contentsOf: bytes[0..<n])
                result = .count(n)
            }
        }
        pipe.lock.releaseIRQ(flags)
        if case .count(let n) = result, n > 0 { pipe.waits.wake() }
        return result
    }

    override func lastClose() {
        let flags = pipe.lock.acquireIRQ()
        if isWriter { pipe.writerClosed = true } else { pipe.readerClosed = true }
        pipe.lock.releaseIRQ(flags)
        pipe.waits.wake()
    }
}

// MARK: The console

/// The terminal a program was started from, as the shell sees it. The
/// shell (the "pump", on its own task) drains `bytes` to its terminal and
/// feeds it keys; programs reach it through ConsoleFile. Shared by every
/// program of one command line (a pipeline's stages).
///
/// Keys: in cooked mode (the default) `feed` edits a line (echo, Backspace,
/// Ctrl-U) and releases it on Enter; Ctrl-D on an empty line is end of file;
/// Ctrl-C is an interrupt (the pump kills the foreground programs). In raw
/// mode (`ConsoleMode.raw`) each key goes straight to the input.
///
/// With no pump (`reader == nil`: a background job, or after the command
/// ended) writes go to the kernel log and reads see end of file.
final class ConsoleChannel {
    static let cap = 64 * 1024
    /// Output not yet taken by the pump.
    var bytes: [UInt8] = []
    /// Input ready to be read.
    var input: [UInt8] = []
    var eofPending = false
    /// The cooked line being edited (pump only).
    var line: [UInt8] = []
    var mode: UInt64 = 0
    /// The pump: unparked when output arrives.
    var reader: Task?
    /// File waiters: readers of input, writers waiting for room.
    let waits = WaitList()

    init(reader: Task?) { self.reader = reader }

    // Programs' side (any CPU).

    func readReady() -> Bool {
        let flags = outputLock.acquireIRQ()
        defer { outputLock.releaseIRQ(flags) }
        return !input.isEmpty || eofPending || reader == nil
    }

    func writeReady() -> Bool {
        let flags = outputLock.acquireIRQ()
        defer { outputLock.releaseIRQ(flags) }
        return bytes.count < ConsoleChannel.cap || reader == nil
    }

    func tryRead(_ max: Int) -> IOResult {
        let flags = outputLock.acquireIRQ()
        defer { outputLock.releaseIRQ(flags) }
        if !input.isEmpty {
            var n = min(max, input.count)
            if mode & ConsoleMode.raw == 0, let nl = input[0..<n].firstIndex(of: 0x0A) { n = nl + 1 }
            let out = Array(input[0..<n])
            input.removeFirst(n)
            return .data(out)
        }
        if eofPending { eofPending = false; return .data([]) }
        if reader == nil { return .data([]) }
        return .wouldBlock
    }

    func tryWrite(_ data: [UInt8]) -> IOResult {
        let flags = outputLock.acquireIRQ()
        guard let pump = reader else {
            outputLock.releaseIRQ(flags)
            let text = String(decoding: data, as: UTF8.self)
            onCPU0 { printRaw(text) }
            return .count(data.count)
        }
        if bytes.count >= ConsoleChannel.cap {
            outputLock.releaseIRQ(flags)
            unpark(pump)
            return .wouldBlock
        }
        let n = min(data.count, ConsoleChannel.cap - bytes.count)
        bytes.append(contentsOf: data[0..<n])
        outputLock.releaseIRQ(flags)
        unpark(pump)
        return .count(n)
    }

    /// Blocking write from kernel context (a fault report).
    func write(_ data: [UInt8], killed: () -> Bool) {
        var done = 0
        while done < data.count {
            guard let me = scheduler.current else { return }
            switch tryWrite(Array(data[done...])) {
            case .count(let n): done += n
            case .wouldBlock:
                waits.add(me)
                if !writeReady() { park() }
                waits.remove(me)
                if killed() { return }
            default: return
            }
        }
    }

    // The pump's side.

    /// Everything written so far.
    func take() -> [UInt8] {
        let flags = outputLock.acquireIRQ()
        let out = bytes
        bytes = []
        outputLock.releaseIRQ(flags)
        if !out.isEmpty { waits.wake() }
        return out
    }

    /// The command ended: nobody pumps any more.
    func detach() {
        let flags = outputLock.acquireIRQ()
        reader = nil
        bytes = []
        outputLock.releaseIRQ(flags)
        waits.wake()
    }

    /// One key typed at the terminal. Returns the text to echo, and whether
    /// it was an interrupt (Ctrl-C).
    func feed(_ key: KeyEvent) -> (echo: [UInt8], interrupt: Bool) {
        var echo: [UInt8] = []
        var interrupt = false
        let flags = outputLock.acquireIRQ()
        if key == .char(0x03) && mode & ConsoleMode.passInterrupt == 0 {
            interrupt = true
            line = []
            if mode & ConsoleMode.raw == 0 { echo = Array("^C\n".utf8) }
        } else if mode & ConsoleMode.raw != 0 {
            var b: [UInt8] = []
            switch key {
            case .char(let c): b = [c]
            case .up: b = [0x1B, 0x5B, 0x41]
            case .down: b = [0x1B, 0x5B, 0x42]
            case .right: b = [0x1B, 0x5B, 0x43]
            case .left: b = [0x1B, 0x5B, 0x44]
            case .home: b = [0x1B, 0x5B, 0x48]
            case .end: b = [0x1B, 0x5B, 0x46]
            case .delete: b = [0x1B, 0x5B, 0x33, 0x7E]
            case .pageUp: b = [0x1B, 0x5B, 0x35, 0x7E]
            case .pageDown: b = [0x1B, 0x5B, 0x36, 0x7E]
            default: break
            }
            if input.count + b.count <= ConsoleChannel.cap { input += b }
        } else if case .char(let c) = key {
            switch c {
            case 0x0D, 0x0A:
                if input.count + line.count < ConsoleChannel.cap { input += line + [0x0A] }
                line = []
                echo = [0x0A]
            case 0x7F, 0x08:
                if !line.isEmpty {
                    var n = line.count - 1
                    while n > 0 && line[n] & 0xC0 == 0x80 { n -= 1 }
                    line.removeSubrange(n...)
                    echo = [0x08, 0x20, 0x08]
                }
            case 0x15: // Ctrl-U
                for b in line where b & 0xC0 != 0x80 { echo += [0x08, 0x20, 0x08] }
                line = []
            case 0x04: // Ctrl-D
                if line.isEmpty {
                    eofPending = true
                } else {
                    input += line
                    line = []
                }
            case 0x20...0xFF:
                if line.count < 4096 {
                    line.append(c)
                    echo = [c]
                }
            default: break
            }
        }
        outputLock.releaseIRQ(flags)
        waits.wake()
        return (echo, interrupt)
    }
}

final class ConsoleFile: FileObject {
    let channel: ConsoleChannel
    init(_ channel: ConsoleChannel) { self.channel = channel }

    override var waits: WaitList { channel.waits }
    override var consoleChannel: ConsoleChannel? { channel }

    override func ready() -> Int16 {
        (channel.readReady() ? WaitEvent.readable : 0) | (channel.writeReady() ? WaitEvent.writable : 0)
    }

    override func tryRead(_ max: Int) -> IOResult { channel.tryRead(max) }
    override func tryWrite(_ bytes: [UInt8]) -> IOResult { channel.tryWrite(bytes) }
}
