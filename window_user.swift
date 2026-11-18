// Phase 6F: windows owned by processes.
//
// A process opens a window with win_create and gets a file descriptor
// (WindowFile) and a pixel buffer. The buffer is a contiguous run of
// frames the kernel allocates and owns; it is mapped into the process
// read/write, no-exec, without the `owned` bit (so the address space never
// frees it) and is seen by the kernel through the identity map. The
// compositor draws straight from it: while the window's content is
// `direct` (the framebuffer's pixel format is 0x00RRGGBB, always true on
// QEMU/Limine) UserWindow.content is a Surface wrapping the buffer, so
// there is no copy at all. Otherwise (or after the WM resized the window
// and until the process adopts the new size) `content` is a kernel
// surface and draw() copies the presented damage into it, converting the
// pixel format.
//
// Threads. The WM, the compositor and everything in Window are CPU 0 data;
// syscalls hop there with onCPU0 (create, resize, title, close). The
// exceptions are present (a lock-protected damage rect, so the hop isn't
// needed 60 times a second) and the event queue (WinChannel, its own lock):
// the WM posts events from CPU 0 and the process reads them on any CPU.
//
// Events are fixed 16-byte WinEvent records read from the fd, so a process
// can `wait` on it with its other fds. The queue is capped (128 records):
// mouse motion is coalesced (a new motion replaces a queued one at the
// tail) and dropped first when full, resizes coalesce, and a full queue
// evicts the oldest motion to make room for a key or a button. A close
// request is a flag, not a record in the ring, so it can't be lost; a
// second request while the first is still unread (the process is hung)
// kills the process.
//
// Lifetime. The fd's last close (the process closing it, exiting, or being
// killed: processLeave closes every fd) removes the window from the WM,
// unmaps the buffer from the process if it is still there, and frees the
// frames. Unmapping only touches pages that still translate to our frames,
// so a process that unmapped the buffer itself and mapped something else
// there keeps that mapping.

/// Replaces the global WM for tests (a local WM over an off-screen
/// compositor).
var testWindowManager: WindowManager? = nil

func userWindowManager() -> WindowManager? { testWindowManager ?? windowManager }

/// All live user windows' buffer frames (tests).
var userWindowFrames = 0
var userWindowsCreated = 0

// MARK: The event queue

final class WinChannel {
    static let capacity = 128
    var lock = SpinLock()
    private let slots: UnsafeMutablePointer<WinEvent>
    private let motion: UnsafeMutablePointer<Bool>
    private var head = 0
    private(set) var count = 0
    private var closePending = false
    private var shut = false
    /// Buttons of the last mouse event posted (a change is not "motion").
    private var lastButtons: UInt16 = 0
    private(set) var dropped = 0
    private(set) var coalesced = 0
    private(set) var posted = 0
    let waits = WaitList()

    init() {
        slots = UnsafeMutablePointer<WinEvent>.allocate(capacity: WinChannel.capacity)
        slots.initialize(repeating: WinEvent(), count: WinChannel.capacity)
        motion = UnsafeMutablePointer<Bool>.allocate(capacity: WinChannel.capacity)
        motion.initialize(repeating: false, count: WinChannel.capacity)
    }

    deinit {
        slots.deallocate()
        motion.deallocate()
    }

    var isReadable: Bool {
        let f = lock.acquireIRQ()
        defer { lock.releaseIRQ(f) }
        return count > 0 || closePending
    }

    /// Queue an event, applying the cap policy. Allocation-free.
    func post(_ e: WinEvent) {
        let f = lock.acquireIRQ()
        if shut { lock.releaseIRQ(f); return }
        posted += 1
        var isMotion = false
        if e.kind == WinEventKind.mouse {
            isMotion = e.mods == lastButtons
            lastButtons = e.mods
        }
        // Coalesce into the tail: motion with motion, resize with resize.
        if count > 0 && (isMotion || e.kind == WinEventKind.resize) {
            let t = (head + count - 1) % WinChannel.capacity
            if (isMotion && motion[t]) || (e.kind == WinEventKind.resize && slots[t].kind == WinEventKind.resize) {
                slots[t] = e
                coalesced += 1
                lock.releaseIRQ(f)
                return
            }
        }
        if count == WinChannel.capacity {
            // Full: motion is dropped first; anything else evicts the oldest
            // motion, or is itself dropped.
            if isMotion || !evictMotion() {
                dropped += 1
                lock.releaseIRQ(f)
                return
            }
        }
        let i = (head + count) % WinChannel.capacity
        slots[i] = e
        motion[i] = isMotion
        count += 1
        lock.releaseIRQ(f)
        waits.wake()
    }

