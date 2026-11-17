# Roadmap

- **Part 1: Serial shell.** The simplest possible prompt, built under the
  current constraints (no heap, no interrupts, no SSE).
- **Part 2: Graphical shell.** Descriptor tables, interrupts, memory
  management, a Swift heap, a framebuffer console, and keyboard/mouse input.

```
Part 1:  M1 echo → M2 line edit → M3 dispatch → M4 numbers
                                       │
Part 2:  A GDT/IDT ─→ B timer/IRQs ─→ F input ───────────────┐
            │                                                ▼
            └──→ C memory + heap ─→ E graphical console ─→ G graphical shell
                        │
                        └──→ D SSE (optional: Dictionary, Set, Float)
```

---

# Part 1: Serial shell

Goal: boot, print `> `, read a line, run a built-in command, repeat.

The shortest path uses the **serial port (COM1)** for both input and output.
QEMU's `-nographic` (`./run.sh --nographic`) connects it to your terminal, so:

- no keyboard driver, font, or framebuffer text rendering
- no interrupts, GDT/IDT, or heap: polling a UART is enough
- everything stays inside the current constraints (`-no-allocations`, no SSE)

A serial echo loop with an `InlineArray<128, UInt8>` line buffer has already
been prototyped and works under the current build flags.

---

## Milestone 1: echo (≈20 lines)

- `getc()`: spin until COM1 line-status bit 0 (data ready, port `0x3FD`) is
  set, then `inb(0x3F8)`.
- `putc()`: existing transmit-empty wait (bit 5) + `outb`.
- Main loop: `putc(getc())` forever.

**Done when:** typed characters appear in `./run.sh --nographic`.

Gotchas: the terminal sends Enter as `\r` (13), not `\n`; output needs
`\r\n` to return to column 0. Quit QEMU with `Ctrl-A X`.

## Milestone 2: line editing

- Line buffer: `var line = InlineArray<128, UInt8>(repeating: 0)` + `len`
  (stack storage, no heap).
- Enter (`\r`): print `\r\n`, hand `line[0..<len]` to the dispatcher, reset.
- Backspace (`0x7F` from most terminals, sometimes `0x08`): if `len > 0`,
  decrement and print `"\u{8} \u{8}"` to erase on screen.
- Ignore other control bytes (< 32); stop accepting input when full.
- Print the prompt `> ` after each line.

**Done when:** you can type, fix typos, and submit lines.

## Milestone 3: parse and dispatch

- Split the line on the first space into `command` and `args`
  (just indices into the buffer, no copies).
- Compare bytes against `StaticString` names with a small `equals(_:_:)`
  helper (`StaticString.withUTF8Buffer` + length check + byte loop).
- `switch`/`if` chain over built-ins; unknown → `unknown command: <cmd>`.

Initial built-ins (each is a few lines):

| Command  | Implementation                                          |
|----------|---------------------------------------------------------|
| `help`   | print the command list                                  |
| `echo`   | print `args`                                            |
| `clear`  | print `ESC[2J ESC[H`                                    |
| `halt`   | `hcf()`                                                 |
| `reboot` | `outb(0x64, 0xFE)` (keyboard controller reset line)     |

**Done when:** `help`, `echo hello`, `clear`, `reboot` all work. ← *the
simplest shell prompt.*

## Milestone 4 (optional polish): output numbers

- `printHex(UInt64)` / `printDec(UInt64)` using a fixed digit buffer
  (avoid `String(describing:)` / string interpolation — they allocate).
- Unlocks informative commands: `fb` (framebuffer width/height/pitch from the
  existing Limine response), `peek <hex addr>`, `mem` (add a Limine memmap
  request in `boot.c` and sum usable entries).

---

# Part 2: Graphical shell

Goal: a shell on the QEMU display, typed on the PS/2 keyboard, written in
ordinary Swift (`String`, `Array`, classes, `print`), with faults reported
instead of silent reboots.

Ground rules that carry through every phase:

- **Kernel flags stay:** `-mno-red-zone`, `-mcmodel=kernel`, and no stack
  protector.
- **Interrupt and exception entry points are assembly.** Swift has no
  `interrupt` calling convention. Add a `cpu.S` (assembled by `clang -c`,
  not LTO) with stubs that save registers, call into Swift through a
  `@_cdecl` function, then `iretq`. Put the register-frame struct in
  `bridge.h` so Swift sees its layout.
- **No allocation inside interrupt handlers.** Handlers push into
  fixed-size ring buffers, and the main loop does the real work.
- **Debugging:** run with `-d int,cpu_reset -no-reboot` to see the fault
  behind a triple fault. Use `-s -S` and `lldb build/kernel.elf`
  (`gdb-remote 1234`) to single-step.

## Phase A: descriptor tables and exceptions

**A1. GDT + TSS.** Replace Limine's GDT with your own:

