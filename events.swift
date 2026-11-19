// Phase H1: one event queue. pollEvents() drains every input source (COM1,
// the PS/2 keyboard and mouse rings, the timer) into `events`; idleStep()
// shows pending output and sleeps. The main loop (runMainLoop, task.swift)
// and the Part 2 readKey() are both built from those two.
// Phase H2: `Key`, a KeyEvent plus the modifiers held when it was pressed.

/// A key press with its modifiers. Ctrl-letters keep their control-code
/// `code` (Ctrl-S is `.char(0x13)` with `ctrl` set), so KeyEvent consumers
/// such as the shell see what they always did. Serial input has no
/// modifiers: they are all off.
struct Key: Equatable {
    var code: KeyEvent
    var ctrl: Bool
    var alt: Bool
    var shift: Bool
    /// The Windows / Super key is held.
    var meta: Bool
    /// Came over serial (COM1) rather than the PS/2 keyboard. The WM sends
    /// these to its serialTarget (Phase K).
    var serial: Bool

    init(_ code: KeyEvent, ctrl: Bool = false, alt: Bool = false, shift: Bool = false, meta: Bool = false,
         serial: Bool = false) {
        self.code = code
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
        self.meta = meta
        self.serial = serial
    }

    /// Ctrl plus `letter` (either case), e.g. `key.isCtrl("s")`, without
    /// spelling out control codes.
    func isCtrl(_ letter: Unicode.Scalar) -> Bool {
        ctrl && code == .char(UInt8(truncatingIfNeeded: letter.value) & 0x1F)
    }

    /// Alt (or AltGr) plus `code` and no Ctrl, e.g. `key.isAlt(.function(4))`.
    func isAlt(_ code: KeyEvent) -> Bool { alt && !ctrl && self.code == code }
}

/// Everything the main loop routes. Inbox messages between tasks use
/// `.message`; `.close`, `.focus` and `.resize` are for windows (Phase K).
enum Event: Equatable {
    case key(Key)
    /// Pointer position in framebuffer pixels (already clamped), and the
    /// buttons (bit 0 left, 1 right, 2 middle).
    case mouse(x: Int, y: Int, buttons: UInt8)
    /// Phase 8H: the mouse wheel turned at (x, y): `delta` notches, positive
    /// = away from the user (scroll up).
    case wheel(x: Int, y: Int, delta: Int)
    /// The timer advanced (at most one per poll; the payload is `ticks`).
    case tick(UInt64)
    case close
    case focus(Bool)
    case resize(width: Int, height: Int)
    /// Task-to-task message with an integer payload.
    case message(Int)
}

/// FIFO of events. Popping moves a head index; the array is emptied (keeping
/// its capacity) once drained, so a steady flow doesn't reallocate.
struct EventQueue {
    var events: [Event] = []
    var head = 0

    var isEmpty: Bool { head == events.count }
    var count: Int { events.count - head }

    mutating func post(_ event: Event) {
        if events.capacity == 0 { events.reserveCapacity(32) }
        events.append(event)
    }

    /// Post a mouse event, replacing a not-yet-read mouse event at the tail
    /// if the buttons are the same (a run of moves becomes one).
    mutating func postMouse(x: Int, y: Int, buttons: UInt8) {
        if head < events.count, case .mouse(_, _, let b) = events[events.count - 1], b == buttons {
            events[events.count - 1] = .mouse(x: x, y: y, buttons: buttons)
        } else {
            post(.mouse(x: x, y: y, buttons: buttons))
        }
    }

    mutating func next() -> Event? {
        guard head < events.count else { return nil }
        let event = events[head]
        head += 1
        if head == events.count {
            events.removeAll(keepingCapacity: true)
            head = 0
        }
        return event
    }
}

/// Raw input waiting to be routed (filled by pollEvents).
var events = EventQueue()

/// Serial input goes through an escape-sequence decoder (terminal.swift),
/// so arrows, Home/End and Delete work over serial as well as on PS/2.
var serialKeys = EscapeDecoder()
/// Tick of the last serial byte, to time out a lone ESC.
var serialLastByte: UInt64 = 0
/// A lone ESC becomes the Escape key after this many quiet ticks (200 ms).
let escapeTimeoutTicks: UInt64 = 20
/// `ticks` when the last .tick event was posted.
var lastTickPosted: UInt64 = 0

/// Drain COM1 (through serialKeys), the keyboard ring (through
/// keyboardDecoder), the mouse ring (moving the cursor sprite) and the
/// timer into `events`. Never blocks.
func pollEvents() {
    while inb(com1 + 5) & 0x01 != 0 {
        serialKeys.feed(inb(com1))
        serialLastByte = ticks
    }
    if serialKeys.pending && ticks &- serialLastByte >= escapeTimeoutTicks { serialKeys.timeout() }
    while let code = serialKeys.pop() { events.post(.key(Key(code, serial: true))) }

    while let code = keyboardRing.pop() {
        if let key = keyboardDecoder.feedKey(code) { events.post(.key(key)) }
    }

    var moved = false
    while let byte = mouseRing.pop() {
        if let packet = mouseParser.feed(byte) {
            mouse.apply(packet)
            moved = true
            events.postMouse(x: mouse.x, y: mouse.y, buttons: mouse.buttons)
            if packet.dz != 0 { events.post(.wheel(x: mouse.x, y: mouse.y, delta: -packet.dz)) }
        }
    }
    if moved { cursorMove(x: mouse.x, y: mouse.y) }

    netPollHook() // Part 7: wake netd if the NIC or a stack timer has work

    let t = ticks
    if t != lastTickPosted {
        lastTickPosted = t
        events.post(.tick(t))
    }
}

/// The screen side of the main loop: refresh the status bar (when due) and
/// show pending console output. Called from idleStep, and at most once per
/// timer tick while tasks keep CPU 0 busy (runMainLoop), so the desktop
/// doesn't freeze while CPU 0 runs compute work.
func refreshStep() {
    let statusDue = statusNextTick
    statusBarRefresh()
    if statusNextTick != statusDue { watchdogStatus() } // the status bar was redrawn
    consoleFlush()
}

/// Nothing to do: refresh the status bar, show pending console output (and
/// echo), and sleep until the next interrupt (the timer bounds the wake-up
/// latency for the polled UART).
func idleStep() {
    refreshStep()
    if interruptsEnabled { // hlt with IF=0 would never wake
        // Phase S: let other CPUs' wakeups IPI us rather than wait for the
        // PIT. Not race-free (the PIT still bounds the latency), and harmless.
        if gsBaseReady { setIdle(true) }
        hlt()
        if gsBaseReady { setIdle(false) }
    }
    if gsBaseReady { watchdogPet() } // sleeping isn't hogging the CPU
}

/// Wait for the next key (Part 2's blocking input; LiveTerminal.read).
/// In a task, it blocks on the task's inbox (the main loop routes keys
/// there). Outside one, or in the main loop's own task, it polls the
/// devices itself and drops other events.
func readKey() -> KeyEvent {
    if let task = scheduler.current, !task.isMain { return waitKey().code }
    while true {
        pollEvents()
        while let event = events.next() {
            if case .key(let key) = event { return key.code }
        }
        idleStep()
    }
}