    /// Remove the oldest queued motion event (lock held). False if none.
    private func evictMotion() -> Bool {
        var k = 0
        while k < count && !motion[(head + k) % WinChannel.capacity] { k += 1 }
        guard k < count else { return false }
        var j = k
        while j + 1 < count {
            let a = (head + j) % WinChannel.capacity, b = (head + j + 1) % WinChannel.capacity
            slots[a] = slots[b]
            motion[a] = motion[b]
            j += 1
        }
        count -= 1
        dropped += 1
        return true
    }

    /// A close request. True if one was already pending and unread.
    func requestClose() -> Bool {
        let f = lock.acquireIRQ()
        let already = closePending
        closePending = true
        lock.releaseIRQ(f)
        waits.wake()
        return already
    }

    /// No more events (the window is gone).
    func shutDown() {
        let f = lock.acquireIRQ()
        shut = true
        count = 0
        closePending = false
        lock.releaseIRQ(f)
        waits.wake()
    }

    /// Up to `n` records (a pending close first), or nil if none.
    func take(_ n: Int) -> [WinEvent]? {
        var out: [WinEvent] = []
        out.reserveCapacity(n)
        let f = lock.acquireIRQ()
        if closePending && n > 0 {
            closePending = false
            out.append(WinEvent(kind: WinEventKind.close, mods: 0, a: 0, b: 0, c: 0))
        }
        while out.count < n && count > 0 {
            out.append(slots[head])
            head = (head + 1) % WinChannel.capacity
            count -= 1
        }
        lock.releaseIRQ(f)
        return out.isEmpty ? nil : out
    }
}

// MARK: The window

final class UserWindow: Window {
    let channel = WinChannel()
    /// The owning process (for the kill on an unanswered close).
    let pid: Int
    private var space: AddressSpace?
    /// The pixel buffer: its frames (identity-mapped address), size, and
    /// where it sits in the process.
    private(set) var bufferPhys: UInt
    private(set) var bufferPages: Int
    private(set) var bufferWidth: Int
    private(set) var bufferHeight: Int
    private(set) var userAddress: UInt
    /// `content` is a Surface over the buffer itself (no copy needed).
    private(set) var contentIsBuffer: Bool
    /// Pixel format conversion (nil: the buffer's format is the screen's).
    private let convert: ((UInt32) -> UInt32)?
    private var damageLock = SpinLock()
    private var presentDamage = Rect.empty
    private(set) var destroyed = false
    private(set) var presents = 0

    /// Wraps an already mapped buffer. `convert` is the framebuffer's
    /// colour conversion if the screen isn't 0x00RRGGBB, else nil.
    init(title: String, width: Int, height: Int, pid: Int, space: AddressSpace, phys: UInt, pages: Int,
         address: UInt, convert: ((UInt32) -> UInt32)?) {
        self.pid = pid
        self.space = space
        bufferPhys = phys
        bufferPages = pages
        bufferWidth = width
        bufferHeight = height
        userAddress = address
        self.convert = convert
        contentIsBuffer = convert == nil
        let surface = convert == nil
            ? Surface(wrapping: UnsafeMutablePointer<UInt32>(bitPattern: phys)!, width: width, height: height, stride: width)
            : Surface(width: width, height: height)
        super.init(title: title, surface: surface)
        // A hung process must not make the window unclosable.
        minContentWidth = 32
        minContentHeight = 16
    }

    private var buffer: UnsafeMutablePointer<UInt32> { UnsafeMutablePointer<UInt32>(bitPattern: bufferPhys)! }

    var info: WinInfo {
        WinInfo(address: UInt64(userAddress), width: Int32(bufferWidth), height: Int32(bufferHeight),
                stride: Int32(bufferWidth), reserved: 0)
    }

    // MARK: present and draw

