# lib/: pure-Swift libraries

Libraries with no OS dependencies (ROADMAP Parts 6–8, "Browser and
libraries"). Each builds two ways: into Wiffer user programs (Embedded
Swift, x86_64-unknown-none-elf) and into a host test binary.

```
./run.sh --hosttest            # every lib with a tests/ directory
./run.sh --hosttest html css   # just these
```

## Layout

```
lib/<name>/
  *.swift          the library (no imports, no libc, no Foundation)
  DEPS             other libs it uses, whitespace-separated (optional)
  SRCS             repo files outside lib/ it also compiles, e.g. the
                   kernel's surface.swift (lib/gui only; optional)
  USERSRCS         extra files for user programs only (lib/gui; optional)
  tests/*.swift    host tests: exactly one `func libTests(_ t: Tests)`
  fixtures/        test inputs, read from the repo root:
                   t.readFile("lib/<name>/fixtures/x.bin")
```

`lib/dns` is host-test only: its `SRCS` compiles the kernel's net_dns.swift
against stand-ins in `lib/dns/stubs.swift`. Every test binary also links
`hosttest/guard.c`, a watchdog that fails the run on a runaway allocation
(`WIFFER_HOSTTEST_MAX_MB`, default 1024) or a hang (`WIFFER_HOSTTEST_MAX_SECS`).

`hosttest/harness.swift` has `Tests` (`section`, `check`, `equal`,
`readFile`, `fuzz`), `TestRandom`, `hex` and `unhex`. `hosttest/host.h`
also has loopback TCP and popen helpers (`host_tcp_connect`,
`host_popen`, ...) for live tests such as lib/tls against a local
`openssl s_server`; tests only, never in a library.

## Rules

- **Embedded Swift subset.** No `any` existentials, no reflection, no
  `Codable`, no Foundation, no `String(format:)`. Errors use typed throws
  (`throws(HTTPError)`) or optionals/enums. Generics and class hierarchies
  are fine. `hosttest.sh` compiles each lib freestanding for
  x86_64-unknown-none-elf first, so a host-only construct fails the run.
- **One module per binary.** A lib, its DEPS and (later) a user program
  compile as a single module, so names must be unique across libs: prefix
  types and free functions (`HTMLNode`, `CSSParser`, `tlsHKDF`, `pngDecode`).
- **Hostile input.** Every parser takes `[UInt8]` (or a `ByteReader` from
  `lib/bytes`) and must never trap on bad input: no force unwraps on data,
  no unchecked subscripts or arithmetic overflow from input values, and
  explicit limits on sizes, depths and loop counts. The fuzzer in
  `--hosttest` treats a crash as a failure.
- **No globals with mutable state** unless documented (user programs may
  be single-threaded, but tests run every case in one process).

## User programs

A program in `user/<prog>/` lists the libs it uses in `user/<prog>/LIBS`
(same format as DEPS); build.sh compiles their sources (with transitive
DEPS) into the program's module alongside libwiffer.
