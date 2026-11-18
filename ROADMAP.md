# Roadmap

- **Part 1: Serial shell.** Done (M1–M4).
- **Part 2: Graphical shell.** Done (Phases A–G). The original plan for both
  parts is in git history (`git show 4cf881e:ROADMAP.md`).
- **Part 3: Window manager and text editor.** Phases H–N done (N4 stretch
  items not started). Phase O (stretch) is open. This document.
- **Part 4: SMP.** Done (Phases P–T).
- **Part 5: Writing to disk.** Done (Phases U–Z): a FAT32 virtio disk at /disk.
- **Parts 6–8: Toward a web browser.** Planned: user space (6A–6G),
  networking (7A–7F), and a browser (8A–8I). See the end of this document.
  Part 6: 6A–6E done (page tables, ring 3 and syscalls, processes, ELF
  programs in /bin, libwiffer, preemption and timed sleeps, fds, pipes,
  wait); 6F–6G open.
  Part 7: 7A–7C done (virtio-net, Ethernet/ARP/IPv4/ICMP, UDP, DHCP, DNS);
  7D–7F open.

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
- **Disk (Part 5).** A legacy virtio-blk disk (polled, CPU 0 only) holds a
  whole-disk FAT32 volume with long names. It is mounted at /disk, which
  is loaded into RAM and written through, so `write`, `mv`, `rm` and the
  editor's Ctrl-S reach the disk before they return. run.sh formats a
  missing build/disk.img, and `tests/fat32.py` reads and writes images on
  the host. Commands: `disks`, `lspci`, `mkfs`, `mount`, `umount`, `sync`,
  `fsck` and `df`.

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

**Done** (fs.swift, virtio_blk.swift, fs_mount_selftest.swift; selftest
`fsMountTests`, after `fatTests`). `FileSystem.mount(volume, at:)` needs
an empty directory that isn't "/", isn't on or under another mount, and a
volume not already mounted (`.busy`). It loads the tree recursively with
`loadDir` plus the new `FATVolume.contents(of:)`, so files aren't
re-walked from the root. The depth limit is 64 (`.corrupt` past that).
The mount point node holds the `FATVolume`. Each change below it calls
the volume first, and the RAM tree changes only on success. `unmount(at:)`
syncs (errors ignored: everything was already flushed), then drops the
nodes. The rules:
- **Case.** Lookups below a mount fold ASCII case. Writing to a case
  variant of an existing file writes that file and keeps its spelling.
  Creating a case variant of a different entry (create, mkdir, a rename's
  target) gives `.exists`. Renaming an entry to another case of its own
  name is allowed, and `mv dir DIR` renames rather than moving into itself.
- **touch and append.** `touch` on an existing file only bumps the RAM
  tick. Append rewrites the whole file.
- **`rm -r`** removes bottom-up, one FAT call per entry.
- **rename** works within one mount only. RAM to or from a mount, or one
  mount to another, gives `.crossDevice`. Removing or renaming a mount
  point, or a directory above one, gives `.busy`.
- **RAM paths** are unchanged: exact lookups. `usage` skips mount points.

New `FSError` cases: `io`, `noSpace`, `invalidName`, `corrupt`,
`crossDevice`, `busy` and `notMounted`, with `init(FATError)`. `diskInit`
points `fatClock` at `rtcNow()`. If vda exists it makes /disk and mounts
the volume there: `vda: FAT32 'WIFFER' mounted at /disk, 0.0 of 63.0 MiB
used, 129008 clusters of 512 bytes`. Otherwise it prints `vda: no FAT32
filesystem (mkfs vda)`, and /disk stays an empty directory.

New shell commands: `mkfs <dev> [label]` (refused while mounted), `mount
[dev dir]` (with no arguments, it lists mounts), `umount`, `sync` and
`fsck <dir>`. `df` adds a line per mount, and `disks` adds a mount column.
`sync` made Tab on "s" ambiguous between three commands, so that
completion selftest now uses "mo" → "mou" (mount, mouse).

run.sh formats a missing build/disk.img with `tests/fat32.py mkfs` and
puts a README.TXT on it. It never touches an existing image. The second
Limine module is `fat32-lfn` (tests/fixtures/fat32-lfn.sparse, copied
into the ISO by build.sh and found with `bootModule(named:)`). It is
loaded into a RamDisk, mounted, and compared with Z's FIXTURE_TREE: names,
sizes, contents and big.bin's formula. That's the cross-implementation
check, and it passes.

Selftests: a mirrored script, then a remount compared tree for tree; with
`failWritesAfter = 0`, every operation gives `.io` and neither tree
changes; a power-cut sweep over an overwrite; the case rule;
crossDevice/busy and mount errors; `.noSpace` on a filled volume; the
editor saving through a mount (`save: /m/notes.txt: I/O error`, still
dirty, then a retry); a shell transcript with a RamDisk as "ram9"; and
the heap back to baseline.

Harness: the main session's scratch image comes from `fat32.mkfs`, with a
host-written /hello.txt. It runs `DISK_CHECKS` (cat, write, mkdir, mv,
rm, the error messages, df, sync, fsck, disks, mount), then checks the
image on the host after the selftest (fsck clean, kept.txt). Two extra
QEMUs boot alongside it:
- **Blank image:** the "no FAT32" message, `mkfs vda`, `mount`, `umount`,
  remount, then the host reads the file.
- **Persistence:** in the desktop, edit /disk/notes.txt with sendkey and
  Ctrl-S, then Ctrl-Q, then write and mkdir from the terminal, `sync`,
  and kill QEMU. A second boot on the same image `cat`s every file, and
  `fat32.fsck` and `read_file` agree.

`--nodisk` skips both and checks that there is no /disk. A full disk is
tested in the selftest, not over serial.

**Gotcha: OVMF writes `NvVars`** (its emulated variable store) into the
root of any FAT volume it finds. A UEFI boot leaves that file in /disk,
and the harness ignores it.

Known limits:
- The whole volume sits in RAM.
- A file written from the host while the kernel has the disk mounted
  isn't seen until a remount, and QEMU's image lock prevents that anyway.
- `touch` doesn't update FAT timestamps.
- `mv` between mounts doesn't copy.

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

---

# Parts 6–8: toward a web browser

The end goal is a **mostly-working web browser** in the default apps. It
loads real text-heavy sites over HTTPS (Wikipedia, Hacker News,
lite.duckduckgo.com, text.npr.org, info.cern.ch), lays them out with CSS,
shows images, follows links and submits simple forms. **JavaScript is out
of scope** until after Part 8 (see "After Part 8"). That rules out
single-page apps, but most document-style sites still read fine without
it.

Getting there takes three parts:

- **Part 6: User space.** Page tables per process, ring 3, syscalls, ELF
  programs, preemption for user code, and windows owned by processes. A
  browser is a large pile of parsers fed hostile input. It must be able to
  crash without taking the desktop with it.
- **Part 7: Networking.** virtio-net, Ethernet/ARP/IPv4/ICMP, UDP, DHCP,
  DNS, TCP, and a sockets API for processes.
- **Part 8: Browser.** TLS 1.3, HTTP/1.1, HTML, CSS, fonts, layout,
  images, and the browser app itself.

```
Part 6  6A page tables ─→ 6B ring 3 + syscalls ─→ 6C processes, ELF, libwiffer ─┬─→ 6D preemption
                                                                                 ├─→ 6E files, stdio, shell runs /bin ─┐
                                                                                 └─→ 6F windows for processes ─────────┤
Part 7  7A virtio-net ─→ 7B Eth/ARP/IPv4/ICMP ─→ 7C UDP, DHCP, DNS ─→ 7D TCP ────────────────────┬────────────────────┤
                                                                                     6E ─────────┴─→ 7E sockets ─→ 7F fetch, MSI-X
Part 8  8A crypto + TLS ─┐
        8B URL, HTTP, inflate ─┤
        8C HTML ─┐             │
        8D CSS ──┼─→ 8F layout + paint ─┴─→ 8H browser app (needs 6F, 7E) ─→ 8I tests, target sites
        8E fonts ┤
        8G images┘
```

**Parts 6 and 7 can run side by side.** Part 7 up to 7D lives entirely in
the kernel and is tested with in-kernel selftests and the harness, so it
doesn't wait for user space. They meet at 7E (sockets). **Most of Part 8
doesn't need either.** 8A–8G are pure Swift libraries with no OS
dependencies, so they can start right away, built and tested on the host
(see the design decisions below).

## Design decisions (all three parts)

### Address space

The kernel already owns two lower-half slots. That fixes where user space
can go:

| PML4 slot | Range | Owner |
|---|---|---|
| 0 | 0 – 512 GiB | kernel: identity map, heap, task stacks (supervisor-only) |
| 1–254 | 0x0000_0080_0000_0000 – 0x0000_7f7f_ffff_ffff | **user** (per process) |
| 255 | 0x0000_7fff_8000_0000+ | kernel: image alias for String literals |
| 256–511 | upper half | kernel: HHDM, kernel image |

- **Each process gets its own PML4.** Slots 0, 255 and 256–511 are copied
  from the kernel's PML4. They point at shared PDPTs, so the kernel looks
  the same in every address space. Slots 1–254 are private.
- **Never add a top-level kernel entry after the first process exists.**
  It wouldn't appear in older PML4s. 6A preallocates a PDPT for every
  empty upper-half slot at boot so this can't happen by accident.
- **User/supervisor bits.** Only slots 1–254 ever get U=1. All kernel
  entries stay U=0, so ring 3 can't touch the identity map.
- **SMEP and SMAP on** (if CPUID has them; `-cpu max` does). The kernel
  touches user memory only inside `copyIn`/`copyOut`/`withUserBuffer`,
  which validate the range by walking the page tables and bracket the
  access with `stac`/`clac`.
- **NX.** Check that EFER.NXE is set (Limine sets it), and map code R+X,
  data RW+NX, and stacks RW+NX.
- Swift's pointer tag bits (the reason for the identity map) are fine for
  user programs: every user address is below 2^47.
- User programs link at **0x0000_0100_0000_0000** (slot 2). The stack
  goes at the top of slot 254, with an unmapped guard page below it.

### Kernel entry and exit

- **SYSCALL/SYSRET.** The GDT already orders user data (0x18) before user
  code (0x20) for SYSRET, so STAR = `0x0010 << 48 | 0x0008 << 32` works.
  LSTAR points at an asm stub in cpu.S. FMASK clears IF, DF and TF.
- **swapgs.** Today the kernel writes GS_BASE directly and user space
  never runs. From 6B: GS_BASE holds the per-CPU pointer while in the
  kernel, and KERNEL_GS_BASE holds the user value (0) while in ring 3.
  The syscall stub and every IDT stub swap only when the saved CS has
  RPL 3. Get this wrong and the kernel crashes in odd places, so 6B tests
  it directly (an interrupt during user code, a fault in user code, a
  nested IRQ during a syscall).
- **Per-CPU TSS rsp0** (the TSS is already per CPU) is set to the
  incoming task's kernel stack top on every switch to a user task.
- **SYSRET's non-canonical RCX bug** (Intel): if the return RIP isn't
  canonical, return through `iretq` instead.
- **ABI.** The number goes in rax. Arguments go in rdi, rsi, rdx, r10, r8
  and r9. The result comes back in rax, with negative values meaning
  `-errno`. Numbers and structs are defined once, in `abi/syscalls.swift`,
  which is compiled into both the kernel and libwiffer. Use our own small
  syscall table, not Linux's. POSIX or Linux compatibility (running
  static musl binaries as a source of apps) is deferred until after
  Part 8. Keep the API small and our own until then.

### Scheduling

- **A process is a Task plus an address space.** `final class Process`
  holds a pid, an `AddressSpace`, an fd table, a cwd, its windows, a
  parent and an exit status. Its thread is a normal `Task` with a kernel
  stack and a saved user context. Processes are **single-threaded** in
  Part 6. The browser uses one thread and an event loop (`wait`, 6E).
- **Preempt user code only.** The timer interrupt switches tasks only if
  it interrupted ring 3. Kernel code stays cooperative, so every
  assumption that unlocked CPU-0-only code relies on still holds. A user
  infinite loop can't freeze the desktop. A kernel one still can, as
  today.
- **APs need a timer.** The PIT ticks only CPU 0. 6D starts the x2APIC
  timer on every CPU, calibrated against the PIT, at 100 Hz. On CPU 0
  the PIT stays the clock, and on APs the LAPIC timer only preempts.
- **CPU-0 subsystems via a hop.** The fs, WM, terminals and (Part 7) the
  network stack are unlocked and pinned to CPU 0. A process may run on
  any CPU (`.any`), so a syscall that touches one of them calls
  `onCPU0 { ... }`. That sets the task's affinity to `.cpu(0)`, yields,
  runs the body, and then restores the affinity. It's just the Part 4
  scheduler, used for one syscall at a time.

### Networking

- **virtio-net, legacy, like virtio-blk.** QEMU gets `-netdev
  user,id=n0 -device
  virtio-net-pci,netdev=n0,disable-legacy=off,disable-modern=on`
  (1af4:1000). User-mode networking (SLIRP) needs no host setup and works
  in CI. The guest is 10.0.2.15, the gateway is 10.0.2.2 (which is also
  the host, for test servers), and DNS is 10.0.2.3. `-object
  filter-dump,id=f0,netdev=n0,file=build/net.pcap` captures traffic for
  Wireshark when debugging. It's off by default, with `./run.sh --pcap`.
- **Polled first, interrupts later.** 7A polls the rx ring from the main
  loop, like the disk. The catch is that CPU 0 `hlt`s until the next PIT
  tick, which adds up to 10 ms of latency per wakeup. That's fine for
  ping and DNS but slow for TCP. 7F adds MSI-X, which delivers straight
  to a LAPIC vector, so there's still no IOAPIC. It needs 6A's
  `mapMMIO`, because the MSI-X table is in a memory BAR.