    /// win_present: any CPU. `r` is in buffer coordinates.
    func present(_ r: Rect) {
        let c = r.isEmpty ? Rect(0, 0, bufferWidth, bufferHeight) : r.intersection(Rect(0, 0, bufferWidth, bufferHeight))
        guard !c.isEmpty else { return }
        let f = damageLock.acquireIRQ()
        presentDamage = presentDamage.union(c)
        presents += 1
        damageLock.releaseIRQ(f)
        dirty = true
    }

    override func draw() {
        let f = damageLock.acquireIRQ()
        let d = presentDamage
        presentDamage = .empty
        damageLock.releaseIRQ(f)
        guard !d.isEmpty, !destroyed else { return }
        if !contentIsBuffer { copyFromBuffer(d) }
        invalidate(d)
    }

    /// Copy `r` of the buffer into `content` (a kernel surface), converting.
    private func copyFromBuffer(_ r: Rect) {
        let c = r.intersection(Rect(0, 0, bufferWidth, bufferHeight)).intersection(content.bounds)
        guard !c.isEmpty else { return }
        let src = buffer, dst = content.pixels
        for y in c.y..<c.maxY {
            let s = src + y * bufferWidth + c.x
            let d = dst + y * content.stride + c.x
            if let convert {
                for x in 0..<c.w { d[x] = convert(s[x]) }
            } else {
                d.update(from: s, count: c.w)
            }
        }
    }

    // MARK: events

    func encode(_ k: Key) -> WinEvent? {
        var code = 0
        switch k.code {
        case .char(let c): code = Int(c)
        case .up: code = WinKey.up
        case .down: code = WinKey.down
        case .left: code = WinKey.left
        case .right: code = WinKey.right
        case .home: code = WinKey.home
        case .end: code = WinKey.end
        case .pageUp: code = WinKey.pageUp
        case .pageDown: code = WinKey.pageDown
        case .insert: code = WinKey.insert
        case .delete: code = WinKey.delete
        case .function(let n): code = WinKey.function + Int(n)
        case .superKey: return nil
        }
        var mods: UInt16 = 0
        if k.ctrl { mods |= WinMod.ctrl }
        if k.alt { mods |= WinMod.alt }
        if k.shift { mods |= WinMod.shift }
        if k.meta { mods |= WinMod.meta }
        return WinEvent(kind: WinEventKind.key, mods: mods, a: Int32(code), b: 0, c: 0)
    }

    override func handle(_ event: Event) {
        switch event {
        case .key(let k):
            if let e = encode(k) { channel.post(e) }
        case .mouse(let x, let y, let b):
            channel.post(WinEvent(kind: WinEventKind.mouse, mods: UInt16(b & 7), a: Int32(truncatingIfNeeded: x),
                                  b: Int32(truncatingIfNeeded: y), c: 0))
        case .focus(let on):
            channel.post(WinEvent(kind: WinEventKind.focus, mods: 0, a: on ? 1 : 0, b: 0, c: 0))
        case .resize(let w, let h):
            // The WM gave `content` a kernel surface of the new size (the old
            // pixels copied in); the process adopts it with win_resize.
            contentIsBuffer = false
            channel.post(WinEvent(kind: WinEventKind.resize, mods: 0, a: Int32(w), b: Int32(h), c: 0))
        case .close:
            if channel.requestClose() { killProcess(pid) }
        default:
            break
        }
    }

    /// The close box and Alt-F4 ask the process; it closes the fd to agree.
    override func close() -> Bool {
        handle(.close)
        return false
    }

    // MARK: resize (CPU 0)