- Entries: null, 64-bit kernel code, kernel data, a TSS descriptor (16
  bytes), and user code/data slots for later.
- The TSS's `ist1` points at a dedicated stack for double faults, so a
  kernel stack overflow can still be reported.
- Load it with `lgdt`, reload CS with a far return (`lretq`) in `cpu.S`,
  reload the data segment registers, then `ltr`.

**A2. IDT + exception handlers.**

- 256 gates. Vectors 0–31 come from a macro-generated stub table in
  `cpu.S`.
- Stubs for vectors without a CPU error code push a dummy 0, so every
  vector has the same frame layout.
- One Swift dispatcher `@_cdecl("interrupt_dispatch")(frame)`.
- For exceptions, print the vector name, error code, `rip`, `rsp`, and
  (for #PF) `cr2`, then call `hcf()`.
- Double fault (#8) uses IST1.

**Done when:** `ud2`, divide-by-zero, and a write to an unmapped address
each print a report instead of rebooting QEMU. Add a `fault <kind>` shell
command to trigger them on demand.

## Phase B: interrupts and timer

**B1. Interrupt controller.**

- Start with the legacy **8259 PIC**: remap it to vectors 0x20–0x2F and
  mask everything except the IRQs you handle.
- It's far less code than the APIC path (ACPI MADT parsing, LAPIC/IOAPIC
  MMIO), which you only need for SMP or MSI. Defer it.

**B2. Timer.**

- Program the PIT (channel 0) to ~100 Hz and count ticks on IRQ0.
- Send an EOI at the end of each handler. Forgetting it is the classic
  "interrupts stop after the first one" bug.
- `sti` once the IDT is loaded; replace busy loops with `hlt` when idle.

**Done when:** an `uptime` command shows seconds increasing, and the idle
CPU sits in `hlt`.

## Phase C: memory and the Swift heap

**C1. Boot memory info.** In `boot.c`, add Limine **memmap** and **HHDM**
requests. HHDM is the higher-half direct map: physical memory at
`hhdm_offset + phys`.

**C2. Physical frame allocator.**

- Track 4 KiB frames from `LIMINE_MEMMAP_USABLE` entries with a bitmap
  (store the bitmap inside the first usable region) or a free list.
- Leave `BOOTLOADER_RECLAIMABLE` untouched while you still read Limine
  responses.
- Add a `mem` command that shows total, used, and free.

**C3. Paging: almost not yet.** Limine's page tables already map the kernel
and HHDM. But Swift keeps tag bits in the top nibble of object and String
literal pointers, so heap objects can't live at HHDM addresses
(`0xffff8000…`), and literals/static objects in the kernel image
(`0xffffffff8…`) break the same way. Two copied PML4 entries are enough:
`PML4[0] = HHDM entry` (identity map: the heap hands out `virt == phys`)
and `PML4[255] = PML4[511]` (the kernel image is also mapped at
`H - 0xffff800000000000`). `build.sh` then rewrites String literal and
static-object references in the IR to use that alias. Build your own PML4
later, when you want guard pages, user space, or MMIO with custom caching.

**C4. Kernel heap.** Implement the Embedded Swift platform hooks (the
contract is in the toolchain's `usr/include/swift/EmbeddedPlatform.h`):

```c
void *_swift_allocate(size_t alignment, size_t size, swift_alloc_flags_t flags);
void  _swift_deallocate(void *ptr, size_t alignment, size_t size, swift_dealloc_flags_t flags);
```

- Start with a **bump allocator** (deallocate is a no-op) to get Swift
  running.
- Then switch to **size-class free lists**: power-of-two buckets
  16 B–2 KiB, plus whole frames for large blocks.
- `size` passed to deallocate may be `-1` (unknown), so keep a small
  header recording each block's size class.
- Return `NULL` on out-of-memory; Swift traps.
- Wrap the allocator in `cli`/`sti` (save and restore the flags) so it's
  safe even if something allocates with interrupts on.

**C5. Turn the heap on in the build.**

- Remove `-no-allocations`.
- Implement three more hooks: `_swift_writeToStandardOutput` (send it to
  serial for now; it becomes the console in Phase E), and
  `_swift_lockStandardOutput`/`_swift_unlockStandardOutput` (no-ops or
  `cli`/`sti`, since there's one CPU).
- Update the `build.sh` check. `swift_retain` and `swift_release` are now
  compiled into the kernel, so the right invariant is **"no undefined
  symbols"**, not "no `swift_*` symbols". The binary still has no external
  runtime.

Already verified with this toolchain: classes, `Array`, `String`, string
interpolation and `print()` link against exactly those five hooks, about
9.5 KB of code, with no SSE instructions.

**Done when:** `print("free: \(pmm.freeFrames) frames")` works and a
stress test (allocate and free 10k nodes in a loop) doesn't leak.

## Phase D: enable SSE (optional, needed for `Dictionary`, `Set`, `Float`)

`Dictionary` and `Set` use floating-point maths for capacity, so they fail
to compile with SSE off. That is verified with this toolchain: "SSE register
return with SSE disabled".

- At boot: set CR0.MP=1 and CR0.EM=0, set CR4.OSFXSR and CR4.OSXMMEXCPT,
  then `fninit`.
- Remove `-mno-sse -mno-mmx -msoft-float` from both Swift and C flags. Keep
  `-mno-red-zone`.
- Interrupt stubs must now preserve SSE state: `fxsave`/`fxrstor` into a
  16-byte-aligned 512-byte area around the dispatcher call. Otherwise a
  handler that uses SSE silently corrupts the interrupted code's registers.
- Drop the `%xmm` check from `build.sh`.

**Done when:** a `[String: Int]` works in the shell (e.g. a variables table
for `set`/`get`).

## Phase E: graphical text console

**E1. Font.**

- Embed an 8×16 bitmap font. PSF1/PSF2 are easy to parse. Spleen (BSD-2)
  and Terminus (OFL) are good choices; `fonts/spleen-8x16.psfu` is PSF1
  with a Unicode table.
- Include it with `.incbin` in a small `font.S` (assembled like `cpu.S`).
- Write `drawGlyph(cell, fg, bg)`.

**E2. Console model.**

- Keep a text grid (`cols × rows` of character + colour) as the source of
  truth, plus a cursor.
- Implement `\n`, `\r`, backspace, tab, and scrolling by shifting the grid
  and redrawing.
- Support a few ANSI escapes (`ESC[2J`, `ESC[H`, SGR colours), so `clear`
  and colour output from Part 1 keep working unchanged.

**E3. Double buffering.**

- Render into a heap-allocated back buffer, then copy dirty rows to the
  framebuffer.
- Reading from framebuffer memory is very slow on real hardware, so never
  read it back when scrolling.

**E4.** Point `_swift_writeToStandardOutput` at the console, and keep
mirroring to serial for headless tests.

**Done when:** `print` output and the boot log appear on the QEMU window,
and scrolling works past the bottom of the screen.

## Phase F: input devices

**F1. PS/2 keyboard (IRQ1).**

- The handler reads port `0x60` and pushes the scancode into a fixed ring
  buffer: single producer, single consumer.
- The main loop decodes scancode set 1:
  - Track Shift, Ctrl and Caps state.
  - Ignore release codes (bit 7 set), except for the modifiers.
  - Handle the `0xE0` prefix for arrows, Home/End and Delete.
- Emit `KeyEvent`s.

**F2. PS/2 mouse (IRQ12, optional).**

- Enable the aux device (`0x64 ← 0xA8`), then send `0xD4, 0xF4` to enable
  reporting.
- Unmask IRQ2 (the cascade) and IRQ12.
- Parse 3-byte packets: buttons, dx, dy with sign bits. Re-sync on bit 3
  of byte 0.

**Done when:** keys echo on the console, and a cursor sprite follows the
mouse.

## Phase G: graphical shell

**G1. Port the Part 1 shell.**

- Hide I/O behind a generic `Terminal` protocol (`read() -> KeyEvent`,
  `write(_:)`). Prefer generics over `any Terminal`, because existentials
  are limited in Embedded Swift.
- The same shell then runs on serial or on the console.
- With a heap, the code gets simpler:
  - Split lines into `[Substring]`.
  - Use a command table of `(name: String, help: String, run: ([Substring]) -> Void)`.
  - Error messages can use interpolation.

**G2. Line editing.** Left/right cursor movement, Home/End, history with
the up/down arrows (`[String]`), and tab completion over command names.

**G3. Commands.**

- Keep everything from Part 1.
- Add `uptime`, `mem` (frame and heap stats), `fb`, `color <fg> <bg>`,
  `fault <kind>`, and `set`/`get` (if Phase D is done).

**G4. Graphical touches (stretch).**

- Status bar with uptime and memory, redrawn on timer ticks.
- The shell in a bordered window with a title.
- Mouse cursor, and click-to-focus between two shell windows.
- A tiny compositor that redraws only damaged rectangles.

**Done when:** the system boots straight into a coloured prompt on the
QEMU window with history and completion, and a deliberate fault shows a
readable report on screen.

---

## Cross-cutting: automated boot tests

Add a `./run.sh --test` mode that boots QEMU headless with
`-device isa-debug-exit,iobase=0xf4,iosize=0x04` and serial on a file. A
test kernel entry runs self-checks (allocator stress, fault recovery,
console scroll) and writes the result to port `0xF4`. QEMU's exit code
becomes `(value << 1) | 1`. Run it after every phase so regressions show up
immediately.
