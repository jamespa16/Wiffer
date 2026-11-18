# Roadmap

- **Part 1: Serial shell.** Done (M1–M4).
- **Part 2: Graphical shell.** Done (Phases A–G). The original plan for both
  parts is in git history (`git show 4cf881e:ROADMAP.md`).
- **Part 3: Window manager and text editor.** Phases H–N done (N4 stretch
  items not started). Phase O (stretch) is open. This document.

Goal: boot into a desktop with overlapping, draggable windows. Each shell
runs in its own terminal window, and a text editor can open, edit and save
files.

```
            H events + tasks ──────────────┐
                                           ▼
I surfaces ─→ J compositor ─→ K window manager ─→ L terminal windows
                                           │
            M RAM filesystem ──────────────┴─→ N text editor
                                                  │
                                                  └─→ O (stretch) disk, widgets
```

H, I and M don't depend on each other, so they can be built in parallel.

---

# Where we are

What Part 3 builds on:

- **Interrupts and input.** GDT/TSS/IDT with exception reports, 8259 PIC,
  PIT at 100 Hz, and PS/2 keyboard and mouse into ring buffers.
  `KeyEvent` has characters (Ctrl-letters arrive as control codes),
  arrows, Home/End, PgUp/PgDn, Insert and Delete. It has no Alt,
  function keys, or key-up events.
- **Memory.** A frame allocator and a size-class Swift heap. Large blocks
  are contiguous frame runs. QEMU has 256 MiB. Classes, `Array`, `String`,
  `Dictionary`, `Set` and `Float` all work (SSE is on).
- **Display.** `Console` is a cell grid with ANSI escapes. `Display`
  renders it into a back buffer and copies dirty rows to the framebuffer.
  The G4 layout is a status bar plus one titled "window", which is really
  a frame drawn in the cell grid. The mouse cursor is drawn straight onto
  the framebuffer and repainted after each row copy.
- **Shell.** `Shell<T: Terminal>` is generic over a blocking
  `read() -> KeyEvent`. It has history, completion, and a command table.
- **One flow of control.** `readKey()` is the idle loop. It polls serial,
  keyboard and mouse, refreshes the status bar, flushes the console, and
  calls `hlt`.
- **Tests.** `./run.sh --test` (and `--test --uefi`) runs in-kernel
  selftests plus a Python harness. The harness types through the QEMU
  monitor (`sendkey`, `mouse_move`) and checks `screendump` against a
  replayed serial transcript.

Two things stand in the way of a window manager:

1. **Everything is cell-based.** Overlapping windows need pixel surfaces,
   clipping, and a compositor that owns the screen.
2. **The shell blocks inside `read()`.** Two shells can't both be waiting
   for a key. Phase H solves this without rewriting the shell.

## Ground rules (carried over, plus new ones)

- Kernel flags stay: `-mno-red-zone`, `-mcmodel=kernel`, no stack protector.
- **No allocation in interrupt handlers.** IRQs only fill ring buffers. The
  event loop does the work.
- **Heap objects and stacks live at lower-half addresses** (the C3
  tag-bit problem). The framebuffer stays a raw
  `UnsafeMutablePointer<UInt32>`. New task stacks come from the heap or
  the frame allocator at identity-mapped addresses, never HHDM.
- **Never read the framebuffer.** All composition happens in a RAM back
  buffer, and only damaged rectangles are copied out.
- **Everything below the hardware is testable off-screen.** Surfaces, the
  compositor, the window manager and the editor are plain Swift types,
  driven in selftests with synthetic events and small sizes (as `Console`
  and `ScriptedTerminal` are today).
- **Prefer generics over `any`** (existentials are limited in Embedded
  Swift). Where a heterogeneous list is unavoidable, such as the window
  list, use a class hierarchy (`class Window`, subclassed by apps). Embedded
  Swift supports class inheritance and dynamic dispatch.

---

# Part 3: Window manager and text editor

## Phase H: event loop and cooperative tasks

**Done** (`events.swift`, `task.swift`, `task_selftest.swift`; `context_switch`
and `task_trampoline` in `cpu.S`).


**H1. One event queue.**