    /// win_resize: adopt the window's current content size as the buffer
    /// size (after asking the WM for `width` x `height` if given). The new
    /// buffer is mapped before the old one goes. Returns -errno.
    func adoptSize(_ p: Process, wm: WindowManager, width: Int, height: Int) -> Int {
        if width > 0 && height > 0 { wm.resize(self, contentWidth: width, contentHeight: height) }
        let w = content.width, h = content.height
        if w == bufferWidth && h == bufferHeight { return 0 }
        guard let fresh = allocateBuffer(width: w, height: h) else { return fail(Errno.ENOMEM) }
        guard let addr = mapBuffer(p, phys: fresh.phys, pages: fresh.pages) else {
            pmm.free(fresh.phys, count: fresh.pages)
            return fail(Errno.ENOMEM)
        }
        // Old pixels into the top-left of the new buffer.
        let old = buffer, np = UnsafeMutablePointer<UInt32>(bitPattern: fresh.phys)!
        for y in 0..<min(h, bufferHeight) {
            (np + y * w).update(from: old + y * bufferWidth, count: min(w, bufferWidth))
        }
        let oldPhys = bufferPhys, oldPages = bufferPages, oldAddr = userAddress
        bufferPhys = fresh.phys
        bufferPages = fresh.pages
        bufferWidth = w
        bufferHeight = h
        userAddress = addr
        userWindowFrames += fresh.pages - oldPages
        if convert == nil {
            content = Surface(wrapping: np, width: w, height: h, stride: w)
            contentIsBuffer = true
        }
        unmapBuffer(p, phys: oldPhys, pages: oldPages, address: oldAddr)
        pmm.free(oldPhys, count: oldPages)
        let f = damageLock.acquireIRQ()
        presentDamage = Rect(0, 0, w, h)
        damageLock.releaseIRQ(f)
        dirty = true
        invalidate()
        return 0
    }

    // MARK: teardown (CPU 0)

    /// Remove from the WM, drop the events, unmap and free the buffer.
    func destroy(wm: WindowManager) {
        guard !destroyed else { return }
        destroyed = true
        wm.remove(self)
        channel.shutDown()
        if let space { unmapPages(space, phys: bufferPhys, pages: bufferPages, address: userAddress) }
        space = nil
        pmm.free(bufferPhys, count: bufferPages)
        userWindowFrames -= bufferPages
        // `content` may wrap the freed buffer: give it a harmless surface.
        content = Surface(width: 1, height: 1)
    }

    private func mapBuffer(_ p: Process, phys: UInt, pages: Int) -> UInt? {
        guard let space else { return nil }
        return mapSharedFrames(p, space, phys: phys, pages: pages)
    }

    private func unmapBuffer(_ p: Process, phys: UInt, pages: Int, address: UInt) {
        guard let space else { return }
        unmapPages(space, phys: phys, pages: pages, address: address)
        // Drop the region if the process hasn't reshaped it.
        if let i = p.regions.firstIndex(where: { $0.start == address && $0.end == address + UInt(pages) * pageSize }) {
            p.regions.remove(at: i)
        }
    }
}

// MARK: Buffers and mappings

/// `width` x `height` XRGB pixels in a zeroed contiguous run of frames.
func allocateBuffer(width: Int, height: Int) -> (phys: UInt, pages: Int)? {
    guard width > 0, height > 0, width <= WinLimit.maxDimension, height <= WinLimit.maxDimension else { return nil }
    let pages = (width * height * 4 + Int(pageSize) - 1) / Int(pageSize)
    guard let phys = pmm.allocate(count: pages) else { return nil }
    UnsafeMutableRawPointer(bitPattern: phys)!.initializeMemory(as: UInt8.self, repeating: 0, count: pages * frameSize)
    return (phys, pages)
}

/// Map frames into `p` at a fresh address: a region (so map() avoids it)
/// whose pages are present and not owned. Nil without address space.
func mapSharedFrames(_ p: Process, _ space: AddressSpace, phys: UInt, pages: Int) -> UInt? {
    let r = p.mapAnonymous(hint: 0, length: UInt64(pages) * UInt64(pageSize), prot: MapProt.read | MapProt.write)
    guard r > 0 else { return nil }
    let addr = UInt(r)
    guard space.map(addr, phys, count: pages, flags: [.user, .write, .noExec]) else {
        _ = p.unmapRange(addr, UInt64(pages) * UInt64(pageSize))
        return nil
    }
    return addr
}

/// Unmap the pages at `address` that still map to our frames.
func unmapPages(_ space: AddressSpace, phys: UInt, pages: Int, address: UInt) {
    for i in 0..<pages {
        let v = address + UInt(i) * pageSize
        if let t = space.translate(v), t.phys == phys + UInt(i) * pageSize { space.unmap(v) }
    }
}

// MARK: The file

final class WindowFile: FileObject {
    let window: UserWindow
    let wm: WindowManager

    init(window: UserWindow, wm: WindowManager) {
        self.window = window
        self.wm = wm
    }

    override var waits: WaitList { window.channel.waits }

