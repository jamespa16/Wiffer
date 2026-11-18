// Phase 6E selftests: fds, pipes, the console's line discipline, timed
// parks, and the programs (iotest from ring 3, a cat | wc pipeline).

/// "lines words bytes" of `bytes`, as /bin/wc prints them.
func wcLine(_ bytes: [UInt8]) -> String {
    var lines = 0, words = 0
    var inWord = false
    for b in bytes {
        if b == 0x0A { lines += 1 }
        let space = b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D
        if space { inWord = false } else if !inWord { inWord = true; words += 1 }
    }
    return "\(lines) \(words) \(bytes.count)"
}

func typed(_ text: String) -> [KeyEvent] { text.utf8.map { .char($0) } }

final class Probe: FileObject {
    var closed = 0
    override func lastClose() { closed += 1 }
}

func fileTests(_ t: inout SelfTest) {
    // FileObject references and the fd table.
    let probe = Probe()
    var table = FdTable()
    let fd0 = table.install(probe), fd1 = table.install(probe)
    t.check("6E1: install picks the lowest free fds", fd0 == 0 && fd1 == 1 && probe.fdRefs == 2)
    t.check("6E1: set (dup2) shares the object", table.set(5, probe) && probe.fdRefs == 3 && table.get(5) === probe)
    t.check("6E1: close drops one count each", table.close(0) && table.close(5) && probe.closed == 0 && probe.fdRefs == 1)
    t.check("6E1: the last close runs lastClose once", table.close(1) && probe.closed == 1 && probe.fdRefs == 0)
    t.check("6E1: closing a closed or absent fd fails", !table.close(1) && !table.close(-1) && !table.close(999))
    t.check("6E1: the table refuses fds past the limit",
            !table.set(FdTable.maxFDs, probe) && table.install(probe, from: FdTable.maxFDs) == nil)
    _ = table.set(3, probe)
    table.closeAll()
    t.check("6E1: closeAll closes everything", probe.closed == 2 && table.openCount == 0)

    // Pipes.
    let (r, w) = PipeEnd.make()
    r.addRef()
    w.addRef()
    if case .wouldBlock = r.tryRead(10) {} else { t.check("6E3: an empty pipe would block a reader", false) }
    t.check("6E3: pipe starts writable only", r.ready() == 0 && w.ready() == WaitEvent.writable)
    if case .count(3) = w.tryWrite([1, 2, 3]) {} else { t.check("6E3: pipe write", false) }
    t.check("6E3: pipe is readable after a write", r.ready() == WaitEvent.readable)
    if case .data(let d) = r.tryRead(2), d == [1, 2] {} else { t.check("6E3: pipe read takes what's asked", false) }
    if case .data(let d) = r.tryRead(9), d == [3] {} else { t.check("6E3: pipe read takes the rest", false) }
    var queued = 0
    while case .count(let n) = w.tryWrite([UInt8](repeating: 7, count: 5000)) { queued += n }
    t.check("6E3: a full pipe holds exactly its capacity then blocks", queued == Pipe.capacity && w.ready() == 0)
    if case .data(let d) = r.tryRead(100), d.count == 100 {} else { t.check("6E3: read from a full pipe", false) }
    t.check("6E3: reading makes room", w.ready() == WaitEvent.writable)
    w.dropRef()
    t.check("6E3: closing the writer is a hangup, data first", r.ready() == WaitEvent.readable | WaitEvent.hangup)
    var rest = 0
    while case .data(let d) = r.tryRead(4096), !d.isEmpty { rest += d.count }
    t.check("6E3: the rest is delivered, then end of file", rest == Pipe.capacity - 100)
    if case .data(let d) = r.tryRead(10), d.isEmpty {} else { t.check("6E3: end of file is empty data", false) }
    r.dropRef()
    if case .error(let e) = w.tryWrite([1]), e == Errno.EPIPE {} else { t.check("6E3: write with no reader is EPIPE", false) }
    t.check("6E3: pipe ends refuse the wrong direction", {
        let (a, b) = PipeEnd.make()
        if case .error = a.tryWrite([1]), case .error = b.tryRead(1) { return true }
        return false
    }())

    // The console's line discipline.
    let ch = ConsoleChannel(reader: scheduler.current)
    var echo: [UInt8] = []
    for k in typed("abc") + [.char(0x7F)] + typed("d\r") { echo += ch.feed(k).echo }
    t.check("6E2: cooked mode edits the line and echoes", echo == Array("abc".utf8) + [8, 32, 8] + Array("d".utf8) + [10])
    if case .data(let d) = ch.tryRead(100), d == Array("abd\n".utf8) {} else { t.check("6E2: a line is released on Enter", false) }
    if case .wouldBlock = ch.tryRead(100) {} else { t.check("6E2: no line, no data", false) }
    _ = ch.feed(.char(0x78))
    t.check("6E2: an unfinished line isn't readable", !ch.readReady())
    _ = ch.feed(.char(0x15))
    _ = ch.feed(.char(0x04))
    if case .data(let d) = ch.tryRead(100), d.isEmpty {} else { t.check("6E2: Ctrl-D on an empty line is end of file", false) }
    var typedAhead = ch.feed(.char(0x61)).echo
    typedAhead += ch.feed(.char(0x0D)).echo + ch.feed(.char(0x62)).echo + ch.feed(.char(0x0D)).echo
    if case .data(let d) = ch.tryRead(100), d == Array("a\n".utf8) {} else { t.check("6E2: one line per read", false) }
    let ctrlC = ch.feed(.char(0x03))
    t.check("6E2: Ctrl-C is an interrupt, echoed ^C", ctrlC.interrupt && ctrlC.echo == Array("^C\n".utf8))
    ch.mode = ConsoleMode.raw
    let rawEcho = ch.feed(.char(0x71)).echo + ch.feed(.left).echo
    if case .data(let d) = ch.tryRead(100), d == [0x62, 0x0A, 0x71, 0x1B, 0x5B, 0x44] {} else { t.check("6E2: raw mode passes keys", false) }
    t.check("6E2: raw mode doesn't echo", rawEcho.isEmpty)
    ch.mode = ConsoleMode.raw | ConsoleMode.passInterrupt
    let passed = ch.feed(.char(0x03))
    t.check("6E2: passInterrupt delivers Ctrl-C as a byte", !passed.interrupt && ch.input == [0x03])
    ch.detach()
    if case .data(let d) = ch.tryRead(1), d == [3] {} else { t.check("6E2: input survives detach", false) }
    if case .data(let d) = ch.tryRead(1), d.isEmpty {} else { t.check("6E2: a detached console reads end of file", false) }

    programTests(&t)
}