- **The stack is a kernel task on CPU 0** (`netd`), driven by rx events
  and timer deadlines. It's unlocked, like the fs. Packet buffers are
  `final class Packet` with headroom, so headers can be pushed without
  copying. A free list caps memory.
- **IPv4 only.** IPv6 is "After Part 8". Fragmented IP packets are
  reassembled, but we never fragment our own (TCP MSS keeps segments
  under the MTU).
- **`NetDevice` is a class hierarchy like `BlockDevice`.** `VirtioNet`,
  `Loopback`, and `LinkPair`, which joins two stacks in memory with
  injected loss, reordering, duplication and delay. The whole stack, TCP
  included, is tested off-screen this way. That's the existing ground
  rule.

### Browser and libraries

- **Shared libraries are pure Swift and build two ways.** HTML, CSS,
  layout, URL, HTTP parsing, inflate, PNG/JPEG, TrueType and crypto
  don't touch the OS. They go in `lib/<name>/` and compile both into
  Wiffer user programs (Embedded Swift) and into a host test binary
  (`./run.sh --hosttest`, with the pinned toolchain). Most of the
  browser's bugs will be in parsing and layout, and a host test loop
  takes seconds where a QEMU boot takes a minute. Code must stay within
  the Embedded Swift subset (no `any` existentials or reflection), so
  the host build uses `-enable-experimental-feature Embedded` too, or at
  least a CI check that the Embedded build still compiles.
- **TLS and crypto in pure Swift: no C libraries.** Either write it from
  scratch or port an existing pure-Swift library. 8A starts by surveying
  the candidates (CryptoSwift covers hashes, AES and ChaCha20 but not
  elliptic curves; there are a few TLS 1.3 implementations in pure
  Swift). A port has to work in Embedded Swift: no Foundation, no
  existentials, no reflection. If it would need more rewriting than
  writing from scratch, write it. Wrappers around C libraries
  (BoringSSL-based swift-crypto, swift-nio-ssl) are out. Either way,
  fixed test vectors decide whether it works: RFC 8448 has whole recorded
  TLS 1.3 handshakes. Hand-written crypto here is for a hobby OS, not for
  protecting anything real. Constant-time code is a goal, not a
  guarantee.
- **TLS 1.3 only at first.** Nearly every major site supports it. TLS 1.2
  (ECDHE + AES-GCM) is a stretch item for older servers.
- **Fonts: a TrueType rasterizer, not more bitmap fonts.** Web pages need
  several sizes, bold, italic and monospace. A `glyf`-outline rasterizer
  with antialiasing and a glyph cache is a few hundred lines of Swift.
  Bundle one free family (DejaVu Sans, Serif and Sans Mono: Bitstream
  Vera license, wide Unicode coverage) in rootfs. The console keeps
  Spleen.
- **Memory.** QEMU goes from 256 MiB to 1 GiB in Part 8 (page images,
  glyph caches and DOMs add up). Reasonable sites should still load at
  512 MiB.
- **A browser crash is a process exit.** The window closes, and the
  terminal that launched it, or the taskbar, reports why. The kernel
  never panics on bad input from the network.

---

# Part 6: User space

Goal: programs in /bin are ELF files that run in ring 3 with their own
address space. A crashing or spinning program is killed or preempted while
the desktop keeps running. Programs can read and write files, print to the
terminal that started them, and open their own windows.

## Phase 6A: page tables (done)

**6A1. `AddressSpace`** (`vmm.swift`). Owns a PML4 frame and the page
table frames under slots 1–254. `map(virt, phys, count, flags)`,
`unmap`, `translate(virt) -> (phys, flags)?`, `protect`, and `deinit`,
which frees the tables and any frames marked as owned. Flags are
`.write`, `.user`, `.noExec`, `.uncached`. Page table frames come from
pmm and are zeroed through the identity map. `AddressSpace.kernel` wraps
the boot PML4.

**6A2. Kernel-half setup at boot.** Preallocate PDPTs for every empty
slot in 256–511 (see the design decisions). Check NXE, enable SMEP/SMAP
if present (CR4), and add `stac`/`clac` to bridge.h.

**6A3. `mapMMIO(phys, size) -> UnsafeMutableRawPointer`** for the
kernel: maps uncached into a reserved upper-half window (Limine's HHDM
may not cover MMIO). Part 7's MSI-X needs it, and so will any future
AHCI/NVMe/xHCI driver.

**6A4. Guard pages for kernel task stacks** (cheap now): leave the page
below each new task stack unmapped in the identity map, so an overflow
faults instead of corrupting the heap. Keep the canaries.

**Selftests:** map/translate/unmap round trips, flags, a fresh address
space switched into and out of (CR3) with a test page visible only
there, deinit returns every frame (pmm count back to baseline), and an
MMIO map of the framebuffer compared through both mappings.

**Done when:** the kernel runs unchanged on its own boot PML4, and an
`AddressSpace` can be created, entered, left and freed with no leaks.

**As built** (vmm.swift, vmm_selftest.swift):
- `PageFlags` are the PTE bits themselves (`.write`, `.user`, `.noExec`,
  `.uncached` = PCD|PWT) plus software bit 9, `.owned`. `AddressSpace()`
  copies PML4 slots 0 and 255–511 from the boot PML4; `AddressSpace.kernel`
  wraps it (`kernelCR3`). `write(virt, bytes)` fills pages of a space that
  isn't loaded, through the identity map (the ELF loader uses it).
- `vmmInit()` (kernel.swift, after the heap) preallocates PDPTs for every
  empty slot 256–511 (254 frames), and `cpuProtectionInit()` (every CPU)
  checks NXE and sets SMEP/SMAP from CPUID. `userAccessBegin/End` wrap
  stac/clac.
- `mapMMIO` maps into PML4 slot 384 (0xffff_c000_0000_0000), with an
  unmapped page after each mapping.
- Guard pages: `spawn` allocates one extra frame below each stack and
  clears its present bit in the identity map (`setGuardPage`), splitting
  Limine's huge pages as needed. **Decision:** a split costs a page-table
  frame that is never returned (`splitPages` counts them), so the existing
  task/terminal leak checks allow exactly that many frames. The HHDM shares
  the tables, so the guard is absent there too.