- Define an `Event` enum: `.key(KeyEvent)`, `.mouse(x, y, buttons)`
  (absolute position, after clamping), `.tick`, and later
  `.close` / `.focus(Bool)` / `.resize`.
- Split `readKey()` into `pollEvents()`, which drains serial, PS/2 and
  timer into an `[Event]` queue, and an idle step (flush the screen, `hlt`).
  Keep `readKey()` as a thin wrapper so Part 2 keeps working until L.

**H2. Richer keys.**

- Track Alt (`0x38`, and `E0 38` for AltGr). Decode F1–F12 and the
  Windows/Super key (`E0 5B`).
- Carry the modifiers with each key, e.g.
  `struct Key { var code: KeyEvent; var ctrl, alt, shift: Bool }`. The WM
  needs Alt-Tab and Alt-F4, and the editor needs Ctrl-S without guessing at
  control codes.
- Serial still yields plain `KeyEvent`s with the modifiers off.

**H3. Cooperative kernel tasks.** This is what lets the existing blocking
`Shell.run()` live in a window unchanged.

- `final class Task` holds a stack (64 KiB from the frame allocator, at an
  identity-mapped address), a saved `rsp`, and an inbox `[Event]`.
- Add `context_switch(from: &oldRSP, to: newRSP)` to `cpu.S`. It pushes
  the SysV callee-saved registers (`rbx`, `rbp`, `r12`–`r15`), swaps `rsp`,
  pops and `ret`s. It also saves `MXCSR` and the x87 control word, because
  those are callee-saved too. A new task's stack is pre-built so its
  first `ret` lands in a trampoline that calls the task's closure.
- The scheduler is a run queue plus `yield()`. A task waiting for input
  blocks until its inbox is non-empty. The main loop is task 0: it polls
  events, routes them, runs ready tasks, and `hlt`s when none are ready.
- No preemption. The timer IRQ never switches tasks, so the heap and
  console need no locks beyond what they already have. A task that spins
  forever hangs the desktop, which is fine for now. Add a status-bar
  watchdog warning if a task runs for more than 1 s without yielding.
- Guard pages are a stretch goal. They need your own page tables (the old
  C3 note). Until then, put a canary word at the bottom of each stack and
  check it on every switch.

**Done when:** a selftest runs two tasks that ping-pong 10,000 messages
through their inboxes without corrupting registers or the heap. And the
Part 2 shell, run as a task, still passes `./run.sh --test`.

## Phase I: pixel surfaces and drawing

**Done** (`surface.swift`, `surface_selftest.swift`).


**I1. `Rect` and `Surface`.**

- `struct Rect { x, y, w, h }` with `intersection`, `union`, `contains`,
  `isEmpty`, and `offsetBy`.
- `final class Surface` owns `width × height` `UInt32` pixels on the heap
  (a 640×480 window is 1.2 MiB, which is a large-block allocation). It also
  holds a current clip rect.

**I2. Primitives,** all clipped and allocation-free:

- `fill(rect, color)`, `hline`/`vline`, `frame(rect, color)`
- `blit(from: Surface, src: Rect, to: Point)`
- `drawGlyph` / `drawText(String, at:, fg:, bg:)` using the existing
  `PSFFont`. Measure text in cells, because the font is monospace.
- A 1-bit sprite blit with a mask. The mouse cursor art moves to this.

**I3. Port `Display` onto it.** Rendering a `Console` becomes
`ConsoleView.render(console, into: Surface, at: Point)`, drawing only dirty
rows. The full-screen console is then just one surface. This keeps Part 2
working and proves the API before any windows exist.

**Done when:** selftests check primitives pixel-by-pixel on small surfaces
(including clipping at every edge and negative coordinates). The boot
console still looks identical in the `screendump` check.

## Phase J: compositor

**Done** (`compositor.swift`, `compositor_selftest.swift`; stats via `gfx`).


- The compositor owns the screen: a screen-sized back buffer, an ordered
  layer list (bottom to top), and a **damage list** of `Rect`s. This is
  the G4 "damaged rectangles" leftover.
