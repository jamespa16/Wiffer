# Roadmap

- **Part 1: Serial shell.** Done (M1–M4).
- **Part 2: Graphical shell.** Done (Phases A–G). The original plan for both
  parts is in git history (`git show 4cf881e:ROADMAP.md`).
- **Part 3: Window manager and text editor.** Phases H–N done (N4 stretch
  items not started). Phase O (stretch) is open. This document.
- **Part 4: SMP.** Done (Phases P–T).
- **Part 5: Writing to disk.** Phases U–Y. In progress.

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
- **SMP.** Other CPUs start through Limine MP with x2APIC, and a single
  CPU is the fallback. Per-CPU data sits behind GS. Spinlocks take locks
  in the order schedLock → heapLock → pmmLock → stdoutLock. One shared run
  queue filters by affinity. Tasks default to `.cpu(0)`, so the WM,
  console, shells and fs stay on CPU 0, and `.any` tasks migrate. IPIs
  wake idle CPUs and halt the rest on panic. The `cpus` and `par` commands
  show it. `./run.sh --test --smp N` runs with N CPUs (default 4). Known
  limit: a task off CPU 0 must post results rather than print, because
  consoleFlush isn't synchronised with stdoutLock.

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

- **Persistence.** Now Part 5 (below). Original note: a virtio-blk driver needs PCI config-space enumeration
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

**Done** (task.swift, sched_selftest.swift, task_selftest.swift, smp.swift,
percpu.swift, apic.swift, interrupts.swift, events.swift, cpu.S, bridge.h,
shell.swift, selftest.swift, terminal_window_selftest.swift,
tests/serial_session.py). `spawn(name, affinity: .cpu(0) | .any | .cpu(n),
stackSize:, body)`; `.cpu(n)` for a CPU that isn't online returns nil.
`currentCPU()` gives a task its CPU; results go back with
`shellTask.post(.message(n))` (any CPU; wakes the target, IPIs CPU 0 if it's
in idleStep's hlt). `scheduler` is now a `final class` (no CPU ever copies the
shared arrays); per-CPU state is a `CPUSched` object (current, idle,
zombies) reached through `PerCPU.sched` (Unmanaged bits), built by the BSP
in smpInit before each AP starts, so APs allocate nothing while booting.
`cpus` shows each CPU's current task ("idle" on idle APs). `fault ap` runs a
`#UD` in a `.cpu(1)` task; the harness checks its report (`cpu    1`, exit 5)
when `-smp` >= 2. Lock order: **schedLock → heapLock → pmmLock →
stdoutLock**; allocating under schedLock (run-queue appends, inbox posts, the
watchdog's print) is allowed, nothing takes schedLock under another lock, and
Task.deinit (heap, pmm) runs outside it (zombies are freed after the lock
is dropped). Deviations from the plan below:

- `context_switch(save, load, onCPU)` clears the outgoing task's `onCPU`
  word *after* loading the new rsp, not between saving and loading: an
  interrupt in between would push onto a stack another CPU may already
  have resumed. Interrupts stay enabled across the switch.
- `yield`'s requeue and the pick happen in one lock section (the pick
  first, so the yielder can't be stolen by another CPU while it decides to
  keep running); `waitEvent` re-checks the inbox under the lock before
  blocking.
- Wakeups prefer an idle AP (round-robin from the last one woken); CPU 0
  is a candidate only if it's the only CPU allowed. CPU 0 marks itself idle
  around idleStep's `hlt`; that's best-effort (the PIT still bounds it).
- Watchdog marks are per CPU (`PerCPU.watchdogMark/Active/Tripped`); an AP
  counts only while it runs a real task, and a yield that finds nothing
  else to run still counts as cooperating.
- Panics: `panicBegin()` (first CPU wins a CAS on `panicOwner`) broadcasts
  0xF1, waits ~10 ms (TSC) for the others to count themselves halted, then
  NMIs the stragglers; an NMI'd or losing CPU halts silently. Task-panic
  reports now end with `(cpu N)`.
