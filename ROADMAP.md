# Roadmap

- **Part 1: Serial shell.** Done (M1–M4).
- **Part 2: Graphical shell.** Done (Phases A–G). The original plan for both
  parts is in git history (`git show 4cf881e:ROADMAP.md`).
- **Part 3: Window manager and text editor.** This document.

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