- `composite()` merges overlapping damage rects (or falls back to their
  bounding box past ~16 rects). For each rect it paints the layers that
  intersect it, bottom to top, into the back buffer, then copies just that
  rect to the framebuffer.
- Layers, bottom to top:
  1. Desktop background (a solid colour or simple pattern, drawn
     procedurally, no image decoder).
  2. Windows.
  3. Status bar / taskbar.
  4. Mouse cursor. It's now just the top layer, so the
     `repaintCursorRows` hack and direct framebuffer drawing go away.
- Moving the cursor damages its old and new rects only.
- Opaque windows only. Skip alpha blending. If you add shadows later, use
  a fixed 50% darken.
- Keep a `compositor.stats` counter (rects and pixels copied per frame) for
  the status bar. It makes performance regressions obvious.

**Done when:** an off-screen selftest stacks three overlapping layers,
damages a rect and checks that only it was repainted and that the pixels
are right. On QEMU, the cursor moves smoothly over a static desktop.

## Phase K: window manager

**Done** (`window.swift`, `wm.swift`, `taskbar.swift`, `wm_selftest.swift`).
Boot still shows the Part 2 shell; the `desktop` command (`startDesktop`)
turns the console into window #1 and the status bar into the taskbar.
Serial keys always go to that console's shell (`WindowManager.serialTarget`).
Launchers are hooks: `windowManager.openTerminal` / `openEditor`. Debug
commands: `windows`, `open`, `close <n>`, `warp <x> <y>`.

**K1. Windows.**

- `class Window` has a frame `Rect`, a title, a content `Surface`, an
  owning `Task` (optional), and flags (focused, dirty, closable).
- Methods subclasses override: `handle(_ event: Event)`, `draw()`, and
  `close()`.
- Decorations are drawn by the WM, not the app: a title bar with the
  title and a close box, plus a 1–2 px border. Focused and unfocused windows
  use different colours.

**K2. Focus and z-order.**

- Clicking a window raises it and gives it keyboard focus. This is the
  other G4 leftover.
- Keys go to the focused window, except for the WM's own shortcuts:
  - Alt-Tab cycles focus.
  - Alt-F4 closes the focused window.
  - Super+Enter opens a terminal (or use Ctrl-Alt-T if Super is awkward
    under QEMU).
- **Hit testing**: title bar, close box, border (for resize), and content.
  Mouse events in the content area go to the window under the cursor, in
  window-local coordinates.

**K3. Move and resize.**

- Dragging the title bar moves the window. Damage the old and new frames.
  Full repaint while dragging is fine at QEMU speeds. If it isn't, drag an
  outline and move once on release.
- Dragging the bottom-right corner resizes it. Allocate a new content
  surface and send the window `.resize`. Enforce a minimum size.
- Keep windows at least partly on screen, so the title bar is always
  reachable.

**K4. Taskbar.** Grow the status bar into a taskbar:

- A button per window (click to focus or raise), plus the clock and
  memory.
- A **"+ Terminal"** button and a **"+ Editor"** button. These are the
  launcher until there's anything fancier.

