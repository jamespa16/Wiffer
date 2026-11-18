// /bin/wintest [noread]: a window for the tests (Phase 6F). 220x140: a
// marker rectangle of colour 0x2040C0 at (0, 60, 220, 20), a button and a
// text field. Every event is logged to the serial port ("ev ..."); a close
// event ends it. With `noread` it opens the window and never reads events
// (the queue-cap test), sleeping until killed.

let args = Process.args
if args.count > 1 && args[1] == "bad" {
    // Bad arguments to the window syscalls must fail cleanly.
    var failed = 0
    func expect(_ what: String, _ r: Int, _ errno: Int) {
        if r != -errno { debugPrint("bad: FAIL \(what): got \(r), want -\(errno)\n"); failed += 1 }
    }
    var info = WinInfo()
    let literal: StaticString = "x"
    let title = UInt64(UInt(bitPattern: literal.utf8Start))
    withUnsafeMutablePointer(to: &info) { p in
        let out = UInt64(UInt(bitPattern: p))
        expect("zero size", syscall(SyscallNumber.winCreate, 0, 10, title, 1, out), Errno.EINVAL)
        expect("huge size", syscall(SyscallNumber.winCreate, 100000, 10, title, 1, out), Errno.EINVAL)
        expect("huge both", syscall(SyscallNumber.winCreate, 1 << 40, 1 << 40, title, 1, out), Errno.EINVAL)
        expect("long title", syscall(SyscallNumber.winCreate, 10, 10, title, 100000, out), Errno.EINVAL)
        expect("null out", syscall(SyscallNumber.winCreate, 10, 10, title, 1, 0), Errno.EFAULT)
        expect("kernel out", syscall(SyscallNumber.winCreate, 10, 10, title, 1, 0xFFFF_8000_0000_0000), Errno.EFAULT)
        expect("bad title ptr", syscall(SyscallNumber.winCreate, 10, 10, 8, 4, out), Errno.EFAULT)
        expect("present stdout", syscall(SyscallNumber.winPresent, 1, 0, 0, 1, 1), Errno.EBADF)
        expect("present bad fd", syscall(SyscallNumber.winPresent, 99, 0, 0, 1, 1), Errno.EBADF)
        expect("resize stdout", syscall(SyscallNumber.winResize, 1, 0, 0, out), Errno.EBADF)
        expect("title stdout", syscall(SyscallNumber.winSetTitle, 1, title, 1), Errno.EBADF)
        expect("sysinfo null", syscall(SyscallNumber.sysinfo, 0), Errno.EFAULT)
    }
    if let w = AppWindow.create(title: "bad", width: 50, height: 50) {
        var out = WinInfo()
        withUnsafeMutablePointer(to: &out) { p in
            let o = UInt64(UInt(bitPattern: p))
            expect("resize one zero", syscall(SyscallNumber.winResize, UInt64(w.fd), 0, 5, o), Errno.EINVAL)
            expect("resize huge", syscall(SyscallNumber.winResize, UInt64(w.fd), 99999, 5, o), Errno.EINVAL)
            expect("resize null out", syscall(SyscallNumber.winResize, UInt64(w.fd), 0, 0, 0), Errno.EFAULT)
            expect("title ptr", syscall(SyscallNumber.winSetTitle, UInt64(w.fd), 8, 4), Errno.EFAULT)
            expect("title long", syscall(SyscallNumber.winSetTitle, UInt64(w.fd), title, 1000), Errno.EINVAL)
        }
        var small = [UInt8](repeating: 0, count: 8)
        expect("read < 1 record", small.withUnsafeMutableBytes {
            syscall(SyscallNumber.read, UInt64(w.fd), UInt64(UInt(bitPattern: $0.baseAddress)), 8)
        }, Errno.EINVAL)
        expect("write", syscall(SyscallNumber.write, UInt64(w.fd), title, 1), Errno.EBADF)
        w.present(Rect(-100, -100, 1 << 30, 1 << 30)) // clipped, not an error
        w.present(Rect(1 << 29, 5, 10, 10)) // outside: nothing
        // The ninth window is refused.
        var more: [AppWindow] = []
        for _ in 0..<WinLimit.maxPerProcess { if let x = AppWindow.create(title: "n", width: 20, height: 20) { more.append(x) } }
        if more.count != WinLimit.maxPerProcess - 1 { debugPrint("bad: FAIL window cap, opened \(more.count)\n"); failed += 1 }
        for x in more { x.close() }
        // After close the buffer is gone: touching it would fault, so don't.
        w.close()
        expect("present closed", syscall(SyscallNumber.winPresent, UInt64(w.fd), 0, 0, 1, 1), Errno.EBADF)
    } else { debugPrint("bad: FAIL create\n"); failed += 1 }
    debugPrint("bad: \(failed) failed\n")
    Process.exit(failed == 0 ? 0 : 1)
}
guard let app = App(title: "wintest", width: 220, height: 140) else {
    debugPrint("wintest: no window\n")
    Process.exit(1)
}
debugPrint("wintest: window \(app.window.width)x\(app.window.height)\n")
if args.count > 1 && args[1] == "noread" {
    app.requestPaint()
    app.window.surface.fill(0x2040C0)
    app.window.present()
    while true { Time.sleep(1000) }
}
app.onPaint = { s in
    s.fill(Rect(0, 60, s.width, 20), 0x2040C0)
}
var clicks = 0
app.ui.button("Hit", frame: Rect(10, 10, 80, 24)) {
    clicks += 1
    debugPrint("ev click \(clicks)\n")
}
let field = app.ui.textField(frame: Rect(10, 100, 200, 24), text: "")
field.onSubmit = { debugPrint("ev submit \($0)\n") }
app.onEvent = { e in
    switch e {
    case .key(let k): debugPrint("ev key \(k.code) ctrl=\(k.ctrl)\n")
    case .mouse(let x, let y, let b, _): debugPrint("ev mouse \(x) \(y) b=\(b)\n")
    case .resize(let w, let h): debugPrint("ev resize \(w) \(h)\n")
    case .focus(let on): debugPrint("ev focus \(on ? 1 : 0)\n")
    case .close: debugPrint("ev close\n")
    }
    return false
}
app.onResize = { w, h in debugPrint("ev adopted \(w) \(h)\n") }
Process.exit(app.run())
