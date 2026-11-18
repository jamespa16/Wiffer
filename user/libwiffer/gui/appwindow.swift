// libwiffer, Phase 6F: windows (compiled into programs that list `gui` in
// user/<prog>/LIBS; see lib/gui).
//
//   AppWindow.create(title:width:height:)  open a window (nil on failure)
//   .surface        a Surface over the pixel buffer (0x00RRGGBB): draw on it
//   .present(rect)  tell the compositor what changed (nil: everything)
//   .setTitle(_:)   .adoptResize() after a resize event   .close()
//   .fd             the window's descriptor, for wait()
//   .readEvents()   decoded events that are waiting (never blocks)
//   GUIFont.spleen  the 8x16 console font (embedded in every program)

/// The Spleen 8x16 font, from the copy libwiffer links in (font.S).
enum GUIFont {
    static var spleen: PSFFont? = {
        guard let p = wiffer_font_data() else { return nil }
        return PSFFont(p, size: Int(wiffer_font_size()))
    }()
}

final class AppWindow {
    let fd: Int
    private(set) var surface: Surface
    private(set) var info: WinInfo

    var width: Int { surface.width }
    var height: Int { surface.height }

    private init(fd: Int, info: WinInfo) {
        self.fd = fd
        self.info = info
        surface = AppWindow.wrap(info)
    }

    private static func wrap(_ info: WinInfo) -> Surface {
        Surface(wrapping: UnsafeMutablePointer<UInt32>(bitPattern: UInt(info.address))!, width: Int(info.width),
                height: Int(info.height), stride: Int(info.stride))
    }

    /// Open a window with a `width` x `height` content area (the kernel may
    /// make it smaller to fit the screen: see `width`/`height`).
    static func create(title: String, width: Int, height: Int) -> AppWindow? {
        var info = WinInfo()
        var t = title
        let fd = t.withUTF8 { b in
            withUnsafeMutablePointer(to: &info) { out in
                syscall(SyscallNumber.winCreate, UInt64(width), UInt64(height),
                        UInt64(UInt(bitPattern: b.baseAddress)), UInt64(b.count), UInt64(UInt(bitPattern: out)))
            }
        }
        guard fd >= 0, info.address != 0 else { return nil }
        return AppWindow(fd: fd, info: info)
    }

    func present(_ r: Rect? = nil) {
        let r = r ?? Rect(0, 0, 0, 0)
        _ = syscall(SyscallNumber.winPresent, UInt64(fd), UInt64(bitPattern: Int64(r.x)), UInt64(bitPattern: Int64(r.y)),
                    UInt64(bitPattern: Int64(r.w)), UInt64(bitPattern: Int64(r.h)))
    }

    func setTitle(_ title: String) {
        var t = title
        t.withUTF8 { b in
            _ = syscall(SyscallNumber.winSetTitle, UInt64(fd), UInt64(UInt(bitPattern: b.baseAddress)), UInt64(b.count))
        }
    }

    /// After a resize event: map a buffer of the window's current size (the
    /// old pixels are copied into its corner). `surface` is replaced.
    @discardableResult
    func adoptResize() -> Bool { resize(width: 0, height: 0) }

    /// Ask for a content size (0, 0: just adopt the current one).
    @discardableResult
    func resize(width: Int, height: Int) -> Bool {
        var out = WinInfo()
        let r = withUnsafeMutablePointer(to: &out) {
            syscall(SyscallNumber.winResize, UInt64(fd), UInt64(width), UInt64(height), UInt64(UInt(bitPattern: $0)))
        }
        guard r == 0, out.address != 0 else { return false }
        info = out
        surface = AppWindow.wrap(out)
        return true
    }

    /// Events already queued (no blocking). Use wait() on `fd` to sleep.
    func readEvents(max: Int = 64) -> [GUIEvent] {
        var ready = [WaitFD(fd: Int32(fd), events: WaitEvent.readable, revents: 0)]
        guard wait(&ready, timeoutMs: 0) > 0 else { return [] }
        var records = [UInt8](repeating: 0, count: max * WinEvent.size)
        let n = records.withUnsafeMutableBytes { b in
            syscall(SyscallNumber.read, UInt64(fd), UInt64(UInt(bitPattern: b.baseAddress)), UInt64(b.count))
        }
        guard n > 0 else { return [] }
        var out: [GUIEvent] = []
        for r in guiDecodeRecords(Array(records[0..<n])) { if let e = guiDecode(r) { out.append(e) } }
        return out
    }

    func close() { _ = syscall(SyscallNumber.close, UInt64(fd)) }
}

/// Counters for monitors (the sysinfo syscall).
func systemInfo() -> SysInfo {
    var s = SysInfo()
    _ = withUnsafeMutablePointer(to: &s) { syscall(SyscallNumber.sysinfo, UInt64(UInt(bitPattern: $0))) }
    return s
}