    override func ready() -> Int16 { window.channel.isReadable ? WaitEvent.readable : 0 }

    override func tryRead(_ max: Int) -> IOResult {
        let n = max / WinEvent.size
        guard n > 0 else { return .error(Errno.EINVAL) }
        guard let events = window.channel.take(n) else { return .wouldBlock }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(events.count * WinEvent.size)
        for var e in events {
            withUnsafeBytes(of: &e) { bytes.append(contentsOf: $0) }
        }
        return .data(bytes)
    }

    override func stat() -> StatInfo { StatInfo(size: 0, kind: StatKind.device, modified: 0) }

    override func lastClose() {
        onCPU0 { window.destroy(wm: wm) }
    }
}

// MARK: System calls

func windowFile(_ p: Process, _ fd: UInt64) -> WindowFile? {
    guard fd < UInt64(FdTable.maxFDs) else { return nil }
    return p.fds.get(Int(fd)) as? WindowFile
}

func copyOutValue<T>(_ addr: UInt64, _ value: T) -> Bool {
    var v = value
    return copyOut(addr, withUnsafeBytes(of: &v) { Array($0) })
}

func sysWinCreate(_ p: Process, _ w: UInt64, _ h: UInt64, _ titlePtr: UInt64, _ titleLen: UInt64, _ out: UInt64) -> Int {
    guard w >= 1, h >= 1, w <= UInt64(WinLimit.maxDimension), h <= UInt64(WinLimit.maxDimension),
          titleLen <= UInt64(WinLimit.maxTitle) else { return fail(Errno.EINVAL) }
    guard userRangeReady(p, UInt(out), MemoryLayout<WinInfo>.size, write: true) else { return fail(Errno.EFAULT) }
    guard let titleBytes = titleLen == 0 ? [] : copyIn(titlePtr, Int(titleLen)) else { return fail(Errno.EFAULT) }
    guard let space = p.space else { return fail(Errno.EINVAL) }
    var count = 0
    for o in p.fds.slots where o is WindowFile { count += 1 }
    guard count < WinLimit.maxPerProcess else { return fail(Errno.EMFILE) }
    let title = String(decoding: titleBytes.filter { $0 >= 0x20 }, as: UTF8.self)
    var result = 0
    var info = WinInfo()
    onCPU0 {
        guard let wm = userWindowManager() else { result = fail(Errno.ENODEV); return }
        let maxContent = Window.contentSize(frameWidth: wm.workArea.w, frameHeight: wm.workArea.h)
        let cw = min(Int(w), maxContent.w), ch = min(Int(h), maxContent.h)
        guard cw >= 1, ch >= 1, let buf = allocateBuffer(width: cw, height: ch) else { result = fail(Errno.ENOMEM); return }
        guard let addr = mapSharedFrames(p, space, phys: buf.phys, pages: buf.pages) else {
            pmm.free(buf.phys, count: buf.pages)
            result = fail(Errno.ENOMEM)
            return
        }
        // The framebuffer's pixel format, if it isn't 0x00RRGGBB.
        var convert: ((UInt32) -> UInt32)? = nil
        if let d = display, d.color(0x123456) != 0x123456 { convert = { d.color($0) } }
        let win = UserWindow(title: title, width: cw, height: ch, pid: p.pid, space: space, phys: buf.phys,
                             pages: buf.pages, address: addr, convert: convert)
        let file = WindowFile(window: win, wm: wm)
        guard let fd = p.fds.install(file) else {
            unmapPages(space, phys: buf.phys, pages: buf.pages, address: addr)
            _ = p.unmapRange(addr, UInt64(buf.pages) * UInt64(pageSize))
            pmm.free(buf.phys, count: buf.pages)
            result = fail(Errno.EMFILE)
            return
        }
        userWindowFrames += buf.pages
        userWindowsCreated += 1
        wm.add(win)
        info = win.info
        result = fd
    }
    guard result >= 0 else { return result }
    if !copyOutValue(out, info) {
        _ = p.fds.close(result)
        return fail(Errno.EFAULT)
    }
    return result
}