- Known limit (not fixed here): `print` from an AP is serialised by
  stdoutLock, but CPU 0's consoleFlush/render reads (and clears the dirty
  state of) the kernel console without it, so the two can race. Serial
  output is fine. Until the flush is made safe, `.any` tasks should report
  results by posting to a CPU 0 task (as Phase T's `par` plans to) rather
  than printing.

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

**Done** (par.swift, shell.swift, taskbar.swift, wm.swift, smp.swift,
selftest.swift, tests/serial_session.py; the docs bullet below is done
too). `par [n]` (default 3,000,000, 2..100,000,000) spawns one `.any`
worker per online CPU, each trial-dividing strided 4096-number chunks of
[0, n) (yielding per chunk so the watchdog stays quiet), then repeats with
one worker. Workers never print: each posts `.message(worker << 48 | cpu << 40
| count)` to the shell task, which gathers them with `waitEvent()`; any
other event that arrives meanwhile (keys) is stashed and re-posted to the
shell task afterwards. Output: a line per worker (id, cpu, primes), the
parallel and single totals with ticks and ms, "ERROR totals differ" on a
mismatch, and the speedup. Measured under QEMU TCG (MTTCG is already the
default; no `-accel` change needed): default n at `-smp 4` 13 vs 55 ticks
for 2M (4.2x); `-smp 2` 2.0x; `-smp 1` 1.0x. Taskbar: "cpu N" plus one dot per
CPU left of the status text (filled = busy, outlined = idle); an AP is busy
while its `watchdogActive` word is set, CPU 0 (which does the reading) while
its switch count moved since the last refresh. Updated with the clock, twice
a second; the existing taskbar pixel checks needed no change. Harness:
`smp_checks` (run in the main session) checks `cpus` row count, `par 1000000`
(78498) and `par 200000` (17984) totals, the worker count, more than one CPU
used when `-smp` >= 2, the speedup line and bad input; a `help` line check
for `par`; selftests cover `countPrimes` (pi(10)=4, pi(100)=25,
pi(10000)=1229) and the strided split.
- Update "Where we are" and README.md's Wiffer entry. **Done.**

## After Part 4: soft affinity, usage meters

**Done** (task.swift, sched_selftest.swift, smp.swift, taskbar.swift,
events.swift, wm_selftest.swift).

- **Soft affinity.** A task's home is the CPU it last ran on. Each CPU
  takes tasks homed on it first. Only a CPU in its idle context steals:
  an AP's idle task, task 0, or a task that is blocking or exiting. A busy
  CPU that yields never takes another CPU's task, so busy CPUs don't trade
  work.
- **When a task can be adopted.** It's new (on an AP), its home is busy,
  or it has waited `stealDelayTicks` (2). CPU 0 adopts only after that
  delay, or when no AP may run the task, so APs get first claim on compute
  work.
- **Wakeups** go to the home CPU when it's idle.
- **Effect.** Under `par`, workers stay on one CPU each. Before, they
  bounced through CPU 0. Throughput is unchanged: the working set is tiny.
- **`softAffinity = false`** restores the Phase S behaviour. The `.any`
  ping-pong selftest uses it to keep stressing cross-CPU handoff.
- **Taskbar usage meters.** CPU 0's timer IRQ samples every CPU at 100 Hz
  into `PerCPU.busyTicks` (an AP is busy when off its idle task, CPU 0
  when not in idleStep's `hlt`). Each meter fills by its share of the last
  half-second. They replace Phase T's instantaneous busy dots.
- **Desktop no longer freezes while CPU 0 computes.** runMainLoop calls
  `refreshStep()` (status bar and console flush, the screen half of
  idleStep) at most once per tick while tasks are ready.

---

# Part 5: Writing to disk

Goal: files survive a reboot. A FAT32 volume on a virtio disk is mounted
at `/disk`. Anything written there — `write`, `mkdir`, `mv`, `rm`, or
Ctrl-S in the editor — reaches the disk before the command returns. The
rest of `/` stays in RAM, seeded from rootfs.tar as before. The image is
plain FAT32 with no partition table, so the host can read it too
(`hdiutil attach -imagekey diskimage-class=CRawDiskImage build/disk.img`
on macOS, or `tests/fat32.py`).

```
U block layer (block.swift: done) ─┬─→ V PCI + virtio-blk ──┐
                                   ├─→ W FAT32 read/format ─→ X FAT32 write ─┼─→ Y /disk: VFS, commands, persistence tests
                                   └─→ Z host tool (tests/fat32.py) ───────┘
```

V, W→X and Z don't depend on each other. They meet only at `BlockDevice`
(block.swift) and the `FATVolume` API below. Y joins them.

## Design decisions

- **virtio-blk, legacy interface, polled.** The legacy (0.9.5) transport
  works entirely through an I/O-port BAR: there's no MMIO to map. QEMU
  gets `-device virtio-blk-pci,drive=vd0,disable-legacy=off,disable-modern=on`
  (vendor 0x1AF4, device 0x1001). Completion is found by polling the used
  ring, with `pause` and a tick timeout. No IRQ is needed, so there's no
  IOAPIC or INTx routing. QEMU completes most requests before the notify
  returns anyway. AHCI and NVMe are later options. They'd slot in as more
  `BlockDevice` subclasses.
- **DMA is easy here.** PML4[0] identity-maps physical memory (pmm.swift),
  so a pointer from `pmm.allocate(count:)` is also the device address.
  The virtqueue and a bounce buffer are contiguous frame runs, allocated
  once at probe time. Don't DMA into Swift arrays.
- **FAT32, whole-disk ("superfloppy"), 512-byte sectors.** It's simple
  enough to write, and every host can read it. Long file names (VFAT LFN)
  are read and written, so names keep their case and length. Lookup is
  case-insensitive, as FAT requires. A 64 MiB image at 512-byte clusters
  is 131k clusters, comfortably FAT32. Format refuses volumes under the
  65,525-cluster minimum. The sparse `RamDisk` makes full-size test
  volumes cheap.
- **Write-through, mirrored in RAM.** Mounting loads the whole volume into
  FSNodes under the mount point, so reads (`cat`, `ls`, the editor) don't
  change at all. Every mutating `FileSystem` call on a path under a mount
  goes to the `FATVolume` first. Only if that succeeds is the RAM tree
  changed, so a disk error leaves both sides as they were. Each operation
  ends with a device flush. This won't scale to a huge disk; that's fine
  for now, and the size of what's loaded is shown by `df`.
- **Crash-safe ordering for file writes.** Write the new data into newly
  allocated clusters, then point the directory entry at them, then free the
  old chain. A failure partway leaks clusters at worst (fsck reports them).
  It never corrupts an existing file. FSInfo's free count is a hint and is
  recomputed when it looks wrong.
- **CPU 0 only**, like the RAM fs and the WM (Part 4 affinity), so it needs
  no locks. A long transfer spins on CPU 0. That's acceptable for now.
- **Swift first** (as always): PCI, virtio and FAT are Swift. bridge.h only
  gains `outw/inw/outl/inl` and volatile/fenced load/store helpers for the
  rings.
- **Timestamps** come from the CMOS RTC (ports 0x70/0x71, BCD). If reading
  it fails, use 2026-01-01 00:00.

## Phase U: block layer

**Done** (block.swift; selftest `blockTests`). `class BlockDevice` holds a
name, `sectorCount` and `readOnly`. `read(lba, count) -> [UInt8]`,
`write(lba, bytes)` and `flush()` are range-checked wrappers that throw
`BlockError` (`outOfRange`, `io`, `readOnly`). Drivers override
`readSectors`/`writeSectors`/`flush`. `RamDisk` is sparse and can inject
write failures (`failWritesAfter`). Every device found goes into the
global `blockDevices`.

## Phase V: PCI and virtio-blk

**Done** (`pci.swift`, `virtio_blk.swift`, `rtc.swift`; selftests
`pciTests`, `rtcTests`, `virtioTests`). `diskInit()` (after `smpInit()`)
runs `pciInit()`, which fills `pciDevices` (BARs sized with decoding and
interrupts off), then probes every 1af4:1001 function as `VirtioBlock`
vda, vdb, ... into `blockDevices`. A modern-only 1af4:1042 is reported
and skipped. One polled queue with one request in flight. Fixed
descriptors 0–2 point into a request frame (header at 0, status at 16)
and a 64 KiB bounce buffer (128 sectors per chunk). `avail.flags =
NO_INTERRUPT`, and ISR is read after each completion. A request that
times out (2 s of ticks, or a spin cap if interrupts are off) marks the
device `broken`. The device may still own the buffers then, so every
later request fails with `.io`. `flush()` sends T_FLUSH if the device
offers F_FLUSH, otherwise it does nothing. `rtcNow()` returns a named
tuple `RTCTime` (`rtcDecode` is separately tested). bridge.h gained
`outw/inw/outl/inl`, `dma_load16/dma_store16/dma_load8` (acquire/release)
and `dma_fence`. Shell: `lspci`, `disks`. Under both SeaBIOS and OVMF,
the disk is at 00:03.0 with I/O BAR 0 already assigned: 128 bytes, the
legacy header plus device config, at 0xc000 under SeaBIOS and 0x6000 under
OVMF. MSI-X is off, so device config starts at 0x14. No firmware quirks were needed. The driver still sets
I/O + bus master in the command register itself. run.sh creates
`build/disk.img` (64 MiB of zeros) if it's missing. `--nodisk` leaves the
disk off (with `--test`, the harness's main session too, via
`WIFFER_NODISK`). The harness's main session gets a fresh scratch image in
a temp dir. `DISK_CHECKS` (or `NODISK_CHECKS`) run after the shell checks.
Restoring the selftest's sectors was checked by booting on 64 MiB of
random data, running `selftest`, and comparing hashes (BIOS and UEFI).

**V1. PCI** (`pci.swift`). Config mechanism #1 (0xCF8/0xCFC). Brute-force
bus 0–255, device 0–31, and functions 0–7 for multi-function devices. That
gives a `[PCIDevice]` with location, vendor/device, class/subclass, BARs
(I/O or memory, with sizes) and an interrupt line. Helpers read and write
config dwords and enable I/O and bus mastering. Shell: `lspci`.

**V2. virtio-blk** (`virtio_blk.swift`, `final class VirtioBlock:
BlockDevice`). Follow the legacy init sequence: reset, ACK, DRIVER, read
features, accept `VIRTIO_BLK_F_FLUSH` (and `RO`, if present), queue 0
size, allocate the queue (descriptor table + avail ring, then the used
ring at the next 4 KiB boundary), write the PFN, then DRIVER_OK. Capacity
comes from device config. Each request is a 3-descriptor chain: a 16-byte
header (type, sector), the data in the bounce buffer, and a 1-byte status.
Split large transfers by bounce-buffer size. Use T_FLUSH for `flush()`.
Time out after about 2 s and report `.io`. Name devices vda, vdb and so
on, and add them to `blockDevices` in `diskInit()`, called from
kernel.swift after `smpInit()`.

**V3. Shell, run.sh, harness.**
- `disks` lists name, size in MiB, sectors read/written and `ro`.
- `rtc.swift`: `rtcNow()` returns (year, month, day, hour, minute,
  second).
- run.sh attaches `build/disk.img` (64 MiB; created blank if missing; Y
  makes it formatted). `--nodisk` leaves it off.
- The harness's main session attaches a fresh scratch image under a temp
  dir, so a test run never touches build/disk.img.
- Selftest (only when vda exists): save the last sector, write a pattern,
  read it back, flush, then restore the sector.
- Harness check: `lspci` shows 1af4:1001, and `disks` shows vda at
  64 MiB.

**Done when:** BIOS and UEFI boots both find vda. The round-trip selftest
passes. Booting with `--nodisk` still passes everything else.

## Phase W: FAT32 read and format

**Done** (fat32.swift, fat32_selftest.swift; selftest `fatTests`, run after
`blockTests`). The API below as written, except that `label` and
`freeClusters` are `private(set)` and the geometry is `let`. Format follows
the Microsoft table and FAT-size formula. A 64 MiB disk gets 1016-sector
FATs and 129,008 clusters of 512 B; 293 MiB gets 4 KiB clusters. Under
65,525 clusters gives `.noSpace`, and a bad label gives `.invalidName`. The
FATs and the root cluster are zeroed in 64-sector writes, and the boot
sector at 0 is written last. Mount always counts the free clusters from
the FAT, in 32 KiB reads; FSInfo is only a hint and is never trusted. The
label comes from the root's label entry, or else from the BPB ("NO NAME" =
""). Directories are read whole, one per path component, on every call: no
directory cache. The FAT cache holds whole sectors keyed by index. Dirty
ones are written to every FAT copy in runs, and the cache is dropped past
512 sectors. A chain is `.corrupt` if it runs off the volume, into a free
or bad cluster, or past `totalClusters` links (a loop). LFN runs need
consecutive sequence numbers and the matching checksum, or the 8.3 name is
shown instead. Orphaned LFN entries are skipped. Lookup folds only ASCII
and matches long names only (not `NAME~1`). Short names above 0x7F are
shown as Latin-1. Checked against macOS: images written here pass
`fsck_msdos` and mount with names intact, and a `newfs_msdos` volume filled
by macOS lists, reads and checks clean here (a host build of
fat32.swift + block.swift). Z's fixture hadn't landed, so it isn't tested
yet. The FAT tests add about 0.35 s to a ~1.9 s selftest.

`fat32.swift` (plus `fat32_selftest.swift`) is pure Swift over a
`BlockDevice`. It's written against `RamDisk` only, so it needs nothing
from V.

```swift
enum FATError: Error, Equatable {
    case notFAT32, corrupt, notFound, exists, notADirectory, isADirectory,
         notEmpty, invalidName, noSpace, io(BlockError)
    var message: String { ... }
}
struct FATEntry { var name: String; var isDirectory: Bool; var size: Int }
final class FATVolume {
    static func format(_ dev: BlockDevice, label: String) throws(FATError)
    static func mount(_ dev: BlockDevice) throws(FATError) -> FATVolume
    let device: BlockDevice
    var label: String; var clusterSize: Int; var totalClusters: Int; var freeClusters: Int
    // paths are components from the volume root; names match case-insensitively
    func list(_ path: [String]) throws(FATError) -> [FATEntry]
    func read(_ path: [String]) throws(FATError) -> [UInt8]
    // Phase X:
    func write(_ path: [String], _ bytes: [UInt8]) throws(FATError) // create or replace
    func mkdir(_ path: [String]) throws(FATError)
    func remove(_ path: [String]) throws(FATError)  // a file or an empty directory
    func rename(_ from: [String], to: [String]) throws(FATError) // `to` must not exist
    func sync() throws(FATError)                   // FSInfo, then device flush
    func check() -> [String]                       // fsck: problems, [] when clean
}
```

- **Format.** BPB/EBPB at sector 0 with a backup at 6, and FSInfo at 1
  (and 7). 32 reserved sectors, 2 FATs, root at cluster 2, `0x55AA`
  signatures, and the volume label in the root directory as well. Take
  sectors per cluster from Microsoft's FAT32 table.
- **Mount** validates the BPB: bytes per sector 512, power-of-two
  sectors/cluster, FAT32 by cluster count, not by the type string.
- **Directory parsing:** 8.3 entries, LFN sequences with the checksum
  verified (fall back to the 8.3 name on mismatch), deleted (0xE5) and
  end (0x00) markers, and skipping `.`, `..` and the volume label.
- **Cache:** whole FAT sectors, write-back until the end of each
  operation. Cluster chains are followed with loop detection, which
  reports `.corrupt`.
- **Selftests:**
  - format a 64 MiB RamDisk, mount it, check geometry and free count
  - hand-build directory sectors with LFN and 8.3 names and list them
  - a corrupt BPB gives `.notFAT32`
  - a FAT loop gives `.corrupt`
  - Z's image fixture (if Z has landed) is listed correctly
  - the heap goes back to baseline after unmount

## Phase X: FAT32 write

**Done** (same files). Timestamps come from the global
`fatClock: () -> FATTimestamp`, which defaults to `fatDefaultClock`
(2026-01-01 00:00). Y should point it at `rtcNow()`. Each mutating call runs
inside `update`, which flushes the FAT, FSInfo and then the device. If the
call throws, the volume drops its FAT cache and recounts the free clusters
from disk. The commit point is one sector write: the 8.3 entry's sector
(written last when adding, first when deleting). A call that throws has not
reached it, so the disk still reads as before. Errors after it (freeing the
old chain, deleting a rename's old entry) are swallowed, because at worst
they leak clusters or orphan LFN entries. The data goes out before the
commit: new clusters, their FAT links, then a device flush. A pre-commit
failure tries to free the new chain again. A directory grows by a zeroed
cluster, marked end-of-chain and flushed before it's linked in. Replacing a
file needs room for both copies, so a full disk gives `.noSpace` even when
the new contents are smaller. Writing an existing name in another case
replaces that file and keeps its spelling. A generated short name never
reuses one in the directory: a plain 8.3 name that is taken gets an LFN
and `~N`. Rename is in place when it stays in one directory and needs no
more slots, and only a change of case is allowed onto the same entry.
Moving a directory into itself gives `.invalidName`, since FATError has no
`invalidMove` (Y's VFS checks first anyway). An empty path gives
`.invalidName` (`read([])` gives `.isADirectory`). `check()` doesn't
compare the FAT copies. `reserve(path, size:)` allocates without writing
data, so the full-disk test can fill a volume cheaply. The power-cut sweep
cuts after every possible write count of a 12-sector-write overwrite.
Breaking the write order (freeing the old chain before the commit) makes it
fail, as does skipping the LFN checksum in the hand-built test.

- **Names:** pick a short name (`NAME~1.TXT`) and write LFN entries when
  the name isn't a valid uppercase 8.3 name. Characters outside FAT's set
  give `.invalidName`. Store the 8.3 case bits (0x08/0x10) for
  all-lowercase names, as Windows does.
- Directory entries are allocated from free or deleted slots, and the
  directory grows by a cluster when it's full. `mkdir` writes `.` and
  `..` (`..` = 0 for the root's children).
- File write follows the crash-safe order above. Free chains on remove.
  Rename rewrites the entry in place when only the name changes,
  otherwise it writes the new entry, then deletes the old one. Moving a
  directory updates its `..`. Timestamps come from `rtcNow()` (stub it
  in a test hook until V lands).
- **`check()`** compares the FAT with what the directories reference:
  lost clusters, cross-links, sizes against chain lengths, and FSInfo
  against the real free count.
- **Selftests:**
  - a script of create/write/overwrite/grow/shrink/mkdir/rename/remove,
    then remount from the same RamDisk and compare against a model
    `FileSystem`
  - `check()` is clean after every step
  - a full disk gives `.noSpace` with nothing leaked
  - a `failWritesAfter` sweep over one overwrite leaves the old or the
    new contents readable, and check() reports at most lost clusters
  - long and mixed-case names round-trip
  - heap baseline

## Phase Z: host tool `tests/fat32.py`

A Python 3 stdlib-only implementation, written from the spec and
independent of the Swift code: two implementations checking each other.
`fat32.py mkfs IMG [--size 64M] [--label WIFFER]`, `ls IMG [path]`,
`cat IMG path`, `put IMG hostfile path`, `mkdir IMG path`, and
`fsck IMG` (exit 1 on problems). It has an importable API for the harness.
It has its own tests in `tests/test_fat32.py`
(`python3 -m unittest tests/test_fat32.py`). If `newfs_msdos`/`mkfs.fat`/
`mtools` are present, it cross-checks against them. They aren't required.
It also produces a small fixture image for W's selftest. That fixture is
`tests/fixtures/fat32-lfn.img.gz`, or a generator in build.sh: whichever
keeps the ISO small. The kernel would read it as a Limine module.

**Done** (tests/fat32.py, tests/test_fat32.py, tests/fixtures/). Written
from fatgen103 without looking at fat32.swift.
- **mkfs** follows the spec: the sectors/cluster table (64 MiB gives 1,
  so 512-byte clusters), its FATSz formula (64 MiB: 1016-sector FATs,
  129,008 clusters), 32 reserved sectors, FSInfo at 1/7 and the backup
  boot sector at 6. It refuses anything up to 66,600 sectors and anything
  under 65,525 clusters. The smallest volume it accepts is 33 MiB (66,504
  clusters). The image is created sparse with `truncate`.
- **Volume** API: `list/read/write/mkdir/remove(recursive)/stat/walk/tree/check`.
  The FAT is held in memory as an `array('I')` and written to both copies
  per dirty sector. Everything else is seek/read on the image. Writes are
  crash-safe in the order the design asks for: new chain, then entry, then
  free the old chain. Each call syncs FSInfo, and the free count is always
  recomputed on open.
- **Names:** exact uppercase 8.3 names get no LFN. All-lowercase base
  and/or extension use the NT bits 0x08/0x10. Mixed-case 8.3 names
  (`Readme.txt`) get an LFN with no tail. Anything else gets the spec's
  basis name (spaces and embedded dots stripped, `+,;=[]` and non-ASCII
  become `_`) plus `~N`, with N counting up past collisions
  (`LONGF~10`).
- **fsck** checks:
  - the BPB, both signatures, the backup boot sector and both FSInfo
    sectors
  - that the FAT copies match, plus FAT[0]/FAT[1] and the dirty bit
  - the whole directory tree: loops, cross-links, chains that run into
    free/bad/out-of-range clusters, size against chain length
  - LFN sequences: orphans, ordinal breaks, checksum mismatch
  - `.`/`..` position and targets, duplicate names, lost clusters, and the
    FSInfo free count
- **Gotcha: no gzip in the kernel.** Raw, the fixture would put 33 MiB in
  the ISO, and the kernel has no inflate. So there are two copies:
  `fat32-lfn.img.gz` (35 KB, for the host) and `fat32-lfn.sparse` (15 KB).
  The sparse file is "FATSPRS1", then u32 total sectors and u32 extent
  count, then per extent u32 LBA, u32 count and the sectors. The kernel can
  copy it straight into a `RamDisk(sectorCount:)`.
  - The expected tree is `FIXTURE_TREE`, documented in
    `build_fixture`'s docstring: LFN names, NT case bits, a `~2` tail, a
    lossy name, an empty file, a 10-cluster file, nested dirs, a deleted
    run, and a root spanning 2 clusters.
  - A test checks that the committed files match the generator, which is
    deterministic: fixed volume id and timestamps.
- **Cross-checks:** macOS `fsck_msdos -n` works on plain image files, and
  it runs on the images the tests write. `hdiutil attach -nomount` plus
  `diskutil mount` works without sudo (plain `mount -t msdos` needs root
  to load the kext). With `FAT32_MOUNT_TEST=1`, the tests mount images
  both ways: macOS reads our writes, and macOS's writes (with `._` files)
  fsck clean here. Tests for `mkfs.fat`/`fsck.fat`/mtools are written but
  skipped here: those tools aren't installed.
- Not done: rename (the kernel has it; the harness only needs host reads).

## Phase Y: /disk

- **VFS mounts** (`fs.swift`): `FileSystem.mount(volume, at:)` loads the
  volume into FSNodes under the mount point. `unmount(at:)` syncs it and
  drops them. Mutations under a mount call the volume first (see the
  design decisions). Recursive `rm -r` removes bottom-up. Cross-mount
  `mv` gives `.crossDevice`. Removing or renaming a mount point gives
  `.busy`. New `FSError` cases: `io`, `noSpace`, `invalidName`,
  `crossDevice`, `busy`. FAT's case-insensitive collisions come back as
  `.exists`.
- **Boot:** `diskInit` mounts vda at `/disk` if it holds FAT32. Otherwise
  it prints `vda: no FAT32 filesystem (mkfs vda)`.
- **Shell:** `mkfs <dev> [label]`, `mount <dev> <dir>`, `umount <dir>`,
  `sync`, and `fsck <dir>`. `df` adds a per-mount line (label, used/free
  MiB). `disks` shows mount points.
- **run.sh** formats a new build/disk.img with `tests/fat32.py mkfs`.
- **Editor:** saving under /disk just works. An I/O error shows up as
  `save: /disk/x: I/O error`, and the buffer stays dirty.
- **Harness:**
  1. boot with a scratch image made by fat32.py, holding a host-written
     file
  2. `cat` it
  3. `write`, `mkdir`, `mv` and `rm` under /disk
  4. edit `/disk/notes.txt` in the editor and Ctrl-S
  5. `sync`, then kill QEMU
  6. boot a second QEMU on the same image and check every file
  7. finally run `fat32.py fsck` plus `cat` on the host

  Also: `mkfs` on a blank image, a full disk, and `--nodisk`.

**Done when:** a note written in the editor survives a reboot and reads
back on the host. `./run.sh --test`, `--test --uefi` and `--smp 1` pass.