func programTests(_ t: inout SelfTest) {
    guard let me = scheduler.current, (try? vfs.lookup("/bin/iotest")) != nil else {
        t.check("6E: /bin/iotest in the rootfs", false)
        return
    }
    _ = runProgramForTest(["hello"])
    let frames = pmm.freeFrames, splits = splitPages, heap0 = HeapUsage()

    // The syscall surface from ring 3.
    let io = runProgramForTest(["iotest"])
    if io.status != .exited(0) || !has(io.output, " 0 failed") || has(io.output, "FAIL") { print(io.output) }
    t.check("6E1: iotest passes from ring 3 (files, pipes, wait, spawn, bad pointers)",
            io.status == .exited(0) && has(io.output, " 0 failed") && !has(io.output, "FAIL"))
    t.check("6E1: iotest left nothing in the filesystem", (try? vfs.lookup("/iot")) == nil)

    // cat /README | wc: a two-stage pipeline, as the shell builds it.
    let expected = wcLine((try? vfs.read("/README")) ?? [])
    do throws(ExecError) {
        let channel = ConsoleChannel(reader: me)
        let console = ConsoleFile(channel)
        let (pr, pw) = PipeEnd.make()
        pr.addRef()
        pw.addRef()
        let cat = try spawnProcess(path: "/bin/cat", argv: ["cat", "/README"], output: channel, waiter: me,
                                   stdio: [console, pw, console])
        let wc = try spawnProcess(path: "/bin/wc", argv: ["wc"], output: channel, waiter: me, stdio: [pr, console, console])
        pr.dropRef()
        pw.dropRef()
        var bytes: [UInt8] = []
        let statuses = waitProcesses([cat, wc], console: channel, sink: { bytes += $0 })
        t.check("6E3: cat /README | wc counts the file", statuses == [.exited(0), .exited(0)]
                && String(decoding: bytes, as: UTF8.self) == expected + "\n")
    } catch {
        t.check("6E3: cat | wc spawns", false)
    }

    // A program reading the console gets cooked lines; Ctrl-D ends it.
    var echoTest: (String, ExitStatus) = ("", .killed)
    do throws(ExecError) {
        let channel = ConsoleChannel(reader: me)
        let p = try spawnProcess(path: "/bin/cat", argv: ["cat"], output: channel, waiter: me)
        var script: [KeyEvent]? = typed("hi\r") + [.char(0x04)]
        var bytes: [UInt8] = []
        let s = waitProcesses([p], console: channel, sink: { bytes += $0 }, keys: {
            defer { script = nil }
            return (script ?? [], false)
        })
        echoTest = (String(decoding: bytes, as: UTF8.self), s[0])
    } catch {}
    t.check("6E2: cat on the console echoes a typed line and returns it", echoTest.0 == "hi\nhi\n" && echoTest.1 == .exited(0))

    // Ctrl-C kills what's blocked reading the console.
    var interrupted: (String, ExitStatus) = ("", .exited(0))
    do throws(ExecError) {
        let channel = ConsoleChannel(reader: me)
        let p = try spawnProcess(path: "/bin/cat", argv: ["cat"], output: channel, waiter: me)
        var script: [KeyEvent]? = [.char(0x03)]
        var bytes: [UInt8] = []
        let s = waitProcesses([p], console: channel, sink: { bytes += $0 }, keys: {
            defer { script = nil }
            return (script ?? [], false)
        })
        interrupted = (String(decoding: bytes, as: UTF8.self), s[0])
    } catch {}
    t.check("6E2: Ctrl-C kills a program blocked on the console", interrupted.1 == .killed && has(interrupted.0, "^C"))

    // Ctrl-C kills a spinning program (on another CPU: until 6D, nothing
    // interrupts ring 3 on CPU 0).
    if onlineCPUCount() > 1 {
        do throws(ExecError) {
            let channel = ConsoleChannel(reader: me)
            let p = try spawnProcess(path: "/bin/spin", argv: ["spin"], output: channel, waiter: me, affinity: .cpu(1))
            let begin = ticks
            var sent = false
            // Nothing wakes the pump while the spin runs (a real shell is
            // woken by keys): a helper task does it after a while.
            spawn("ctrlc-wake", affinity: .cpu(0), { sleepMilliseconds(150); unpark(me) })
            let s = waitProcesses([p], console: channel, keys: {
                if !sent && ticks - begin >= 10 { sent = true; return ([.char(0x03)], false) }
                return ([], false)
            })
            t.check("6E2: Ctrl-C kills a spin", s[0] == .killed)
        } catch {
            t.check("6E2: Ctrl-C kills a spin", false)
        }
    }

    t.check("6E: no processes left", processTable.isEmpty)
    let leaked = frames - pmm.freeFrames - (splitPages - splits)
    if leaked != 0 { print("  pmm: \(leaked) frames leaked by the 6E tests") }
    t.check("6E: no frames leaked by files, pipes and programs", leaked == 0)
    // (A scheduler or wait-list array may grow once, first time through: allow a
    // couple of blocks, not a block per run; frames are exact above.)
    let heapNow = HeapUsage()
    if heapNow.blocks > heap0.blocks + 2 { print("  heap: \(heap0.blocks) -> \(heapNow.blocks) blocks") }
    t.check("6E: no heap leaked by files, pipes and programs", heapNow.blocks <= heap0.blocks + 2
            && heapNow.largeFrames == heap0.largeFrames)
}