func sysWinPresent(_ p: Process, _ fd: UInt64, _ x: UInt64, _ y: UInt64, _ w: UInt64, _ h: UInt64) -> Int {
    guard let f = windowFile(p, fd) else { return fail(Errno.EBADF) }
    func clampInt(_ v: UInt64) -> Int { Int(max(-1 << 31, min(1 << 31, Int64(bitPattern: v)))) }
    let r = Rect(clampInt(x), clampInt(y), clampInt(w), clampInt(h))
    f.window.present(r)
    return 0
}

func sysWinResize(_ p: Process, _ fd: UInt64, _ w: UInt64, _ h: UInt64, _ out: UInt64) -> Int {
    guard let f = windowFile(p, fd) else { return fail(Errno.EBADF) }
    guard w <= UInt64(WinLimit.maxDimension), h <= UInt64(WinLimit.maxDimension),
          (w == 0) == (h == 0) else { return fail(Errno.EINVAL) }
    guard userRangeReady(p, UInt(out), MemoryLayout<WinInfo>.size, write: true) else { return fail(Errno.EFAULT) }
    var info = WinInfo()
    let r = onCPU0 { () -> Int in
        let r = f.window.adoptSize(p, wm: f.wm, width: Int(w), height: Int(h))
        info = f.window.info
        return r
    }
    guard r == 0 else { return r }
    return copyOutValue(out, info) ? 0 : fail(Errno.EFAULT)
}

func sysWinSetTitle(_ p: Process, _ fd: UInt64, _ ptr: UInt64, _ len: UInt64) -> Int {
    guard let f = windowFile(p, fd) else { return fail(Errno.EBADF) }
    guard len <= UInt64(WinLimit.maxTitle) else { return fail(Errno.EINVAL) }
    guard let bytes = len == 0 ? [] : copyIn(ptr, Int(len)) else { return fail(Errno.EFAULT) }
    let title = String(decoding: bytes.filter { $0 >= 0x20 }, as: UTF8.self)
    onCPU0 { f.window.title = title }
    return 0
}

func sysSysinfo(_ p: Process, _ out: UInt64) -> Int {
    guard userRangeReady(p, UInt(out), MemoryLayout<SysInfo>.size, write: true) else { return fail(Errno.EFAULT) }
    var s = SysInfo()
    s.ticks = ticks
    s.totalFrames = UInt64(pmm.totalFrames)
    s.usedFrames = UInt64(pmm.usedFrames)
    s.heapBytes = UInt64(heap.bytesInUse)
    s.heapBlocks = UInt64(heap.liveCount)
    s.tasks = UInt64(scheduler.taskCount)
    s.cpuCount = UInt64(max(smpStarted, 1))
    let n = min(Int(s.cpuCount), 8)
    func busy(_ i: Int) -> UInt64 { i < n ? perCPUEntry(i).pointee.busyTicks : 0 }
    s.busy0 = busy(0); s.busy1 = busy(1); s.busy2 = busy(2); s.busy3 = busy(3)
    s.busy4 = busy(4); s.busy5 = busy(5); s.busy6 = busy(6); s.busy7 = busy(7)
    onCPU0 {
        s.processes = UInt64(processTable.count)
        s.windows = UInt64(userWindowManager()?.windows.count ?? 0)
        s.compositorFrames = UInt64(display?.compositor.stats.frames ?? 0)
        let t = rtcNow()
        s.year = UInt64(t.year); s.month = UInt64(t.month); s.day = UInt64(t.day)
        s.hour = UInt64(t.hour); s.minute = UInt64(t.minute); s.second = UInt64(t.second)
    }
    return copyOutValue(out, s) ? 0 : fail(Errno.EFAULT)
}

// MARK: Launching programs from the desktop

/// The programs the taskbar's "+ Apps" menu lists (in /bin).
let guiApps = ["clock", "sysmon"]

/// Run /bin/<name> as a background process (no console: its output goes to
/// the kernel log; it is reaped when it exits). CPU 0.
func launchProgram(_ name: String) {
    do throws(ExecError) {
        _ = try spawnProcess(path: "/bin/" + name, argv: [name], output: nil, waiter: nil)
        print("launch: \(name)")
    } catch {
        print("launch: \(name) failed")
    }
}

/// Give the WM its "+ Apps" menu.
func installAppLauncher(_ wm: WindowManager) {
    wm.launchApp = { launchProgram($0) }
    wm.setApps(guiApps)
}