**Done when:** the harness opens two windows, drags one with `mouse_move`
plus button presses (the QEMU monitor's `mouse_button`), clicks to swap
focus, closes one, and checks each step with `screendump`. Selftests cover
hit-testing and focus order off-screen.

## Phase L: terminal windows

**Done** (`terminal_window.swift`, `terminal_window_selftest.swift`). Boot
goes straight to the desktop with one terminal; limine.conf entry 2 passes
`cmdline: nodesktop` (read through a Limine executable-cmdline request) for
the Part 2 full-screen shell. `build.sh` also makes
`build/wiffer-nodesktop.iso` (same files, `default_entry: 2`):
`./run.sh --nodesktop`. Each `TerminalWindow` runs `Shell<WindowTerminal>`
in its own task; `Shell.run()` now returns once `Terminal.finished` (set by
`exit`, or when `read()` gets `.close`, which it turns into Ctrl-C so the
half-typed line is dropped). Closing by any route ends the task: the WM
dropping the window's task posts `.close`. Resize re-creates the `Console`
keeping the cursor's rows. **Routing:** serial follows focus: the WM's
`serialTarget` is the most recently focused window that `acceptsSerial`
(terminals; `WindowManager.serialFollowsFocus`), serial keys go to it
whatever has focus, and its output is mirrored to COM1 while it is the
target; a serial key with no terminal open opens one. `print()` and all
kernel output go to serial and the (now off-screen) kernel console, shown by
`open log`. Exception and task-panic reports skip the WM and compositor:
`panicFlush` paints the kernel console and red status bar straight onto the
framebuffer. Harness: Part 2 checks, K's `desktop` checks and the selftest
boot the `nodesktop` ISO; faults, the editor and `terminal_checks` boot the
desktop (`terminal_checks` reads window text back from screendumps by
matching font glyphs).

- `TerminalWindow: Window` owns a `Console` sized to its content area, a
  `ConsoleView`, and a `Task` running `Shell<WindowTerminal>`.
- `WindowTerminal: Terminal`:
  - `read()` blocks the task until a key arrives in its inbox.
  - `write()` feeds the window's `Console` and marks the window dirty.
  - `columns` is the window's current width in cells.
- On resize, re-create the `Console` grid at the new size, keeping what
  fits. Reflow is optional.
- `print()` and kernel log output still go to serial. They also go to a
  "Log" window, or to the most recently focused terminal. Pick one and
  document it. Exception reports bypass the compositor: they paint
  directly on the framebuffer (and serial), because the kernel is dying.
- Shell commands that talk to the WM: `open <app>`, `windows`,
  `close <n>`, and `exit` (closes this terminal).
- Boot straight into the desktop with one terminal open. Keep a
  `nodesktop` kernel cmdline flag (from `limine.conf`) for the Part 2
  full-screen shell, which is handy when the WM is broken.

**Done when:** two terminals run side by side, each with its own history
and variables. Typing in one doesn't echo in the other. `./run.sh --test`
drives both through `sendkey` plus clicks.

## Phase M: RAM filesystem

**Done** (`fs.swift`, `ustar.swift`, `fs_commands.swift`, `fs_selftest.swift`;
seeded from `rootfs/`).


The editor needs files. Start in memory. Persistence is Phase O.

**M1. VFS.**

- `final class FSNode`: name, kind (file or directory), `[UInt8]`
  contents, children `[String: FSNode]` (needs Phase D, which is done),
  parent, and modification tick.
- Path helpers: split on `/`, resolve `.` and `..`, absolute or relative to
  a per-shell current directory.
- API: `lookup`, `create`, `mkdir`, `read`, `write`, `remove`, `rename`,
  `list`. Return errors as an enum (`notFound`, `exists`, `notADirectory`,
  `notEmpty`), not traps.

**M2. Seed it at boot from a Limine module.**

- Add a Limine **module request** in `boot.c`. Pack a directory (e.g.
  `rootfs/` with a README, a sample `.swift` file, and `motd`) into a
  ustar `rootfs.tar` in `build.sh`, and list it in `limine.conf`.
- Parse ustar in Swift (512-byte headers, octal sizes) into the RAM fs.
- Module memory is `BOOTLOADER_RECLAIMABLE`/HHDM. Copy contents into heap
  arrays and don't keep pointers into it.

**M3. Shell commands:** `ls`, `cd`, `pwd`, `cat`, `mkdir`, `rm`, `mv`,
`touch`, `write <file> <text>`, and `df` (total bytes in the fs).

**Done when:** `cat /README` shows the packed file after boot. A
create/write/rename/remove selftest leaves the heap's live-block count
where it started.

## Phase N: text editor

**Done** (N1–N3; `textbuffer.swift`, `editor_model.swift`, `editor_window.swift`,
`editor_selftest.swift`, `editor_window_selftest.swift`). N4 is not started.
`EditorWindow` has no task: `handle(_:)` drives the `EditorModel` directly
and turns `takeDamage()` into rows to repaint; `draw()` paints only those
rows and the status line, without allocating (the window's single
`pendingDamage` rect still unions them for the compositor). Quitting removes
the window through an `unowned(unsafe)` reference to its WM (set by
`openEditorWindow`). `edit [path]` (relative to the shell's cwd) needs the
desktop; the taskbar's "+ Editor" and `open editor` open an untitled editor.
The harness (`editor_checks`, using `enter_desktop()`) boots into the
desktop (Phase L) and types into the editor with `sendkey` while serial
drives terminal #1's shell.

`EditorWindow: Window`, opened with `edit <path>` from a terminal or the
taskbar button. The editing model is a plain struct that knows nothing
about windows, so it can be tested with scripted keys like the shell.

**N1. Buffer model (`TextBuffer`).**

- Store an array of lines, `[[UInt8]]` (UTF-8 bytes per line). It's the
  simplest structure that's fast enough for files of a few thousand lines.
  A gap buffer or piece table is unnecessary at this size.
- Cursor is `(line, column)` in bytes, kept on a scalar boundary. Keep a
  "desired column" so moving up and down through short lines works the way
  people expect.
- Operations: insert char/newline, backspace, delete, join and split
  lines, tab (insert spaces, width 4), and `load(bytes)` / `save() -> bytes`.
  Keep `\n` line endings, and preserve whether the file ends with a newline.
- A `dirty` flag, cleared on save.

**N2. View.**

- Draw into the window's surface with the PSF font: visible lines, a
  line-number gutter, and a block cursor.
- A status line at the bottom: path, `[+]` when modified, `Ln/Col`, and
  messages ("saved 42 lines").
- Vertical scrolling keeps the cursor in view. Horizontal scrolling for
  long lines (no soft wrap at first).
- Redraw only changed lines plus the old and new cursor lines, the same
  dirty-row idea as `Console`.

**N3. Keys.**

| Key                         | Action                                    |
|-----------------------------|-------------------------------------------|
| arrows, Home/End            | move                                      |
| PgUp/PgDn                   | move by a screenful                       |
| Ctrl-Home / Ctrl-End        | start / end of file                       |
| Ctrl-S                      | save (write the file through the VFS)     |
| Ctrl-O                      | open: prompt for a path in the status line |
| Ctrl-F                      | find: prompt, then jump to next match     |
| Ctrl-Q or the close box     | quit; if dirty, ask "save? y/n/esc"       |

- Mouse: click to place the cursor. Scroll wheel is a stretch, because it
  needs IntelliMouse mode on the PS/2 mouse (the `200,100,80` sample-rate
  knock, then 4-byte packets).

**N4. Stretch.**

- Undo/redo as a stack of inverse operations.
- Selection (Shift+arrows and mouse drag) with cut/copy/paste through a
  kernel clipboard, shared with terminal windows.
- Syntax highlighting for `.swift` keywords: a per-line colour pass with
  no state across lines, except block comments.

**Done when:** from a terminal, `edit /notes.txt` opens a window. You can
type several lines, move around, fix a typo, Ctrl-S and Ctrl-Q, and then
`cat /notes.txt` in the terminal shows the text. Selftests run the same
key script against `TextBuffer` and check the saved bytes. The harness does
it end-to-end with `sendkey` and a `screendump`.

## Phase O (stretch): beyond the basics

Pick and choose. Each is independent.

- **Persistence.** A virtio-blk driver needs PCI config-space enumeration
  (port `0xCF8`/`0xCFC` is enough under QEMU) and a virtqueue. The simpler
  option is ATA PIO on the q35 AHCI controller in IDE mode, or `-M pc`.
  Then either mount a FAT image read/write, or write the RAM fs out as a
  tar on Ctrl-S. That's crude but simple.
- **A tiny widget kit.** Labels, buttons and a text field on top of
  `Surface`, so dialogs ("save changes?") stop being status-line prompts.
- **More apps** to prove the WM API: a clock, a system monitor (frames,
  heap, tasks, compositor stats), and a file browser that opens the editor.
- **Better input.** QEMU's `usb-tablet` gives absolute mouse coordinates
  and no grab, but needs an xHCI driver, which is a big job. Keyboard
  typematic repeat for held arrows can be done in software, from key-down
  plus timer.
- **Isolation.** Your own page tables (guard pages, then ring-3 apps via
  the GDT user slots and TSS `rsp0` from Phase A), and preemptive
  scheduling on the timer. This is where a "basic" WM turns into a real OS.
  Defer it until the cooperative design actually hurts.

---

## Cross-cutting: testing the desktop

- **Off-screen first.** `Surface`, `Compositor`, `WindowManager`,
  `TextBuffer` and `FSNode` take plain values and events, so most checks
  live in `selftest.swift` and run in milliseconds.
- **Harness additions** (`tests/serial_session.py`):
  - A `click(x, y)` helper (`mouse_move` + `mouse_button 1` / `0`).
  - A `drag(from:, to:)` helper.
  - A `pixel_at(x, y)` check on `screendump`s.

  Remember the monitor socket takes only one client, so share the existing
  connection.
- **Determinism.** Mouse movement in QEMU is relative and can be scaled.
  Before clicking, read the kernel's idea of the pointer (the `mouse`
  command), or add a `warp x y` debug command, rather than trusting
  absolute moves.
- Run `./run.sh --test` and `./run.sh --test --uefi` after every phase.
  Expect merge hot spots in `build.sh`, `kernel.swift` init order, the
  `selftest.swift` call list and the harness.

---

# Part 4: SMP

Goal: every CPU QEMU (or the machine) has runs kernel tasks. The desktop
keeps working unchanged, and compute tasks spread across all CPUs.

```
P atomics, spinlocks, per-CPU data ─┐
                                    ├─→ R AP bring-up ─→ S SMP scheduler ─→ T demo, tests, docs
Q x2APIC, IPIs, more IDT vectors ───┘
(harness: -smp N plumbing, alongside P/Q)
```

P and Q don't depend on each other.

## Design decisions

- **Affinity instead of locking everything.** The window manager,
  compositor, consoles, shells and RAM fs stay unlocked and **pinned to
  CPU 0** (the BSP). A task has `affinity: .cpu(n)` or `.any`. Every
  existing task (shells, terminals, task 0) is `.cpu(0)`. Only `.any` tasks
  migrate, and they may touch only SMP-safe code: the heap, frame
  allocator, scheduler, inboxes, `print`/`puts`, and their own data. A
  task that needs the UI posts an event to a CPU 0 task.
- **Device IRQs stay on the BSP.** Keep the 8259 PIC and the PIT (100 Hz,
  `ticks`) on CPU 0, delivered through the BSP's LAPIC LINT0 in
  virtual-wire mode. There's no IOAPIC. APs get IPIs only.
- **x2APIC only (MSRs, no MMIO mapping).** Ask Limine's MP request for
  x2APIC (`LIMINE_MP_REQUEST_X86_64_X2APIC`). QEMU runs with
  `-cpu max` (TCG has x2APIC). If x2APIC or the MP response is missing,
  run single-CPU exactly as today. That's a supported configuration, so
  test it.
- **Cooperative still.** There's no preemption and no APIC timer.
  Idle CPUs `hlt` and are woken by a reschedule IPI when a task they may
  run becomes ready.
- **Swift runtime is already SMP-safe:** refcounts are atomic, and
  `swift_once` is a cmpxchg plus spin (checked in build/kernel.raw.ll). The
  `Synchronization` module (`Atomic`) is available in Embedded Swift, as
  are clang `__atomic_*` builtins through bridge.h.
- **Stacks and per-CPU blocks** live at identity-mapped (lower-half)
  addresses, as the ground rules already require.

## Phase P: atomics, spinlocks, per-CPU data

**P1. Spinlock.** `struct SpinLock` (test-and-test-and-set with `pause`)
and an IRQ-saving variant, `lock.withIRQsOff { }`, which does
`irq_save` → acquire … release → `irq_restore`. It records the owning CPU
and panics on a recursive acquire. It also counts contended acquires, for
the `cpus` command. Add a recursive variant for stdout.

**P2. Per-CPU block.** `final class`-free plain storage: a fixed
`InlineArray` of `PerCPU` structs (max 64 CPUs), indexed by CPU index
(0 = BSP). Fields:

- index and APIC id
- `current` task and `idle` task, with the zombies list
- GDT, TSS and double-fault IST stack
- stats: switches, idle ticks, IPIs received

Point `IA32_GS_BASE` (MSR `0xC0000101`) at the CPU's entry, so
`thisCPU()` is a `%gs:0` load (C helper in bridge.h). Give each CPU its
own GDT and TSS. A TSS descriptor's busy bit means two CPUs can't `ltr`
the same one, so `gdtInit()` becomes `gdtInit(cpu:)`. The IDT stays
shared.

**P3. Lock the shared allocators and output.**

- heap and pmm: `irq_save` becomes the IRQ-saving spinlock.
- `_swift_lockStandardOutput`/`unlock`: the recursive spinlock.
- `puts`/`printHex`/`printDec` raw paths: the same lock.
- Exception and panic paths try the lock with a bounded spin, then write
  anyway (the kernel is dying).

**Done when:** a single-CPU build passes `./run.sh --test`. New
selftests cover lock/unlock, the recursion panic path (as a test
predicate, not a real panic), `thisCPU().index == 0`, and that GS base
matches the BSP's block.

## Phase Q: x2APIC, IPIs, more vectors

**Q1. MSR helpers** in bridge.h (`rdmsr`/`wrmsr`) and `cpuid`. Detect
x2APIC (CPUID.1:ECX bit 21).

**Q2. `apic.swift`.**

- Enable x2APIC: `IA32_APIC_BASE` (MSR `0x1B`) bits 10 and 11, and the
  spurious-vector register (MSR `0x80F`) = `0x1FF`.
- Read the id from MSR `0x802`.
- EOI: MSR `0x80B` ← 0.
- ICR is MSR `0x830`, a single 64-bit write in x2APIC.
- `sendIPI(apicID, vector)`, `broadcastIPI(vector, excludingSelf)`, and an
  NMI IPI for panics.
- On the BSP, program LINT0 as ExtINT and LINT1 as NMI, so the 8259
  keeps delivering IRQs through the LAPIC. On APs, mask both.

**Q3. Vectors.** Extend the cpu.S stub table to all 256 vectors. Generate
it with `.irp`/`.rept`, keeping the error-code list correct. Reserve:

- `0xF0` reschedule (wake)
- `0xF1` halt (panic: stop this CPU)
- `0xF2` test/ping (counts per CPU, for selftests)
- `0xFF` spurious (no EOI)

`interrupt_dispatch` sends LAPIC EOI for `0xF0`–`0xFE` and PIC EOI for
32–47, as now.

**Done when:** on one CPU, a selftest sends a self-IPI (`0xF2`, ICR
destination shorthand "self") and sees the counter tick. Single-CPU
`./run.sh --test` still passes.

## Harness: `-smp N`

`./run.sh` and `tests/serial_session.py` pass `-cpu max -smp N`. N
comes from `--smp N` or `WIFFER_SMP` and defaults to 4. `./run.sh --test`
runs with 4, and `./run.sh --test --smp 1` with 1.

## Phase R: AP bring-up

**Done** (smp.swift, percpu.swift, boot.c, bridge.h, kernel.swift,
descriptors.swift `idtLoad`, interrupts.swift, shell.swift, selftest.swift,
percpu_selftest.swift, build.sh). `smpInit()` runs right after the BSP's first
`sti` (pmm, heap, IDT, x2APIC and PIT ticks exist) and waits up to 100 ticks
(1 s) for the APs. Each AP gets a 64 KiB stack (`PerCPU.stackBase/stackTop`,
for Phase S's idle task) and a 16 KiB #DF stack; `ap_entry` -> `apEnterStack`
(SSE-checked by build.sh) -> `apMain` -> `apIdleLoop()` (`sti; hlt`, counts
`idleWakeups`; Phase S replaces it). APs print nothing. `cpus` command,
"cpu N" in exception reports, AP selftests (ping, CR3, online count).

- Add a `limine_mp_request` (flags: x2APIC) in boot.c. Read its response
  after pmm and heap init.
- For each AP, allocate its stack (64 KiB, identity-mapped) and fill in
  its `PerCPU` entry on the BSP. Then write `extra_argument` = CPU index
  and `goto_address` = `ap_entry` (a `@_cdecl` that enables SSE first,
  exactly like `kernel_main`). Extend build.sh's no-SSE check to cover
  it.
- On the AP:
  1. Switch to its own stack (`switch_stack`).
  2. `gdtInit(cpu:)`, `lidt` (shared IDT), set GS base.
  3. Enable x2APIC and mask LINTs.
  4. Mark itself online (an atomic counter), `sti`, then enter the
     per-CPU idle loop (`hlt` until there's work).
- The BSP waits, with a timeout, until all APs are online, then
  `print`s `smp: N CPUs online`.
- Limine's page tables are shared. mapLowerHalf patches the live PML4
  before APs start, so they see the lower-half aliases. Check that each
  AP's CR3 equals the BSP's.
- `cpus` shell command: per CPU, show the index, APIC id, online, current
  task, switches, idle %, IPIs and lock contention.

**Done when:** with `-smp 4`, boot prints 4 CPUs online and `cpus` lists
them. A selftest pings each AP with `0xF2` and sees each counter advance.
Both `--smp 1` and `--smp 4` pass `./run.sh --test` (BIOS and UEFI).

## Phase S: SMP scheduler

- `scheduler.current` becomes `thisCPU().current`. The scheduler's
  shared state (run queue, `all`, `nextID`) sits behind one IRQ-saving
  spinlock, as do task state changes and `Task.post` (the inbox is
  touched by a poster on CPU 0 and an owner elsewhere).
- **One shared run queue,** filtered by affinity: a CPU takes the first
  task it may run. That's fine at this size. Per-CPU queues and work
  stealing are a stretch.
- **Cross-CPU handoff.** A task switched out on CPU A must not be resumed
  on CPU B until A has finished saving its rsp. Give `Task` an `onCPU`
  word. `context_switch` gets a third argument, a pointer to the outgoing
  task's flag, and clears it (`movq $0`, a release store on x86) after
  saving rsp and before loading the new one. `prepareSwitch` takes the
  lock and dequeues; then, after unlocking, it spins until
  `next.onCPU == 0` and sets it to 1.
- **Lock across the switch:** don't. Drop the lock before
  `context_switch`. The `onCPU` flag covers the race.
- **Each AP has an idle task** (its boot stack). Idle loop: take the
  lock, dequeue a runnable task or `hlt` with interrupts on. Use the
  `sti; hlt` pair to avoid the lost-wakeup race, after re-checking the
  queue with IRQs off.
- **Wakeups.** When a task becomes ready (`spawn`, `post`, `yield`), if
  some idle CPU may run it, send `0xF0` to one idle CPU. Track idle CPUs
  in an atomic bitmask. CPU 0 keeps its current `hlt`-in-`idleStep` loop;
  the PIT wakes it.
- **Zombies** are per-CPU, freed by the next task that runs on that CPU.
- **Watchdog** stays on CPU 0's `ticks`. Track a mark per CPU; the BSP's
  timer IRQ checks all of them.
- **Panics on any CPU:** take a panic flag (first CPU wins), send `0xF1`
  to the others (NMI if they don't stop within 10 ms), then report as
  today. `exceptionReport` prints the CPU index.
- `spawn(name, affinity: .any, …)`. The default stays `.cpu(0)`, so
  nothing existing changes behaviour.

**Done when:** these selftests pass with `-smp 4`:

- 4 × `.any` tasks hammer a shared spinlocked counter and the heap
  (allocate/free arrays) for 100k iterations each. The count is exact and
  the heap's live count returns to baseline.
- Two `.any` tasks ping-pong 10,000 messages and are seen running on
  different CPUs.
- `check_callee_saved` passes across migrations.
- A task pinned to `.cpu(2)` only ever runs on CPU 2.

The whole existing suite still passes on `--smp 1` and `--smp 4`.

## Phase T: demo, tests, docs

- Shell command `par <n>`: count primes below `n` with one `.any` task per
  CPU, then print each CPU's share and the wall time (in ticks) against
  a one-task run. Results come back to the shell's task through its
  inbox.
- Taskbar: show the CPU count, plus a busy dot per CPU (idle or not).
- Harness: `smp_checks` boots with `-smp 4`, runs `cpus` and `par`, and
  checks the result.
- Update "Where we are" and README.md's Wiffer entry.