- TLB: a user space is live on one CPU at a time (switchedIn reloads CR3
  for every task, the kernel's for kernel tasks), so only local invlpg is
  needed. Kernel-half changes are new mappings or present → absent.

## Phase 6B: ring 3 and syscalls (done)

**6B1. Entry stubs** (cpu.S, kept tiny). The `syscall` entry: swapgs,
save the user rsp in per-CPU scratch, load the kernel stack from per-CPU,
build a `UserContext` frame, call `@_cdecl("syscall_dispatch")`, then
return through sysret (or iretq, for a non-canonical rip). IDT stubs
swapgs when the saved CS is ring 3. `enterUser(context)` does the first
`iretq` into a new process.

**6B2. MSRs** per CPU in `gdtInit(cpu:)`: EFER.SCE, STAR, LSTAR, FMASK,
KERNEL_GS_BASE. Switching to a user task sets TSS rsp0 and CR3.

**6B3. Dispatch** (`syscall.swift`): a switch on the number. Just enough
for now: `exit(code)`, `write_debug(ptr, len)` (to serial), `yield`.
`copyIn`/`copyOut` reject any range outside slots 1–254 or not mapped
with U (and W, for copyOut), giving `-EFAULT`.

**6B4. User faults.** A #PF, #GP, #UD, #DE or #BP from ring 3 kills the
task with a one-line report (`pid 7 (crash): page fault at
0x100_0000_1234, rip 0x100_0000_0042`) instead of panicking. A fault in
ring 0 still panics, as now.

**Selftests**, using a few bytes of hand-assembled code copied into a
fresh address space (no ELF yet): `exit(42)` returns 42 to the kernel;
`write_debug` prints; reading kernel memory, executing a data page,
`hlt`, `cli` and `in`/`out` are all killed with the right report; a busy
loop sees timer IRQs come and go (swapgs balanced); and running the same
blob on every CPU.

**Done when:** a user blob runs, makes syscalls, and exits or is killed
on every CPU, with the desktop unaffected.

**As built** (cpu.S, syscall.swift, user_selftest.swift):
- PerCPU words 2–4 (offsets 16, 24, 32, checked by `perCPUOffsetsOK`) are
  the syscall stub's user-rsp scratch, the kernel stack for syscalls, and
  the address of the TSS rsp0 field. `syscallInit(cpu:)` runs at the end
  of `gdtInit`.
- **Decision: leaving ring 3 unwinds instead of abandoning the stack.**
  `user_run(rip, rsp, slot)` pushes the callee-saved state, stores that
  stack point in `Task.userEntry` (rspSlot[2]), the per-CPU syscall stack
  and TSS rsp0, and iretqs to ring 3 with clean registers and FPU state.
  When a process exits, faults or is killed, `syscall_dispatch` /
  `interrupt_dispatch` (which now return a UInt64) return that point
  instead of 0, and the stub's `user_leave` makes `user_run` return. Every
  Swift frame therefore returns normally and releases what it holds; a
  process that never comes back leaks nothing.
- Syscall frames are `interrupt_frame`s with vector 0x100. Syscalls run
  with interrupts on. The #BP gate is DPL 3 (else a user int3 is a #GP).
- `copyIn`, `copyOut`, `withUserBuffer` check each page (user, writable for
  copyOut), fault in absent pages of mapped regions first, then stac/clac.
- User faults give `pid 7 (crash): page fault at 0x8, rip
  0x100_0000_0a48` (`groupedHex`). The report goes to the process's output
  (the waiting shell's terminal), or the kernel log if it has none.
- Interrupt stats per CPU: `userInterrupts`, `syscallInterrupts`,
  `syscalls`. Test-only syscall 99 (`testWaitIRQs`) waits in the kernel for
  interrupts, for the nested-IRQ test; APs get them as ping IPIs (they have
  no timer until 6D).
- The watchdog ignores CPUs running a process's thread
  (`PerCPU.processRunning`): ring-3 code is to be preempted (6D), not
  trusted to yield.

## Phase 6C: processes, ELF and libwiffer (done)

**6C1. ELF loader** (`elf.swift`). Static x86-64 `ET_EXEC`. Check the
magic, class, machine and that every PT_LOAD is inside slots 1–254. Map
the segments with their own permissions (W^X: refuse a segment that is
both W and X), zero the .bss, set up the stack (argc, argv, envp, and an
auxv with AT_PAGESZ, AT_PHDR and AT_ENTRY), and enter `e_entry`. The ELF
is read from the VFS, so it can come from rootfs or /disk.

**6C2. `Process`** (`process.swift`). pid, parent, children, state,
exit code. `spawn(path, argv, stdio) -> pid`, `exit`, `wait(pid)`,
`kill(pid)`. The process table is CPU 0 data, reached through `onCPU0`.
An exited process is a zombie until its parent waits, and orphans
reparent to the kernel (pid 0), which reaps them.

**6C3. Memory syscalls:** `map(addr hint, len, prot) -> addr`
(anonymous, zeroed, lazily allocated on first fault), `unmap`,
`protect`. Demand faults on mapped-but-absent pages allocate a frame. A
fault anywhere else kills the process.

**6C4. libwiffer** (`user/libwiffer/`): `_start` (asm: stack to argc and
argv, then `main`), syscall stubs, and the Embedded Swift runtime hooks
(`posix_memalign`, `free`, `putchar`, `arc4random_buf`). The heap is
**heap.swift's size-class allocator compiled a second time**, with its
frame source swapped for `map`. Wrap the syscalls in Swift: `File`,
`print` to fd 1, `Process.args`, `exit`.

**6C5. Build.** build.sh compiles each `user/<prog>/` with libwiffer,
links with `user/user.ld` (base 0x100_0000_0000), and puts the binary in
rootfs `/bin`. The same `-disable-swift-specific-llvm-optzns` flag
applies (see the Array copy-on-write note).

**First programs:** `hello`, `args`, `alloc` (Array, String, Dictionary
and lots of allocation, then a checksum), `crash <kind>`, `spin`.

**Shell:** a command that isn't built in is looked up in `/bin` and
spawned. The shell waits for it. `ps` lists processes, and `kill <pid>`
kills one.

**Done when:** `hello` prints from ring 3, `alloc` does real Swift
allocation, each `crash` kind is reported and the shell carries on, and
pmm/heap usage returns to baseline after 100 spawns.

**As built** (process.swift, elf.swift, process_commands.swift,
abi/syscalls.swift, user/):
- **ABI** (`abi/syscalls.swift`, in the kernel build and every program):
  `SyscallNumber` 0 exit, 1 yield, 2 debugWrite, 3 getpid, 10 map, 11
  unmap, 12 protect, 23 write (fds 1/2 only), 99 testWaitIRQs (selftests).
  Reserved, returning -ENOSYS: 4 sleep, 5 now (6D); 6 spawn, 7 waitpid,
  8 kill, 20–35 files/pipes/wait/consoleMode (6E); 40–43 windows (6F); 50
  sockets (7E); 60 getrandom (8A). Also `Errno`, `MapProt` (W|X refused),
  `AuxKey`, `UserLayout` (image base, mapBase 0x4000_0000_0000, stack top
  0x7f80_0000_0000, 1 MiB stack).
- `Process` (pid, parent pid, child pids, regions, output, waiter, status
  `.exited(n)/.faulted(vector)/.killed`) and its thread, a `.any` Task with
  `task.process` and `task.cr3`. The process table is CPU 0 data. A kernel
  task that spawns and will wait names itself the `waiter` (unparked at
  exit; it reaps with `waitProcess`). New scheduler primitives in task.swift:
  `park()`/`unpark(task)` (a wake flag, so no lost wakeups),
  `spawn(…, setup:)`, a mutable `Task.affinity`, and **`onCPU0 { }`** (pin
  to CPU 0, yield until there, run, restore; a yield by a task that may no
  longer run on its CPU now always leaves it).
- Memory: regions (`MemoryRegion`) are demand-zero; `map` is first-fit from
  mapBase. ELF segments and the top of the stack are mapped eagerly.
- **Decision (6C output):** without fds yet, `write(1|2)` appends to a
  `ProcessOutput` buffer (64 KiB cap, the writer parks when full) that the
  waiting shell copies to its terminal. With no output (a background job)
  it goes to the kernel log. 6E replaces this with `ConsoleFile`.
- libwiffer: `start.S` (`_start`, `wiffer_syscall`, mem*, rdtsc/pause and
  the deliberate faults), `runtime.swift` (Embedded hooks; heap.swift's
  `pmm`/`heapLock`/`puts` shims over map/unmap), `wiffer.swift`
  (`Process.args/pid/exit/yield`, `File.stdout.write`, `Memory.map`,
  `debugPrint`), `libwiffer.h`. Programs have a `main.swift` with top-level
  code (no `-parse-as-library`); `_start` calls its `main`.
- Build: build.sh step 5b. **Decision:** user code is LTO-linked with
  `-mllvm -relocation-model=pic` (a static ET_EXEC, but position-independent
  code: the small code model's 32-bit absolute relocations can't reach
  0x100_0000_0000). `user/<prog>/LIBS` pulls in lib/ sources with
  transitive DEPS. The rootfs is staged in build/rootfs with /bin added.
- Shell: an unknown word runs `/bin/<word>` (or a path with `/`) and waits;
  Ctrl-C or closing the window kills it; a trailing `&` runs it in the
  background. `ps`, `kill <pid>`. Programs: hello, args, alloc, crash
  (null write exec kernel ident ud trap de bp hlt cli io stack exit), spin.
- Known limit until 6D (fixed there): a process spinning in ring 3 on
  CPU 0 couldn't be killed; `kill` reaches other CPUs by IPI.

## Phase 6D: preemption (done)

**6D1. LAPIC timer on every CPU** (x2APIC MSRs, periodic, calibrated
against the PIT at boot), vector 0xEF. CPU 0 keeps the PIT for `ticks`.

**6D2. Preempt ring 3.** When a timer interrupt (PIT on CPU 0, LAPIC on
the APs) lands in ring 3 and the task has used up its slice (2 ticks),
it is marked ready and the CPU switches away. A timer interrupt that
lands in ring 0 never switches. Interrupted user state lives on the
kernel stack, so the normal `context_switch` handles the rest.

**6D3. `sleep(ms)`** and `now()` syscalls, with timed wakeups in the
scheduler (a sorted deadline list checked on each tick). The WM and the
browser need timeouts anyway (6E `wait`).

**Tests:** four `spin` processes on 4 CPUs, and the desktop still
redraws and echoes keys (harness). `spin` on `--smp 1` still lets the
shell run. `sleep 500` takes 500 ms ± a tick. A preempted `alloc` still
gets the right checksum.

**Done when:** no user program can stall the desktop by spinning.

**As built** (preempt.swift, apic.swift, task.swift, user/sleep):
- **Timers.** `apicTimerCalibrate()` (kernelMain, right after the first
  `sti`) counts the BSP's LAPIC timer (divide 16) over 5 PIT ticks and
  leaves it off. Each AP's apMain calls `apicTimerStart()`: periodic,
  vector 0xEF (`Vector.timer`), at the PIT's rate (`cpus` stats:
  `PerCPU.lapicTicks`). **Decision:** CPU 0 runs no LAPIC timer; the PIT
  is its clock *and* its preemption tick (the roadmap's "PIT on CPU 0,
  LAPIC on the APs"), so there's one tick source per CPU. Without
  x2APIC there are no APs, and the PIT alone preempts CPU 0.
- **Preemption.** Every tick bumps `PerCPU.sliceTicks` (reset in
  switchedIn). After the EOI, interrupt_dispatch calls
  `preemptIfSliceUsed()` for a timer vector (32 or 0xEF) that came from
  ring 3: with the slice (`sliceLength` = 2) used up, `sti`,
  `reschedule(.preempt)`, `cli`. **Decision: every switch happens with
  interrupts on**, the preemption one included, so a task switched in from
  the IRQ path never inherits IF=0 (and the preempted task, resumed from
  a normal switch, returns through the stub's `cli; swapgs; iretq`). Ring
  3 holds no kernel lock or state, so the preempt path is task context and
  may allocate. A resumed task may be on another CPU: swapgs balances
  because the user GS is always 0, and switchedIn reloads CR3 / rsp0.
- **Null SS.** An interrupt from ring 3 loads SS with the null selector;
  interrupt_dispatch now reloads the kernel's (`load_ss`, bridge.h) on
  entry from ring 3, else every kernel task switched to from the preempt
  path ran on with SS = 0 (caught by the "CS/SS are kernel selectors"
  selftest).
- `.preempt` is a yield (requeued, `wakeIdleCPU`), except that besides
  tasks homed here it may take one that has waited `stealDelayTicks`
  (`takeLongWaiting`), so a new process can't starve while every CPU runs
  ring-3 code. `PerCPU.preemptions` counts real switches.
- **Timed waits.** `sleepers: DeadlineList<Task>` (sorted, ties FIFO),
  behind schedLock, with `nextSleeperDeadline` as a lock-free fast path.
  CPU 0's IRQ0 runs `expireDeadlines()`: pops expired tasks and
  `unparkLocked`s them. Allocation-free: popping never allocates, and
  `ensureRunQueueRoom()` (in spawn) keeps the run queue's capacity above
  the task count, so enqueue never grows it (a task is queued at most
  once). Expiry and unpark both just unpark under schedLock, so an early
  unpark and the deadline can race from any CPUs: the first wakes the
  task, the second at most leaves a spurious wakeup.
- **API for 6E `wait` and 7E sockets** (deadlines are absolute `ticks`):
  `parkUntil(_ deadline: UInt64) -> Bool` (`@discardableResult`; parks
  until `unpark(task)` or the deadline; true once the deadline passed;
  `.max` = plain park; spurious wakeups possible, so loop on your own
  condition and register as a waiter *before* checking it);
  `sleepUntil(_ deadline: UInt64, interrupted: () -> Bool = { false })
  -> Bool`; `sleepMilliseconds(_ ms: UInt64, interrupted:) -> Bool`;
  `deadlineAfter(ms: UInt64) -> UInt64` (rounded up to a tick). Task 0
  can't block: it gets an immediate return (sleep* busy-wait there).
- Syscalls 4 `sleep(ms)` (0, or -EINTR when killed; 0 ms yields) and 5
  `now()` (ms since boot, 10 ms steps). libwiffer `Time.now`,
  `Time.sleep(ms)`. `/bin/sleep [-v] <ms>` (`-v` prints `slept N ms`).
- Tests: `preemptTests` (deadline list unit tests; timed park timeout,
  early unpark from another CPU, a sleeper per CPU, an unpark/deadline
  race loop; AP LAPIC rate; a spin on CPU 0 beside the selftest task, a
  preempted `alloc`'s checksum, kill of the CPU-0 spin, a spin per CPU
  with a pinned task still running on each, `sleep -v 500` within a
  tick, kill of a sleeper). Harness: N background spins (N = -smp) with
  the shell, `hello` and `ps` still working, then killed; `sleep -v 500`;
  Ctrl-C of a foreground spin; and a desktop session where keys typed on
  the PS/2 keyboard beside N spins echo and are redrawn (OCR). The
  process checks now run with `--smp 1` too.
- Known gaps: the slice is per-CPU ticks, not time used, so a task
  switched in just before a tick gets a short first slice. The MXCSR
  seen by an IRQ handler is the interrupted user's (pre-existing; no
  kernel IRQ code uses floating point). Idle APs now wake 100 times a
  second for their timer (no tickless idle). Kernel code that never
  yields still freezes its CPU, by design.

## Phase 6E: files, stdio and wait (done)

**6E1. File descriptors.** Each process has an fd table of `FileObject`
(a class hierarchy: `VFSFile`, `ConsoleFile`, `PipeEnd`, and later
`Socket` in 7E). `open(path, flags)`, `read`, `write`, `seek`, `close`,
`stat`, `readdir`, `mkdir`, `unlink`, `rename`, `getcwd`, `chdir`, `dup2`.
VFS calls run under `onCPU0`. Paths resolve against the cwd. Mounts
(/disk) work unchanged, since they're already behind `FileSystem`.

**6E2. stdio.** fds 0, 1 and 2 are a `ConsoleFile` bound to the terminal
that spawned the process. Writes post text to the terminal's inbox.
Reads block until the terminal has a line (cooked mode) or a key (raw
mode, `ioctl`-like `console_mode`). Ctrl-C in the terminal kills the
foreground process.

**6E3. Pipes** (`pipe()`), plus `cmd | cmd` in the shell. Small but
useful, and it exercises blocking reads and writes from both sides.

**6E4. `wait(fds, events, timeout) -> ready`**, the one blocking
multiplexer (think `poll`). It covers files that can block (console,
pipes, and later sockets and windows). The browser's event loop is a
single call to it.

**6E5. Move simple commands out.** Port `cat`, `ls`, `wc`, `hexdump`
and `echo` to `/bin` as libwiffer programs (the built-ins stay until
the ports pass the same harness checks, then they're removed). That
proves the file API on real use.

**Done when:** `/bin/cat /disk/README.TXT | /bin/wc` works in a
terminal window, Ctrl-C kills a `spin`, and the shell harness checks
pass with the ported commands.

**As built** (fileobject.swift, sysfile.swift, process_commands.swift,
user/libwiffer/files.swift, user/{cat,ls,wc,hexdump,echo,iotest},
file_selftest.swift):
- **Ground rule: the kernel never dereferences a user pointer outside
  `copyIn`/`copyOut`/`withUserBuffer`, and trusts no syscall value.** Every
  fd, length, count, flag and path is checked (paths: 1...4096 bytes, no
  NUL; wait: at most 64 fds). `read` validates the destination with
  `userRangeReady` before taking data from a pipe, so a bad pointer loses
  nothing. `iotest` (ring 3) covers null, kernel, unmapped, read-only and
  page-straddling pointers and pointer+length overflow.
- **FileObject** (`class`, any CPU unless `needsCPU0`): `tryRead(max) ->
  IOResult`, `tryWrite([UInt8]) -> IOResult` (`.data/.count/.wouldBlock/
  .error(errno)`; empty `.data` is EOF), `ready() -> Int16` (WaitEvent
  readable/writable/hangup), `waits: WaitList` (`add/remove/wake`; call
  `notify()` when readiness may change), `seek`, `stat`, `readdir`,
  `lastClose()`, `needsCPU0`, `consoleChannel`. Methods never block: the
  syscall layer (`blockingIO`, `sysWait`) registers on `waits`, re-checks
  `ready()`, then `park()`s (a kill unparks: -EINTR). Subclasses for 6F
  windows and 7E sockets override these. Reference counting is explicit:
  `FdTable.install/set/close` call `addRef/dropRef`; the last drop runs
  `lastClose` (how a pipe sees its last writer go). The shell holds a count
  on both ends of each pipe until every stage has its fds.
- **Decision (console):** a command line's programs share a
  `ConsoleChannel`; the waiting shell is the pump (`waitProcesses`): it
  drains output to its terminal, feeds keys from its inbox to the channel's
  line discipline and kills the programs on Ctrl-C or window close. (Not a
  post to the terminal's inbox: the shell is already the task that owns the
  terminal.) Cooked mode (default): echo, Backspace, Ctrl-U, one line per
  read, Ctrl-D on an empty line is EOF. `console_mode(fd, ConsoleMode.raw
  [| .passInterrupt])`: keys as bytes (arrows as ESC [ A..D), no echo;
  Ctrl-C still kills unless `passInterrupt`. Background jobs and a channel
  after its command ended log to the kernel log and read EOF.
- **VFSFile** works on a private copy when opened for writing and writes it
  through (`vfs.write`, so /disk too) when its last fd closes; other opens
  see the new bytes then. Known gap: a large file written in pieces is
  rewritten whole at close (FAT write-through is whole-file).
- **Syscalls:** spawn 6 `(path,len,argv blob,len,fds)`, waitpid 7, kill 8
  (children or self), open 20, close 21, read 22, write 23, seek 24, stat
  25, readdir 26 (DirRecord stream), mkdir 27, unlink 28 (file or empty
  dir), rename 29, getcwd 30, chdir 31, dup2 32, pipe 33, wait 34
  `(WaitFD array, count, timeoutMs)`, consoleMode 35, fstat 36.
  `handleSyscall` now takes a fifth argument (r8). `wait` uses 6D's
  `parkUntil`/`deadlineAfter`.
- **Shell:** `a | b | c` runs programs only (a bare name is /bin/name).
  **Resolution order:** built-in commands first (`cat`, `ls`, `echo` stay
  built in: the in-kernel selftests and many serial checks use their exact
  output), then /bin/<word>; a word with `/` always runs the program, so
  `/bin/cat` is the port. The ports (cat, ls, wc, hexdump, echo) pass the
  same harness checks; removing the built-ins was left out of scope.
  `set affinity <cpu>` pins started programs to a CPU.
- **libwiffer:** `File.open/read/readAll/write/writeAll/seek/stat/close/
  dup2/pipe/readDirectory`, `File.stdin`, `FS.list/stat/mkdir/unlink/
  rename/getcwd/chdir`, `wait(&[WaitFD], timeoutMs:)`, `Console.setMode`,
  `Process.spawn/waitpid/kill`, `SysError(errno).message`.
- Known gaps: no redirection (`>`), no fd inheritance flags (spawn
  inherits 0-2 or three chosen fds), no `O_NONBLOCK`, pipes have no
  `SIGPIPE` (-EPIPE only), processes are limited to 256 and 64 children,
  and a program's output to a terminal window is copied by the shell task
  on CPU 0 (a flood is bounded by the channel's 64 KiB).

## Phase 6F: windows for processes

**6F1. Protocol.** `win_create(w, h, title) -> (fd, buffer address)`.
The kernel allocates a contiguous frame run for the pixels and maps it
into the process (RW, NX). The kernel sees it through the identity map.
`win_present(fd, damage rect)` tells the compositor what changed.
Events (key, mouse, resize, focus, close) are read from the window's fd,
so they work with `wait`. `win_resize` replaces the buffer after a
resize event. `win_set_title`. Closing the fd, or exiting, closes the
window.

**6F2. Kernel side.** `final class UserWindow: Window` (CPU 0) blits from
the shared buffer in `draw`, converts damage into compositor damage, and
turns `handle(event)` into posts to the fd. A process that stops reading
events has its queue capped (drop mouse motion first), so it can't grow
kernel memory.

**6F3. libwiffer GUI.** `Surface` (surface.swift, shared like heap.swift)
over the mapped buffer, drawing primitives, PSF text, and a small widget
kit: `Label`, `Button`, `TextField` and `ScrollView`. This is Phase O's
widget kit, done now because the browser needs a text field.

**6F4. Demo apps:** `/bin/clock` (redraws every second through
`wait`'s timeout) and `/bin/sysmon` (frames, heap, tasks, processes,
CPU load). Launch from the shell, and from the taskbar (a launcher
menu).

**Tests:** create, draw, present, then the harness screendumps it; a
drag and a resize; a process killed while its window is focused (the
window disappears, focus moves, and memory returns to baseline); and an
event flood with no reader.

**Done when:** a ring-3 app opens a window, draws, reacts to keys and the
mouse, and its crash or exit closes the window cleanly.

## Phase 6G: docs and cleanup

- Update "Where we are", the ground rules (new: the kernel never
  dereferences a user pointer outside `copyIn`/`copyOut`; nothing in the
  kernel trusts a value from a syscall), and the memory notes.
- Stretch: move the editor to user space (`/bin/edit`) as the proof that
  apps don't need to live in the kernel. Terminals and the shell can
  follow later.

---

# Part 7: Networking

Goal: `ping 10.0.2.2`, `host example.com` and `fetch
http://example.com/` work from a terminal. User programs get TCP and
UDP sockets.

## Phase 7A: virtio-net (done)

**7A1. `NetDevice`** (`net_device.swift`): name, MAC, MTU, `send(Packet)`,
an rx callback, and counters. Subclasses: `Loopback`, and `LinkPair` for
tests (loss, reorder, duplication, delay in ticks, all seeded and
deterministic).

**7A2. `VirtioNet`** (`virtio_net.swift`): the legacy sequence, as in
virtio-blk, with queue 0 (rx) and queue 1 (tx), features MAC and
STATUS, and the 10-byte `virtio_net_hdr` (no offloads). Rx gets 256
preposted 2 KiB buffers from one contiguous frame run, refilled as they
are consumed. Tx gets a ring of bounce buffers. Polled from the main
loop. Named eth0.

**7A3. run.sh and harness.** Attach virtio-net with SLIRP by default.
`--nonet` leaves it off, and `--pcap` dumps traffic. A harness helper
starts host servers (Python `http.server` and a TCP echo server) on
ephemeral ports and passes the ports to the session.

**Shell:** `ifconfig` (MAC, IP, counters) and `lspci` showing 1af4:1000.

**Done when:** eth0 sends a raw broadcast frame and receives frames
(SLIRP answers ARP for 10.0.2.2) under BIOS and UEFI.

## Phase 7B: Ethernet, ARP, IPv4, ICMP (done)

- Ethernet II framing. ARP requests, replies and a cache with timeouts.
  Packets waiting on ARP are queued (bounded).
- IPv4: header checksum, one interface, a default route, and TTL.
  Fragment reassembly (with a timeout and a memory cap), and we never
  fragment what we send.
- ICMP: answer echo requests, and send echo requests for `ping`. Report
  "destination unreachable" to the socket that caused it (used by 7D).
- `netd` task on CPU 0: drains rx, runs timers, and owns all stack
  state.

**Tests:** `LinkPair` with two stacks pinging each other, ARP
expiry, reassembly in random order, and bad checksums dropped and
counted. Harness: `ping -c 3 10.0.2.2`. (SLIRP answers ICMP echo for the
gateway. Pinging outside hosts may not work, depending on the host OS's
ICMP permissions, so don't test it.)

## Phase 7C: UDP, DHCP, DNS (done)

- UDP with ports, checksums and a per-port receive queue.
- DHCP client (DISCOVER, OFFER, REQUEST, ACK) at boot, with lease
  renewal. A static fallback config if no offer arrives in 5 s.
- DNS resolver: A queries, following CNAMEs, retries with a timeout, a
  cache that honors TTLs, and name compression on parse. Treat every
  reply as hostile: bounds-check every offset and limit compression
  loops.
- Shell: `host <name>`, and `ifconfig` shows the lease.

**Tests:** DHCP and DNS against canned packets in the selftest, plus
fuzzed (truncated, looping, oversize) DNS replies that must fail
cleanly. Harness: boot gets 10.0.2.15, and `host` resolves a name.
SLIRP's DNS forwards to the host's resolver, so the harness test needs a
local fake instead (serve a tiny DNS responder on the host, and use
`-netdev user,dns=...` or `guestfwd` to point at it). Resolving real
names is a manual check.

### Notes from 7A–7C (as built)

Files: `net_packet.swift` (Packet, checksums, `NetRNG`), `net_device.swift`
(NetDevice, Loopback, LinkPair/LinkEnd), `virtio_net.swift`,
`net_stack.swift` (Ethernet, ARP, IPv4, reassembly, ICMP, timers, hooks),
`net_udp.swift`, `net_dhcp.swift`, `net_dns.swift`, `net_commands.swift`
(`netInit`, `netd`, `netBlock`, ifconfig/arp/ping/host), `net_selftest.swift`
(`NetRig`, `NetWire`, the tests).

- **Parsing.** `lib/bytes/reader.swift` (`ByteReader`) is compiled into the
  kernel by adding it to build.sh's swiftc inputs (documented there); it is
  the only lib/ file in the kernel so far. Packet accessors return nil
  rather than trap.
- **netd.** One `NetStack` on eth0, owned by the CPU-0 task `netd`, which
  sleeps in `waitEvent()`. `pollEvents` calls `netPollHook()`, which posts
  netd a `.message` when `stack.needsPoll(ticks)` (NIC frames, a due timer,
  local packets). 7F's MSI-X handler should post the same message. Shell
  commands call into the stack directly (cooperative CPU-0 tasks, so never
  concurrently with netd) and wait with
  `netBlock(timeout:ticks) { condition }`, which sleeps the task until netd
  has run again, a deadline passes, or Ctrl-C.
- **Time is ticks (100 Hz).** `stack.now` is set by `poll(now:)`; selftests
  drive virtual time, so tests are deterministic and fast.
- **Hooks for 7D (TCP)**, all on `NetStack` (net_stack.swift header comment):
  - `registerProtocol(6) { (IPv4Header, Packet) in ... }`: the packet's
    `start` is the first byte of the TCP segment (IP header just before it in
    `buf`), already trimmed to the IP length and reassembled. The packet is
    borrowed: copy what you keep (`p.bytes()`). `h.src`, `h.dst`, `h.ttl`,
    `h.broadcast` are in the header. With no handler the stack sends ICMP
    protocol unreachable.
  - `sendIP(proto: 6, dst:, payload, src:, ttl:)`: `payload` is a
    `Packet.make()` with the segment appended; headers go into the headroom
    (128 bytes). The stack takes ownership, resolves ARP, queues (max 4 per
    address). It refuses payloads over `mtu - 20` (never fragments), so MSS =
    `dev.mtu - 40`. Pseudo-header sum: `pseudoHeaderSum(src:dst:proto:length:)`
    plus `csumAdd`/`csumFold`.
  - `setErrorHandler(proto: 6) { ICMPError in ... }`: destination
    unreachable / time exceeded for our datagrams, with `code`, `mtu`
    (fragmentation needed), the quoted `originalSrc/Dst`, ports and the TCP
    `seq` from the first 8 quoted bytes. Only quotes from our own address are
    delivered.
  - Timers: `let id = stack.schedule(after: ticks) { ... }`, `cancel(id)`,
    `nextDeadline`. They run inside `poll` (netd). Reschedule from the closure
    for repeating work. Resolution is one tick, so RTO values are multiples of
    10 ms; keep a closure's work short (it blocks netd).
  - Randomness: `netRandom()` (xorshift seeded from the TSC) is fine for
    ports; mix RDRAND into initial sequence numbers yourself.
  - Tests: `NetRig` (stacks `a` = 10.1.0.1 and `b` = 10.1.0.2 on a
    `LinkPair`; `rig.pair.lossPct/reorderPct/dupPct/delay`, `rig.step()`,
    `rig.run(n)`, `rig.run(until:limit:)`) and `NetWire` (one stack fed
    hand-made frames). Time starts at tick 1000.
- **ARP.** Cache of 32 entries, 60 s TTL (`arpTTL`), 3 requests 1 s apart,
  wait queue of 4. Replies are learned only for addresses we asked about;
  requests addressed to us are learned. Own address and 127/8 are delivered
  locally without touching the wire.
- **IPv4.** Fragments are reassembled (8 datagrams, 256 KiB total, 30 s,
  duplicates tolerated, overlaps drop the datagram, ICMP time-exceeded if the
  first fragment arrived). Reassembled datagrams are bigger than a pooled
  `Packet` (2 KiB), so they arrive in an unpooled `Packet.large`. DF is set on
  everything we send. ICMP errors are rate limited (10 per second) and never
  sent about errors, broadcasts or non-first fragments.
- **Sockets so far.** `stack.udpBind(port)` gives a `UDPSocket` (queue of
  32, `onReceive` callback, `lastError` from ICMP). 7E wraps this.
- **DHCP** (`DHCPClient`, started by `netInit`): fallback to the static
  10.0.2.15/24 after 5 s, discovery continues and a later ACK replaces it.
  `ifconfig` says `dhcp: lease from ...` or `no offer, static fallback`.
- **DNS** (`DNSResolver`, `stack.resolver`): `start(name, server:port:)`
  returns a `DNSQuery` that netd finishes; `host` and `ping` wait on it with
  `netBlock`. 2 s per attempt, 3 attempts, CNAME chains up to 8, cache of 32
  names honouring TTLs (capped at a day). No TCP fallback for truncated
  replies.
- **Harness DNS.** `host <name> <ip[:port]>` queries a chosen server, so the
  harness runs a Python UDP responder on the host and the guest reaches it at
  10.0.2.2:<port> (SLIRP maps the gateway address to the host). That also
  serves hostile replies (self-referencing pointer, truncation, oversize
  rdlength). SLIRP's `guestfwd` is TCP only, which is why it isn't used.
  Real names (`host example.com`) work against SLIRP's 10.0.2.3 and are a
  manual check.
- **run.sh / harness.** SLIRP NIC by default, `--nonet` (also
  `WIFFER_NONET=1` for the harness), `--pcap` (build/net.pcap). Every
  harness `Session` gets the NIC (`Session(net=False)` opts out).
- **Deviations.** The 7A3 harness helper that starts Python HTTP and echo
  servers is left to 7D (nothing needs it yet); only the DNS responder exists.
  `Loopback` is a device only: sends to our own address are short-circuited
  inside the stack. `ping` prints `time=<10 ms` below one tick. The shell
  command table has four new names (`ifconfig`, `arp`, `ping`, `host`), so the
  "h" completion test now lists `host`.

## Phase 7D: TCP (done)

This is the largest phase in Part 7. It follows RFC 9293.

- **State machine:** all eleven states, including simultaneous open and
  close, and RST handling (RFC 5961's checks against blind resets).
- **Sending:** a send buffer, MSS from the SYN option, Nagle (on by
  default, with an option to turn it off), and retransmission with
  RFC 6298's RTO (Karn's rule, exponential backoff). Fast retransmit
  on three duplicate ACKs, plus slow start and congestion avoidance
  (RFC 5681). No SACK at first.
- **Receiving:** an out-of-order queue, the advertised window, window
  scaling (RFC 7323, needed for speed), delayed ACKs, and zero-window
  probes.
- **Lifecycle:** TIME_WAIT (short, 2 × 10 s MSL is fine), keepalive off,
  random initial sequence numbers (RDRAND, falling back to RDTSC
  mixing), and ephemeral ports.
- **Kernel API** used by 7E and kernel tests: `TCPConnection` with
  `connect`, `listen`, `accept`, `send`, `receive`, `close` and `abort`,
  plus readiness callbacks.

**Tests:** over `LinkPair`, transfer 1 MiB in both directions at 0%,
5% and 20% loss, with reordering and duplication, checking a hash of
the data (FNV-1a is enough here). Also handshake races, RST in
every state, and a peer that stops reading (zero window, then
recovery). Harness: download 1 MiB from the host Python server and
compare hashes, and `listen` through `hostfwd` with the host connecting
in.

**Done when:** the lossy-link tests pass deterministically, and a 1 MiB
download over SLIRP is correct.

### Notes from 7D (as built)

Files: `net_tcp.swift` (`TCPLayer`: table, listeners, demux, one stack
timer for all deadlines, ISNs, ports, resets, ICMP errors, segment parsing),
`net_tcp_conn.swift` (`TCPConnection`: state machine, buffers, output,
retransmission, congestion control), `net_tcp_commands.swift` (`tcpget`,
`tcplisten`, `netstat`), `net_tcp_selftest.swift`. `NetStack` gained
`var tcp: TCPLayer!` (created in its init, registers protocol 6 and the
ICMP error handler). bridge.h gained `rdrand64`.

**Kernel API for 7E** (all on CPU 0, like the rest of the stack):

- `TCPConnection.connect(stack, to: IPv4Addr, port: UInt16, localPort: UInt16 = 0, options: TCPOptions = TCPOptions()) -> TCPConnection?`
  (nil: no address yet, no free port, table full; SYN goes out at once)
- `TCPConnection.listen(stack, port:, backlog: Int = 8, options:) -> TCPConnection?`
  (nil: port already listened on), `listener.accept() -> TCPConnection?`
- `send(_ UnsafeRawBufferPointer) -> Int`, `send(_ [UInt8], from:count:) -> Int`:
  bytes queued, 0 when the send buffer is full, -1 when sending is over
  (error, or after shutdown/close). Data may be queued in SYN_SENT.
- `receive(into: UnsafeMutableRawBufferPointer) -> Int`, `receive(max:) -> [UInt8]`:
  0 bytes means nothing yet; check `eof` / `error`.
- `shutdown()` half close (FIN after queued data, keep reading);
  `close()` full close (unread or later-arriving data turns it into a RST,
  RFC 2525; an orphan waits at most 60 s in FIN_WAIT_2); `abort()` RST now.
- Readiness: `readable` (data, EOF, error, or a listener with a queued
  connection), `writable` (send space in ESTABLISHED/CLOSE_WAIT, or an
  error), `isClosed` (CLOSED or TIME_WAIT), `error: TCPError?`
  (`.refused`, `.reset`, `.timedOut`, `.unreachable`, `.aborted`, with
  `.message`), plus `eof`, `connected`, `available`, `sendSpace`, `state`.
  `onEvent: ((TCPConnection) -> Void)?` is a hint that any of those may have
  changed; it is called from netd after segment/timer processing (or at the
  end of an API call), never mid-segment, so it may call the API. netBlock
  waiters are woken after every netd run anyway.
- `TCPOptions`: `recvBuffer` (128 KiB), `sendBuffer` (64 KiB),
  `windowScale` (on), `noDelay` (off); `noDelay` is also a var on the
  connection. Listeners pass their options to accepted connections.

Decisions:

- **Timers.** One stack timer per layer, armed for the earliest of every
  connection's deadlines (RTO, persist, delayed ACK, TIME_WAIT/FIN_WAIT_2
  linger); it scans the table when it fires. Initial RTO 1 s, min 200 ms
  (Linux's, not RFC 6298's 1 s), max 60 s, 12 retries (5 for SYNs), delayed
  ACK 40 ms or every second full segment.
- **Retransmission** is go-back-N from sndUna after an RTO (cwnd = 1 MSS),
  fast retransmit plus NewReno partial-ACK recovery after three duplicate
  ACKs. Pure ACKs and RSTs are numbered `sndMax` (BSD): with `sndNxt`
  after a rewind, two rewound ends dropped each other's ACKs as
  unacceptable and deadlocked at 20% loss.
- **Zero window:** the persist probe is a byte-less segment at sndUna-1
  (Linux), which any receiver answers with its window; backoff from
  max(RTO, 500 ms) to 60 s, never giving up. An RTO with a zero window
  switches to probing instead of counting a retry.
- **RST in TIME_WAIT is ignored** (RFC 1337), not RFC 9293's close: our
  own duplicate ACK of the peer's FIN reached its listener and drew a
  RST that killed TIME_WAIT early. A retransmitted FIN in TIME_WAIT is
  ACKed and restarts the 2 × 10 s.
- **RFC 5961:** exact-sequence RSTs only; in-window RSTs, SYNs on a
  synchronized connection and too-old ACKs get a challenge ACK (10 per
  second per layer); ACKs above sndMax are answered and dropped.
- **Memory:** 64 connections per stack, backlog ≤ 64, buffers allocated on
  ESTABLISHED (a SYN flood costs a small object per backlog slot), the
  out-of-order queue capped at 64 segments and the receive buffer's size.
- **ISNs:** RFC 6528, a keyed hash (two RDRAND words mixed with the TSC
  at layer creation, TSC/xorshift without RDRAND) of the 4-tuple plus
  TSC/4096. Tests set `tcp.rng` (seeded ISNs and ports) or `tcp.nextISN`.
- `csumAdd` and `Packet.append` were rewritten with unsafe buffer copies
  (TCP checksums every segment twice).

Measured (Apple-silicon host, TCG, `-smp 4`): over LinkPair (1-tick delay),
1 MiB each way at the same time on one connection: clean 42 virtual ticks,
50-110 ms real; 5% loss + 5% reorder + 2% dup 1591 ticks, 50-140 ms; 20% loss +
10% reorder + 5% dup 9421 ticks, 70-170 ms (ranges: BIOS/UEFI runs on a loaded host). The whole TCP selftest adds
about a second. `tcpTests` is `@inline(never)` and yields between groups: inlined into runSelfTests it made the later watchdog check flaky. SLIRP: `tcpget` of 1 MiB from the host's Python
`http.server` took 40-90 ms across runs (11-25 MB/s, polled NIC, before MSI-X).

Tests: selftest (`tcp: ...`, 60 checks) covers the bulk transfers with
FNV-1a hashes and sequence-number wraparound; simultaneous open and close;
RST in every state (SYN_SENT, both kinds of SYN_RECEIVED, ESTABLISHED,
FIN_WAIT_1/2, CLOSE_WAIT, CLOSING, LAST_ACK, TIME_WAIT, LISTEN) with the
blind-reset checks; backlog and table limits; window scaling on/off;
half close; TIME_WAIT length; Nagle, delayed ACKs, noDelay; zero window
with probes and a lost window update; closed port (RST → refused),
retransmission and SYN timeouts, ICMP unreachable; 3000 hostile segments.
Harness: `tcpget 10.0.2.2 <port> /data` (1 MiB, hash compared), a 404,
a closed host port refused, and `tcplisten 7777` reached from the host
through `hostfwd=tcp:127.0.0.1:<free port>-:7777` (main session only),
echoing 256 KiB.

Known gaps: no SACK, timestamps or keepalive; no RFC 6191 timestamp check
for TIME_WAIT reuse (a SYN above rcvNxt is accepted); urgent data is
treated as normal data; data in a SYN is ignored (the peer resends); no
receive-side PMTU probing (fragmentation-needed only lowers the MSS);
`netstat` shows counters, not per-connection timers; ICMP soft errors are
recorded (`softError`) but not reported to readers.

## Phase 7E: sockets for user space

Needs 6E (fds and `wait`) and 7D.

- `socket(kind)` where kind is `.tcp` or `.udp`. `connect`, `bind`,
  `listen`, `accept`, `send`, `recv`, `sendto`, `recvfrom`, `shutdown`,
  `close`. A socket is a `FileObject`, so `read`, `write` and `wait`
  work on it too. Non-blocking mode for the browser.
- `resolve(name) -> [IPv4]`: uses the kernel resolver, so processes
  share its cache.
- Every call hops to CPU 0 (the stack lives there). Data is copied
  between the user buffer and the socket buffer in the syscall.
- Limits: sockets per process, and buffer sizes. Everything is freed when
  a process dies with open sockets.

## Phase 7F: tools and interrupts

- **MSI-X for virtio-net** (needs 6A's `mapMMIO`): one vector for rx and
  tx, aimed at CPU 0's LAPIC. The handler only sets a flag and posts to
  `netd`. Keep the polling path as the fallback. Note that legacy device
  config moves from 0x14 to 0x18 when MSI-X is on.
- **User programs:** `/bin/fetch <url>` (plain HTTP GET to stdout or a
  file), `/bin/nc` (connect or listen, stdin to socket and socket to
  stdout), `/bin/ping` and `/bin/host` (move them out of the shell).
- **Throughput check:** a 10 MiB download through SLIRP with MSI-X at a
  few MB/s or better (record what you get in the roadmap).

**Done when:** `fetch http://info.cern.ch/` prints the first web page
from a real server (a manual check), and the harness does the same
against its local server.

---

# Part 8: Web browser

Goal: `/bin/browse` opens a window with an address bar. It loads HTTP
and HTTPS pages with images and CSS, scrolls, follows links, goes back
and forward, and submits simple forms. The target sites at the end of
this part render readably.

8A–8G are libraries in `lib/`, built for the host test runner and for
user space (see the design decisions). They can start before Parts 6 and
7 are done.

## Phase 8A: crypto and TLS 1.3 (`lib/crypto`, `lib/tls`)

- **Port or write.** First survey pure-Swift crypto and TLS libraries
  against the Embedded Swift constraints (see the design decisions).
  Record the choice here. Each primitive can be decided separately: for
  example, port the symmetric ciphers and write X25519, ECDSA and TLS
  ourselves.

  **Decision: write every primitive ourselves** (no ported code in
  `lib/crypto`). Survey:
  - *CryptoSwift* (hashes, HMAC, HKDF, AES-GCM, ChaCha20-Poly1305): pure
    Swift, but built around untyped `throws` and protocol existentials
    (`Cipher`, `BlockMode`, `Padding` used as `any`), `Data`/Foundation
    extensions, and `Array` extension sugar throughout. Embedded needs
    typed throws and no `any`, so nearly every file would be rewritten.
    It has no elliptic curves or RSA verify.
  - *swift-ssl* / 1amageek's *swift-crypto* fork: new, single-maintainer
    pure-Swift stacks that claim Embedded support (X25519, P-256). Too young
    to trust over our own vector-tested code, CryptoKit-shaped APIs that
    clash with our one-module naming rule, and auditing an unknown
    codebase costs about as much as writing the primitives.
  - *BigInt* (attaswift), *SwiftECC*, *BlueECC*: generic-protocol-heavy
    bignums and Foundation, or wrappers around OpenSSL/Security.framework.
  - *swift-crypto* (Apple), *swift-nio-ssl*: BoringSSL. Out.

  Per primitive: SHA-2, HMAC, HKDF, ChaCha20, Poly1305 (26-bit limbs),
  X25519 (51-bit limbs, UInt128 products) and the DRBG are small enough
  that writing them against the RFCs was quicker than adapting anything.
  AES is a T-table implementation (written; not constant-time against
  cache timing; AES-NI later). GHASH uses BearSSL's masked-multiply
  ("holes") carry-less multiplication idea, independently implemented.
  ECDSA uses one generic Montgomery engine (`CryptoMontgomery`, CIOS
  over 64-bit limbs) shared with RSA, and the complete a = -3 addition
  formulas of Renes–Costello–Batina, so there is no special-case code.

- **Primitives**, each checked against official test vectors: SHA-256,
  SHA-384, HMAC, HKDF, AES-128-GCM and AES-256-GCM (software AES; AES-NI
  as a later speedup), ChaCha20-Poly1305, X25519, ECDSA P-256 and P-384
  verify, RSA PKCS#1 v1.5 and PSS verify (a small bignum with Montgomery
  multiplication, up to 4096 bits).

  **Done** (`lib/crypto`: `sha2.swift`, `hmac.swift`, `aes.swift`,
  `chacha.swift`, `x25519.swift`, `bigint.swift`, `ecdsa.swift`,
  `rsa.swift`, `drbg.swift`; each file starts with its API). Also SHA-512,
  AES-192, P-256/P-384 ECDH (for the HelloRetryRequest key share),
  TLS 1.3 `HKDF.expandLabel` / `deriveSecret`, and `ChaChaDRBG`, the
  fast-key-erasure generator the kernel's `getrandom` will wrap.
  `./run.sh --hosttest crypto` checks FIPS 180-4, FIPS 197, RFC 4231,
  RFC 5869, the RFC 8448 key schedule, the GCM spec test cases, RFC 8439,
  RFC 7748 (including 1000 iterations), RFC 6979 and RFC 5903 vectors,
  plus fixtures from Python `cryptography` (`lib/crypto/fixtures/gen_*.py`):
  every SHA-2 length to 260, AEAD lengths across block boundaries,
  ECDSA/ECDH on both curves (including the degenerate keys G, 2G, -G),
  and RSA 1024–4096 PKCS#1 v1.5 and PSS (salt 0, 20 and hash length,
  emBits a multiple of 8). Negative tests: every bit flip of AEAD
  output, tampered signatures and digests, r/s out of range, off-curve,
  compressed and out-of-range points, small-order X25519 points, strict
  DER. The verify entry points are fuzzed. Host -Osize on an M-series
  Mac: AES-128-GCM ~200 MB/s, ChaCha20-Poly1305 ~320 MB/s, SHA-256
  ~320 MB/s, X25519 ~42 µs, P-256 verify ~1.7 ms, RSA-2048 verify ~50 µs.
  Gaps: AES is not cache-timing safe, P-256/P-384 field arithmetic
  allocates per operation (fine for a handshake, slow for anything bulk),
  no compressed points, no SHA-1 (old chains), no RSA signing or
  decryption.
- **Randomness:** a `getrandom` syscall backed by a kernel ChaCha20 DRBG,
  seeded from RDSEED/RDRAND, plus RDTSC jitter and interrupt timing as
  extra input. (The DRBG is `ChaChaDRBG` in `lib/crypto`; the syscall
  and seeding are still to do.)
- **ASN.1 DER and X.509:** parse certificates, check the chain to a
  bundled root store (Mozilla's, as `/etc/roots.der` in rootfs), validity
  dates from the RTC, the hostname against SAN (with wildcards), basic
  constraints and key usage. Treat every byte as hostile.

  **Done** (`lib/x509`: `asn1.swift`, `certificate.swift`,
  `validate.swift`). Two libs, not one: `lib/x509` (DEPS bytes crypto)
  and `lib/tls` (DEPS x509), so a program that only reads certificates
  doesn't carry the TLS state machine. `ASN1Reader` is strict DER
  (definite, minimal lengths; minimal INTEGERs and OID arcs; BOOLEAN
  00/ff; no unused-bit garbage; UTCTime/GeneralizedTime with seconds and
  `Z` only; nesting depth 24). `X509Certificate(der:)` keeps the TBS
  bytes, raw and printable DNs, validity as Unix seconds, RSA / P-256 /
  P-384 (and Ed25519, parse only) keys, sha256/384/512WithRSA,
  RSASSA-PSS (hash, MGF1, salt parameters) and ecdsa-with-SHA256/384/512
  signatures, basicConstraints, keyUsage, extKeyUsage, SAN dNSName and
  iPAddress, AKI/SKI and dNSName/iPAddress name constraints; SHA-1, MD5
  and P-521 parse as `.unsupported` so old anchors still load.
  `X509Validator.validate(chain:hostname:now:roots:)` builds a path
  through the server's certificates in any order (extras and duplicates
  ignored, alternatives tried for cross-signs, at most 8 deep and 24
  signature checks) to an `X509TrustStore`, and checks every signature,
  every certificate's dates against the caller's `now`, cA and
  keyCertSign on issuers (v1 anchors without extensions accepted),
  pathLenConstraint, EKU serverAuth (leaf and intermediates, when
  present), digitalSignature on the leaf, name constraints, unknown
  critical extensions, and the hostname: SAN only, `*` only as the whole
  left-most label matching one label, IP literals against iPAddress, and
  **no CN fallback** (like Chrome and Firefox). Errors are `X509Error`
  (`expired`, `notYetValid`, `hostnameMismatch`, `untrustedRoot`,
  `badSignature`, `notCA`, `keyUsage`, `extendedKeyUsage`, `pathLength`,
  `nameConstraints`, `unknownCriticalExtension`, `malformed(why)`,
  `unsupportedAlgorithm(what)`, ...) with readable descriptions. No
  revocation, policies or SCTs.

  Root store: `rootfs/etc/roots.der` is the DER certificates of curl's
  `cacert.pem` (Mozilla NSS data, MPL 2.0; `rootfs/etc/roots.README`
  says so) concatenated, made by `lib/x509/tools/mkroots.py`.
  `X509TrustStore(concatenatedDER:)` loads it: 118 roots (data of
  2026-11-05) parse in about 1 ms with none rejected; keys are RSA 79,
  P-384 35, P-256 3 and P-521 1; 114 self-signatures verify, and 3
  SHA-1-signed roots and the P-521 one are unsupported (the SHA-1 ones
  still work as anchors, since an anchor's own signature is never
  checked; the P-521 root can't anchor anything yet).
- **TLS 1.3 client** (RFC 8446): the cipher suites TLS_AES_128_GCM_SHA256,
  TLS_AES_256_GCM_SHA384 and TLS_CHACHA20_POLY1305_SHA256; X25519 key
  share (and P-256 as a fallback, for HelloRetryRequest); SNI; ALPN
  `http/1.1`; signature algorithms ECDSA and RSA-PSS. No client
  certificates, no 0-RTT, and no resumption at first.

  **Done** (`lib/tls`: `tls.swift` for constants, errors, config and the
  key schedule; `record.swift`; `client.swift`). `TLSClient` is I/O-free:
  `start()`, `feed(bytes)`, `takeOutput()`, `write(data)` (queued until
  connected), `read()`, `close()`, `transportClosed()`, `state`
  (idle/handshaking/connected/closed/failed) and `error` (`TLSError`:
  `peerAlert`, `protocolError(alert, reason)`, `certificate(X509Error)`,
  `truncated`, `closed`). Randomness comes from a caller closure
  `(Int) -> [UInt8]` (getrandom or `ChaChaDRBG`; tests inject the RFC
  8448 values). Trust is `.roots(store)`, `.pinned(leafDER)` or
  `.insecureAcceptAny` (CertificateVerify is still checked). Decisions:
  ChaCha20-Poly1305 first in our preference order (AES is table-based
  software); X25519 is the only first-flight share, and P-256 or P-384
  are sent after a HelloRetryRequest asks (with cookie and message_hash
  transcript); middlebox compatibility mode on (32-byte session id, one
  CCS before the second flight); ClientHellos of 256–511 bytes padded to
  512; rsa_pkcs1 is offered for certificates but refused in
  CertificateVerify. Strict where RFC 8446 says so: unsolicited
  extensions are unsupported_extension, duplicates illegal_parameter,
  key changes must fall on record boundaries, the downgrade sentinel is
  checked, records over 2^14 (+256 encrypted) are record_overflow,
  handshake messages over 64 KiB and more than 16 certificates are
  refused. A CertificateRequest is answered with an empty Certificate.
  NewSessionTicket is ignored; KeyUpdate is handled both ways;
  record_size_limit is honoured when offered; close_notify is answered.
- **Tests:** RFC 8448's recorded handshake replayed byte for byte (with
  its fixed keys and randomness), a host `openssl s_server` or Python
  `ssl` server with a test CA (`tests/certs/`), and bad certificates
  (expired, wrong host, untrusted root, bad signature) that must all be
  refused with a clear error.

  **Done.** `./run.sh --hosttest x509 tls`:
  - RFC 8448 section 3 and section 5 (HelloRetryRequest) replayed byte
    for byte (`lib/tls/fixtures/rfc8448.txt`, extracted from the RFC by
    `gen_rfc8448.py`): every ClientHello record (the second one with its
    P-256 share, cookie and padding), all derived secrets, the server
    flights accepted (RSA-PSS CertificateVerify against the RFC's pinned
    self-signed cert), the client Finished, application data both ways,
    and both close_notify records; also fed whole, in 7-byte pieces and
    byte by byte.
  - Live, against `openssl s_server -www` on 127.0.0.1 with the test PKI
    from `tests/certs/gen.py` (Python `cryptography`; RSA-2048 and
    P-384 roots, P-256 and RSA intermediates, a PSS-signed RSA leaf):
    a full handshake plus `GET /` for each cipher suite with both an
    ECDSA P-256 and an RSA server certificate, HelloRetryRequest to
    P-256 and to P-384, ALPN, the validated three-certificate path, and
    a wrong host name and an expired chain refused over the wire. The
    test prints a note and skips if OpenSSL 3+ isn't on PATH (macOS's
    LibreSSL doesn't count). `hosttest/host.h` gained loopback socket
    and popen helpers for this (host runner only).
  - Bad certificates, each with its error: expired, not yet valid,
    wrong host, wildcard depth, wrong IP, untrusted root (rogue root
    with the real root's name), missing intermediate, bad signature,
    intermediate without CA:true, intermediate without keyCertSign,
    pathLenConstraint, EKU clientAuth only, name constraints; plus
    out-of-order/extra/duplicate chains, IPv4/IPv6 SANs and pinning.
  - Protocol errors: peer alerts, TLS 1.2 servers and the downgrade
    sentinel, unoffered suites/groups/extensions/schemes, tampered
    records (alert sent encrypted), bad Finished and CertificateVerify,
    out-of-order and oversized messages, stray CCS, plaintext
    application data, KeyUpdate in both directions, 2^14 fragmentation.
  - Fuzzing (`t.fuzz`): 10000 certificate/DER mutants and 1500 chain
    mutants; 3000 raw server-byte mutants, 3000 ServerHello mutants and
    4000 mutated *plaintext* server flights re-encrypted with the RFC
    8448 server keys, so EncryptedExtensions/Certificate/
    CertificateVerify/Finished parsing sees them (none accepted).
  - Result: `ok x509: 114 passed, 0 failed`, `ok tls: 130 passed, 0
    failed` with `live s_server: 8/8 handshakes + GET ok`. A manual
    check (not committed) through a localhost relay reached example.com,
    google, cloudflare, github, wikipedia, apple, letsencrypt, amazon,
    news.ycombinator.com, bbc.co.uk, microsoft and swift.org: every
    one handshakes, validates against the Mozilla roots and answers
    HTTP.
  - Gaps: no revocation, no Ed25519/P-521 signatures (no curve code), no
    SHA-1 (so a chain needing a SHA-1 intermediate fails), no P-521 or
    FFDHE groups, no TLS 1.2, no resumption/0-RTT, no client
    certificates, no exporters; the record layer never pads.
- Stretch: TLS 1.2 (ECDHE with AES-GCM or ChaCha20) for older servers,
  and session resumption.

**Done when:** the host test runner completes a handshake with a local
server, and inside Wiffer, `fetch https://example.com/` works (a manual
check).

**Status:** the host half is done (above). Left for Parts 6/7: the
`getrandom` syscall, and `/bin/fetch` driving `TLSClient` over a socket
with `/etc/roots.der` and the RTC time.

## Phase 8B: URLs, HTTP and inflate (`lib/url`, `lib/http`, `lib/inflate`)

**Status: done except inflate** (lib/inflate is being written separately).
`lib/url`, `lib/http` and `lib/text` are in, all with host tests and
fuzzers (`./run.sh --hosttest url http text`).

Decisions and results:
- **lib/url**: full WHATWG basic URL parser (no setters), IPv4 and IPv6
  hosts, opaque hosts, file drive letters, `blob:` origin, form-urlencoded
  encode/decode. Non-ASCII hosts throw `URLError.nonASCIIHost` (no IDNA;
  `xn--` labels pass through unvalidated). Fixture: the complete WPT
  `urltestdata.json` (BSD-3, license in `lib/url/fixtures/`): 891 pass,
  13 skipped (IDNA cases), 0 fail of 904. RFC 3986 section 5.4: 41/41.
- **lib/http** (DEPS url): no I/O, no clock (`now` is Unix seconds).
  `httpBuildRequest`, `HTTPResponseParser` (events: head/body/trailers/
  complete/error, byte-at-a-time safe, limits in `HTTPLimits`),
  `httpRedirectDecision`, `HTTPCookieJar`, `HTTPCache`,
  `HTTPConnectionPool`. 166 host checks plus parser and cookie fuzzing.
  Content-Encoding is a plug point (`HTTPBodyDecoder`, `HTTPBodySink`,
  `httpDecodeBody`); wiring notes at the top of `lib/http/decoder.swift`.
- **lib/text**: functions are prefixed `charset...` (lib/font owns
  `textDecodeUTF8` etc.). UTF-8 (WHATWG replacement semantics),
  windows-1252 (ISO-8859-1 and ASCII labels map to it), UTF-16, label
  lookup, detection order header, BOM, meta prescan (1024 bytes), UTF-8.
  Legacy CJK/other 8-bit labels are recognized as `.unsupported` and
  decoded as windows-1252.
- Known gaps: no IDNA/punycode, no public suffix list (small built-in
  list), no SameSite, no HTTP cache heuristic freshness or Vary
  support, no cookie persistence, no proxy/auth/Expect: continue.

- **URL parsing** per the WHATWG URL standard (the parts that matter):
  schemes, authority, ports, percent-encoding, relative resolution
  against a base (the RFC 3986 and WHATWG test suites are the test
  fixtures), and IDNA left out (ASCII hosts only, with a clear error).
- **HTTP/1.1 client:** request building, response parsing (status,
  headers, Content-Length, chunked, close-delimited), redirects (up to
  10, with method rules), keep-alive with a small per-host pool, and
  `Accept-Encoding: gzip, deflate`. Cookies: a per-session jar
  (Domain, Path, Secure, HttpOnly, Expires and Max-Age). No persistence
  at first. An in-memory cache keyed by URL (respecting `no-store`).
- **Inflate:** DEFLATE, zlib and gzip decoding. PNG needs it too. The
  test fixtures come from host `zlib`/`gzip`.
  **Inflate is done** (`lib/inflate`, with Phase 8G). `Inflater` is the
  streaming API for HTTP bodies: `feed(chunk)` (any chunk size),
  `take()` to drain output, `finish()` at end of input (throws
  `.truncated` if the stream is incomplete), `isDone`; formats `.raw`,
  `.zlib`, `.gzip` (FEXTRA/FNAME/FCOMMENT/FHCRC, CRC-32 and ISIZE,
  multiple members) and `.auto` (sniffs gzip, then zlib, else raw, which
  also covers servers that send raw deflate for `Content-Encoding:
  deflate`). `maxOutput` bounds the decoded size (`.outputLimit`).
  One-shot: `inflateBytes(data, format:, maxOutput:)`. Details are in
  Phase 8G below.
- **Text decoding:** UTF-8 (with replacement characters), Windows-1252
  and ISO-8859-1. Get the charset from the header, then `<meta
  charset>`, defaulting to UTF-8.

## Phase 8C: HTML (`lib/html`)

**Status: done** (`./run.sh --hosttest html`).

- **Tokenizer** following the WHATWG states: data, RCDATA (`title`,
  `textarea`), RAWTEXT (`style`, `xmp`, `iframe`, `noembed`,
  `noframes`), script data with the full escaped/double-escaped
  states, PLAINTEXT, tags, attributes (all quoting styles), comments
  (including bogus), DOCTYPE, CDATA in foreign content, and character
  references with the full 2231-entry named table. The table is
  generated by `lib/html/tools/gen_html_tables.py` from the spec's
  `entities.json` into two ASCII `StaticString`s (sorted records plus
  an offset index, binary search; 35 KB of source, no heap). Numeric
  references use the spec's replacement table. It works on Unicode
  scalars decoded once from UTF-8 (invalid bytes become U+FFFD, CR/LF
  normalized, NUL handled per state).
- **Tree builder:** the full set of insertion modes except template
  ones (initial through after-after-frameset, including text, the table
  modes with foster parenting, select, noscript-in-head), the list of
  active formatting elements with markers and the Noah's Ark clause,
  and the spec's adoption agency algorithm (bounded at 8 outer / 3
  inner iterations, as specified). svg/math are generic namespaced
  elements with the spec's tag/attribute case fixes, integration points
  and breakout rules. Not done: fragment parsing, scripting,
  `<template>` contents (a normal element), `<selectedcontent>`, parse
  errors. The select rules follow the current spec (customizable
  select: `<select>` content is parsed with in-body rules).
- **DOM:** `final class HTMLNode` (document, doctype, element, text,
  comment): `name`, `namespace`, `attributes` (ordered, lowercase),
  `data`/`text`, `parent` (unowned(unsafe); the document owns
  everything), `children`, `index`, sibling/first/last navigation,
  `attribute(_:)`, `id`, `hasClass`, `classNames`, `getElementById`,
  `getElementsByClassName`, `getElementsByTagName`, `firstElement(where:)`,
  `elements(where:)`, `walk`, `textContent`, `documentElement`/`head`/
  `body`, and `teardown()`. Entry points: `htmlParse(bytes or String,
  limits:)` and `htmlTreeDump`.
- **Hostile input:** `HTMLParseLimits` (input bytes 16 MB, nodes
  300 000, depth 512). At the depth cap a new element first closes the
  deepest open one, so the tree is never deeper than the cap; all
  tree walks use explicit stacks. `document.truncated` reports a cut-
  short parse. The fuzzer (3000 mutants) and 100k-deep nesting cases
  run in the host tests.
- **Tests:** html5lib-tests tree-construction fixtures (MIT, license in
  `lib/html/fixtures/`; the files were removed from upstream's master
  when they moved to WPT, so they come from the last commit that had
  them, 9329e64). Pass rate: **1394 of 1509 cases (92.3%)**;
  **1392 of 1398 (99.5%)** without `template.dat`, whose expected
  trees need template contents. 200 fragment and `#script-on` cases
  are skipped. The run fails if the pass count drops below 1394.
  Failures are written to `build/hosttest/html5lib-failures.txt`.
  Remaining failures: template contents (about 110) and
  `<selectedcontent>` (4). The tokenizer tests are not run separately;
  the tree dumps cover tokenization.
- **Speed:** a 783 KB saved Wikipedia article
  (`fixtures/wikipedia-html.html`, 15 000 nodes) parses in about 15 ms
  on the host (~50 MB/s, optimized Embedded build).

## Phase 8D: CSS (`lib/css`)

- **Syntax** (CSS Syntax Level 3): tokenizer, rules, at-rules, and
  declarations, with error recovery that skips what it doesn't
  understand.
- **Selectors:** type, universal, class, id, attribute (`=`, `~=`,
  `^=`, `$=`, `*=`), descendant, child, adjacent and general sibling,
  `:first-child`, `:last-child`, `:nth-child(an+b)`, `:not()` (simple),
  `:link`, `:visited` (always false), `:hover` (tracked by the browser),
  `:root`. Specificity and source order.
- **Cascade:** a user-agent stylesheet (from the HTML spec's
  rendering section), author sheets (`<style>`, `<link
  rel=stylesheet>`, `@import`), `style=""` attributes, `!important`,
  inheritance, `initial`/`inherit`/`unset`, and custom properties with
  `var()` (heavily used now).
- **Values:** lengths (px, em, rem, %, pt, vw, vh), `calc()` (simple),
  colors (named, hex, rgb(), rgba(), hsl()), and the properties layout
  understands (8F). Media queries: `screen`, `min-width`, `max-width`,
  `prefers-color-scheme: light`. Everything else is parsed and ignored.

**Status: done (host-tested, `./run.sh --hosttest css`).** Decisions:

- **Generic over the element, no existentials.** `CSSElement` is a protocol
  (tag, id, classes, attribute, parent, previous/next element sibling, root,
  hover/link/checked/disabled/empty flags, sibling index and count with
  walking defaults); matching and the cascade are generic functions, and the
  DOM conforms in the integration step.
- **Declarations are expanded at parse time** into typed longhands
  (`CSSDeclaration`), so invalid values drop the whole declaration and the
  cascade keeps the earlier one. Declarations containing `var()` stay
  pending and are substituted and expanded per element.
- **Rule index** by the rightmost compound's id, first class or tag, in three
  sets (element, `::before`, `::after`); matching has a step budget.
  `@media` is evaluated when a sheet is added (`CSSStyleResolver.setContext`
  re-evaluates after a resize); `@supports` is evaluated at parse time
  (`display: grid` reports unsupported, so pages use their fallbacks).
- **Computed values:** em/rem/vw/vh/pt/... resolve to px; percentages and
  calc() stay a `CSSLP` (px + pct%, with optional min/max/clamp bounds) or a
  `CSSDimension` (auto/none/keyword/length) for layout to resolve.
  `display: grid` parses as block, `inline-grid` as inline-block.
- **Not done / known gaps:** `:has()`, `:lang()`, `::first-line`-style
  pseudo-elements never match; `@font-face`, `@keyframes`, `@container`
  ignored; `@layer` ordering ignored (contents are plain rules);
  `url()` values are resolved at parse time through an optional closure
  (pending `var()` urls are not); `text-decoration` is not inherited by the
  cascade (layout propagates it); no `counter()`, no `border-radius`,
  `outline`, `box-shadow`, `letter-spacing` or grid properties.

## Phase 8E: fonts and text (`lib/font`) (done)

Pure Swift, host-tested (`./run.sh --hosttest font`, 516 checks).

- **TrueType reader** (`ttfont.swift`, `TTFont`): table directory, `head`,
  `hhea`, `maxp`, `hmtx`, `cmap` (formats 4 and 12; prefers (3,10), then
  Unicode platform 0, then (3,1)), `loca` short/long, `glyf` simple and
  composite (2x2 transforms, point matching, depth 6, 64 components,
  20000 points), `kern` format 0, OS/2 (x-height, cap height), `name`.
  All reads go through bounds checks (`ByteReader` or checked helpers);
  fuzzed. CFF/OTF and collections are rejected (stretch).
- **Rasterizer** (`fontraster.swift`): quadratics flattened to 0.1 px, signed-area
  accumulation (font-rs method), 8-bit coverage with bearings.
  Overlapping contours clamp (approximates nonzero). ~840k glyphs/s at
  16 px on the host, uncached. `GlyphCache` keyed by (font id, size in
  1/8 px, glyph, synthetic style) with a byte cap, cleared when full
  (default 4 MiB). Synthetic bold (horizontal dilation by size/20 and a
  wider advance) and oblique (shear 0.2). `fontBlit` alpha-blends a
  coverage bitmap into an XRGB `UnsafeMutablePointer<UInt32>` or
  `[UInt32]`, clipped, independent of `Surface`.
- **Text** (`textrun.swift`): `TextEngine.shape` gives one glyph per
  scalar with kerning (same face only), fallback down a `FontChain`, a
  tofu box (`fontTofuGlyph`, 0.6 em advance) when no face has the
  character, zero-width controls. `TextRun` has `xs` (pen positions),
  `width`, `breaks`, `nextBreak(after:)` and `fitLine(from:maxWidth:breakWords:)`.
  Line breaking (`textBreakOpportunities`): after spaces and hyphens (not
  before digits), between CJK ideographs, never before closing
  punctuation or after opening, NBSP/word joiner glue, ZWSP, soft
  hyphen, mandatory at newlines.
- **Registry** (`fontregistry.swift`): `FontRegistry.add/face/chain`
  maps family names (Arial, Helvetica, Times, Times New Roman, Georgia,
  Verdana, Courier, Courier New, system-ui, serif, sans-serif,
  monospace, ...) plus weight and style onto faces, with synthetic
  bold/italic flags when the exact face is missing. `fontBundled` lists
  the rootfs files.
- **Bundled** (rootfs `/fonts`, 5.26 MB, with the DejaVu `LICENSE`): DejaVu 2.37
  Sans, Serif, Sans Mono, each regular, bold, oblique/italic, bold
  oblique/italic (12 faces). The ISO boots and passes `--test` with them.
- **Known gaps:** no GSUB/GPOS (kerning is the legacy `kern` table only,
  so DejaVu Sans Mono has none), no complex-script shaping or bidi, no
  ligatures, glyph positions are rounded to whole pixels (no subpixel),
  no hinting, no CFF/WOFF. The taskbar and window titles do not use it yet.

## Phase 8F: layout and paint (`lib/layout`)

**Status: done** (`./run.sh --hosttest layout`, 139 checks; DEPS html css
font image). Decisions and results:

- **API (`LayoutEngine`)**: built from a parsed document and a configured
  `TextEngine` (fonts are loaded by the caller; the library does no I/O).
  `styleSources` lists `<style>` and `<link rel=stylesheet>` in document
  order; inline sheets are parsed at once (`resolveURL` resolves their
  url()s), linked ones are supplied later with `setStyleSheets(slot:_:)`
  (imports first); `addStyleSheet` appends a user sheet. `imageSize`
  (a closure, url as written -> (w, h) or nil) gives intrinsic sizes;
  `imagesChanged()` relayouts without restyling. `setViewport`,
  `setHover(node) -> needsRepaint`, `invalidateStyle`, then `update()`
  does only what is dirty. `paint(into:stride:width:height:scrollX:scrollY:
  images:controlPainter:)` rasterizes the display list into an XRGB buffer
  (images closure returns natural-size `ImageBitmap`s; scaled copies are
  cached); `hitTest(x:y:scrollX:scrollY:)` -> `LayoutHit` (deepest element,
  link + href, control, cursor, title), `linkAt`, `rect(of:)`,
  `fragmentY(_:)`, `formControls` (rects for the browser to draw over and
  route input to; `controlValues`/`controlChecked` override the drawn
  state), `title`, `imageURLs`, `documentWidth/Height`, `canvasColor`,
  `quirksMode`, `dump()`.
- **Styling**: `LayoutElement` wraps `HTMLNode` as a `CSSElement` (hover
  set, cached class lists, sibling index from `HTMLNode.index`). HTML
  presentational hints (bgcolor, text, width/height, align, valign, nowrap,
  cellpadding/cellspacing/border, `<font>`, hspace/vspace, `br clear`, hr)
  are generated as CSS and passed through a new `hints:` parameter of
  `CSSStyleResolver.computeStyle`, which cascades them below every author
  rule (the one change in lib/css). Attribute values are filtered so they
  cannot inject CSS. `<center>`/`align=center` also centers block children
  (the legacy `-webkit-center` behavior). Quirks mode (no/legacy doctype)
  adds the spec's `table { font-size/text-align/...: initial }` rules.
- **Box tree**: one `LayoutBox` class with a kind; anonymous blocks around
  inline runs, block-in-inline turns the inline into a block (simplified),
  anonymous table parts (CSS tables work), blockified flex items,
  `display: contents`, `::before/::after` with string and `attr()` content,
  outside/inside list markers (disc/circle/square as glyphs, decimal, alpha,
  roman, greek; `start`, `value`), replaced elements (img, input, select,
  textarea, iframe/video/canvas/svg as 300x150, meter/progress). Whitespace
  collapses across boxes per `white-space`; text-transform; text is shaped
  once per box tree.
- **Layout**: block widths (auto/fixed/%/min/max/box-sizing/auto margins),
  margin collapsing (siblings, parent/first child via a pre-walk, parent/last
  child, empty blocks), floats with line shortening and clearance, BFC roots
  avoid and contain floats; inline line breaking at break opportunities with
  inline box edges, vertical-align (all keywords and lengths), text-align
  incl. justify, text-indent, line-height struts, atomic inlines; tables
  (grid with colspan/rowspan, auto layout from min/max content with fixed and
  percentage columns and spanning cells, fixed layout, `<col width>`,
  border-spacing, simplified border-collapse that drops shared edges,
  captions, row heights, cell vertical-align incl. baseline); flexbox (row,
  column, wrap, basis/grow/shrink with the freeze loop and min-content
  automatic minimum, justify-content, align-items/self, auto margins, gaps,
  reverse); relative/absolute/fixed positioning (static positions, auto
  margin centering), sticky = relative with zero offset. BFC-root layouts
  are cached per pass (key: widths/forced size), and intrinsic widths are
  cached, so nested shrink-to-fit/flex/table layouts stay linear.
- **Paint**: display list in CSS 2.1 Appendix E order (own background,
  negative z, block backgrounds, floats, inline content, z auto/0, positive
  z), each item with its overflow clip and opacity-multiplied alpha; fixed
  subtrees are viewport-relative. Borders solid/dashed/dotted/double/
  inset/outset approximations, text-decoration lines, background colors and
  images (repeat/repeat-x/-y/no-repeat from the padding-box origin), images,
  default form control appearance (or the browser's painter callback), alt
  text. Root/body background becomes the canvas. Painting skips items
  outside the viewport.
- **Hover**: a hover change only restyles if a :hover compound matches an
  element entering/leaving the chain; paint-only changes are applied in
  place (styles, propagated decorations, display list), layout-affecting
  ones fall back to a full restyle.
- **Limits and recursion**: box depth `LayoutLimits.maxDepth` = 200 (deeper
  elements get no boxes), 400k boxes, 1000 table columns, 20k rows, 1000
  floats per context, font-size 512. All numbers pass through `layoutSan`
  (NaN -> 0, clamp +-1e7). Layout recurses once per box level; the recursive
  frames hold no `CSSComputedStyle` (944 bytes) copies (style work is out of
  line), so all robustness cases (5000-deep divs/spans, 600 nested tables,
  floats, flex, lists) pass with a 256 KB stack on the host. The browser
  should run with at least 512 KB of stack.
- **Tests**: 15 fixture pages (`lib/layout/fixtures/*.html` with `.expected`
  dumps; `WIFFER_LAYOUT_REGEN=1` rewrites them) incl. a saved Hacker News
  front page with its CSS; paint pixel checks (boxes, scrolling, fixed, text
  ink inside its box, clipping, z-order, float over block, opacity, borders,
  dashes, canvas, images, background tiles, visibility, control painter);
  hit tests; API tests (hover in place and fallback, late images, resize with
  media queries, link slots, quirks, hint injection, control state);
  robustness; a 400-mutant pipeline fuzz (parse, layout, paint, hit, hover,
  resize). `WIFFER_LAYOUT_RENDER=page.html[:sheet.css]` paints any saved page
  to `build/hosttest/render.ppm` (DDG lite, text.npr.org, lite.cnn.com,
  Wikipedia and HN all render recognizably).
- **Timings** (host, -Osize, Apple silicon, CPU time, varies 2x with load):
  Wikipedia article (783 KB + 228 KB of its real CSS): style 120-240 ms,
  layout 20-35 ms, display list 3 ms (style+layout 140-290 ms); relayout
  only 11-20 ms; paint about 1 ms per 1024x768 frame; resize 160-250 ms;
  hover over a link 170 ms (in place, but a large subtree). Hacker News:
  5-14 ms. Style time is dominated by lib/css selector matching.
- **Known gaps**: no outlines, border-radius, box-shadow, gradients, masks
  (Wikipedia's mask-image icons paint as dark squares), letter-spacing,
  `order`, align-content, grid (block); block-in-inline is not split; abspos
  inside a positioned inline uses the line's container; sticky does not
  stick; only the viewport scrolls (overflow: auto/scroll clip like hidden);
  border-collapse is a simplification (no conflict resolution); table
  baseline alignment is per row only; percentage heights need a definite
  container; quirks-mode line-height rules are not emulated; text boxes
  carry a full style copy (memory); hover restyle still walks the hovered
  element's parent subtree; `style=""` url()s are not resolved (the browser
  resolves every URL it is given against the base); no bidi/vertical text.


- **Box tree** from the DOM and computed styles: `display` (none, block,
  inline, inline-block, list-item, table parts, flex), anonymous block
  and inline boxes, and `::before`/`::after` with string `content`.
- **Block layout:** width/height (auto and fixed), min/max, margins with
  collapsing, padding, borders, `box-sizing`, and auto horizontal
  margins for centering.
- **Inline layout:** line boxes, baselines, vertical-align (baseline,
  middle, top, bottom, sub, super), text-align (including justify),
  white-space (normal, nowrap, pre, pre-wrap), `<br>`, text-indent,
  line-height, and replaced elements (images, form controls) inline.
- **Floats and clear.** Older sites depend on them.
- **Positioning:** relative, absolute and fixed (fixed relative to the
  viewport), and `z-index` in stacking order. `sticky` acts as
  relative.
- **Tables:** auto layout with column widths from content, colspan and
  rowspan, cell padding, and border-collapse. Many sites (HN included)
  are tables.
- **Flexbox:** single-line and wrapping, direction, justify-content,
  align-items, flex-grow/shrink/basis, gap. Modern sites need it.
  Grid is "After Part 8"; treat it as block for now.
- **Overflow:** visible, hidden and auto/scroll (scrollable boxes are
  a stretch; at first only the viewport scrolls).
- **Paint:** a display list in stacking order (backgrounds,
  borders, text, decorations, images, outlines), clipped and painted
  into a `Surface`. Only the visible part of the page is painted, so
  long pages scroll quickly. Hit testing finds the element under a
  point, for links, hover and forms.
- **Tests:** layout dumps (each box's rect as text) compared to expected
  output for small fixture pages, run on the host. Also some reference
  screenshots compared with screendump in the harness, but those are
  brittle, so keep them few.

## Phase 8G: images (`lib/image`)

**Done** (`lib/inflate`, `lib/image`; `./run.sh --hosttest inflate image`).

- **PNG:** every color type and bit depth, filters, transparency
  (tRNS), and Adam7 interlacing, with inflate from 8B. Checked against
  PngSuite.
- **GIF:** LZW, the first frame only (animation is a stretch).
- **JPEG:** baseline Huffman, 4:2:0/4:2:2/4:4:4 chroma subsampling
  (plus 4:4:0, 4:1:1 and any integral ratio), and then progressive (a
  lot of the web is progressive JPEG).
- **WebP:** lossless and lossy (VP8) are a stretch, but many sites serve
  WebP when the `Accept` header allows it. Don't advertise it, and most
  servers fall back to JPEG/PNG. Skipped.
- Scaling: bilinear, with alpha blending into the page. A decoded-image
  cache with a memory cap. Decode limits (dimensions × 4 bytes under a
  cap), because image headers lie.

**Decisions.**

- **API.** `imageDecode(bytes, maxBytes:)` sniffs the magic bytes
  (`imageSniff`) and calls `PNGDecoder`, `GIFDecoder` or `JPEGDecoder`
  (`.decode(bytes, maxBytes:)`), all `throws(ImageError)`. `maxBytes`
  caps width × height × 4 and is checked from the header before
  anything is allocated (`.tooLarge`); JPEG coefficient memory is also
  held to about 1.5× the cap.
- **`ImageBitmap`:** `width`, `height`, `pixels: [UInt32]` as
  `0xAARRGGBB` with **straight** (non-premultiplied) alpha, no row
  padding, plus `opaque` (every alpha is 0xFF, so blending can copy).
  JPEG is always opaque. `rgbaBytes()` gives R,G,B,A bytes.
- **Scaling and blending:** `imageScaleBilinear(bitmap, width:, height:,
  maxBytes:)` (premultiplied interpolation, edges clamped, nil if over
  the cap) and `imageBlend(into: UnsafeMutablePointer<UInt32>, stride:,
  width:, height:, src:, x:, y:)`, which composites straight alpha over a
  32-bit XRGB buffer with clipping. Neither knows about the kernel's
  `Surface`. `ImageLRU<Key, Value>` is a tiny byte-budget LRU for the
  browser's decoded-image cache.
- **PNG details:** CRC errors in critical chunks fail; in ancillary
  chunks the chunk is dropped. Gamma, background and ICC are ignored.
  16-bit samples keep their high byte (color-key tRNS compares the full
  16 bits). Data after the last needed pixel is ignored; a missing IEND
  after complete image data is accepted. APNG decodes as its default
  image.
- **GIF details:** output is the logical screen size, transparent where
  the frame doesn't cover it (offset frames and local palettes work);
  the background color is ignored. Truncated LZW data leaves the rest
  transparent.
- **JPEG details:** follows libjpeg (accurate integer IDCT, fancy
  triangle upsampling for 2x1, 1x2 and 2x2, fixed-point YCbCr), so
  output is bit-exact with libjpeg-turbo's `djpeg` on every fixture.
  Adobe CMYK and YCCK decode to RGB. Truncated or corrupt entropy data
  decodes as far as it goes (like browsers) rather than failing.
  Arithmetic coding, lossless and 12-bit precision are `.unsupported`.
  Not done: EXIF orientation, ICC profiles, JPEG-in-CMYK without an
  Adobe marker beyond the plain inverse.
- **Inflate details:** table-driven (10-bit literal/length and 8-bit
  distance tables with a canonical slow path for longer codes), a 64-bit
  bit buffer, and unit-granular resumption: each symbol, dynamic table
  or stored header is decoded atomically and rewound if the chunk ends
  mid-unit, so any chunking (down to 1 byte) works. Window handling
  keeps the last 32 KiB after each `take()`. After the last member
  of a gzip stream the next bytes are ignored unless they start with
  `1f 8b`.

**Tests.** `inflate`: fixtures made by host zlib/gzip at levels 0, 1, 6 and
9 plus Z_HUFFMAN_ONLY, Z_RLE and Z_FIXED (`lib/inflate/fixtures/gen.py`),
a hand-built stream using every length and distance code, every gzip
header flag, multi-member files, a 1 MB file, bytewise streaming,
truncation at every offset, corrupted headers and checksums, bad codes,
distances too far back, output limits, and fuzzing. `image`: PngSuite
(all 162 valid files compared to a reference decoder written in Python,
`tests/refdecode.py`, itself cross-checked against Pillow; the 14 `x*`
files must be rejected; license in `fixtures/pngsuite/`), GIFs from a
small encoder in `tests/gen_fixtures.py`, JPEGs from `cjpeg` compared
with `djpeg` output (all subsamplings, restart markers, grayscale,
progressive, CMYK against Pillow), cap checks, truncation, and fuzzing
of all three decoders.

**Results** (host, `-Osize`, Apple silicon): inflate about 215 MB/s of
output; PNG about 53 MP/s and JPEG about 62 MP/s (baseline) and 55 MP/s
(progressive) on 1024×768 synthetic pictures (smooth content, so real
photos will be slower per pixel). All of this is plain Swift without
SIMD.

## Phase 8H: the browser app (`user/browse`)

- **Window:** an address bar (the 6F `TextField`), back, forward,
  reload/stop buttons, a page view, and a status line (loading progress,
  the URL under the mouse). The window title is the page's `<title>`.
- **Loading:** one event loop on `wait`. Fetch the document, parse it,
  start fetching stylesheets and images in parallel (up to 6
  connections per host), lay out once the CSS has arrived (or after a
  timeout), and relayout when images report their sizes. Show progress.
  Stop cancels everything.
- **Navigation:** link clicks (`target` is ignored), fragments
  (`#id` scrolls), history with scroll positions, `file://` URLs for
  local pages, `about:blank`, an `about:home` page with bookmarks
  (target sites), and `view-source:`.
- **Input:** scrolling with arrow keys, PgUp/PgDn, Space, Home/End, and
  the mouse wheel. That needs IntelliMouse mode in ps2.swift (the
  0xF3 200/100/80 knock, then 4-byte packets). Text selection and copy
  are a stretch.
- **Forms:** `<input>` (text, password, search, hidden, checkbox, radio,
  submit), `<textarea>`, `<select>` (a dropdown in the page) and
  `<button>`. Submit by GET and POST
  (`application/x-www-form-urlencoded`). That's enough for search on
  lite.duckduckgo.com and Wikipedia.
- **Errors** are pages, not crashes: DNS failure, connection refused,
  TLS failure (with the reason), and HTTP errors.
- **Desktop:** a taskbar launcher entry, and `browse <url>` from a
  terminal.

## Phase 8I: tests and target sites

- **Harness:** a host HTTP and HTTPS server (test CA) serves
  `tests/web/`: fixture pages covering each layout feature, images,
  redirects, chunked and gzip responses, cookies, forms (the server
  echoes the posted fields), and a slow or broken server (stalls,
  truncation, reset). Drive the browser with sendkey/mouse, then check
  the title, screendumps for a few pages, and that the browser process
  is still alive after each hostile case.
- **Fuzzing on the host:** HTML, CSS, PNG, JPEG, inflate, DNS, X.509 and
  TLS record parsing get a simple mutation fuzzer in the host test
  runner (random flips, truncation, and splicing of fixtures), run
  for a fixed number of iterations in `--hosttest`. A crash or a
  runaway allocation is a failed test.
- **Target sites** (manual checks, listed in the roadmap with a
  readable/broken status per site): info.cern.ch, example.com,
  lite.duckduckgo.com (search), en.wikipedia.org (an article and a
  search), news.ycombinator.com, text.npr.org, lite.cnn.com,
  a Wikipedia page with tables and images, and the Wiffer repo's README
  on GitHub (hard: heavy CSS; as a stretch).

**Done when:** every harness check passes under BIOS and UEFI, and the
target sites (except the stretch one) are readable and navigable.

---

## After Part 8

Not planned yet. Roughly in order of how much they'd help the browser:

- **JavaScript.** The big one, likely a Part of its own: an ES5 subset
  interpreter (bytecode, a mark-and-sweep GC), then DOM bindings,
  events, timers and `fetch`/XHR, then more ES2015+. Even a basic
  engine makes menus and "accept cookies" banners work. Full modern web
  apps stay out of reach.
- Threads in user space (a decoder or layout thread), and shared memory.
- POSIX or Linux syscall compatibility, so static musl programs can run
  as a source of ported apps.
- IPv6, HTTP/2, a persistent cookie jar and cache on /disk, downloads to
  /disk.
- CSS Grid, scrollable overflow boxes, transforms, web fonts (WOFF2 needs
  Brotli), SVG, WebP.
- An xHCI driver for `usb-tablet` (absolute mouse, no grab), and real
  hardware networking (e1000, which QEMU also emulates, is the usual
  next target).

## Decisions

Made on 2026-11-18:

1. **TLS is pure Swift:** written from scratch, or ported from an
   existing pure-Swift library where one fits Embedded Swift. No C
   libraries (no BearSSL, no BoringSSL wrappers).
2. **POSIX or Linux compatibility waits.** It's a possible later source
   of apps, but not before the browser works.
3. **JavaScript is a separate pass** after Part 8. Part 8's target sites
   are the ones that work without it.
