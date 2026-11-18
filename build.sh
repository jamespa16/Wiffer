#!/usr/bin/env bash
# Build a freestanding x86-64 kernel (no external runtime) and a bootable Limine ISO.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

# Kernel codegen flags shared by Swift (via -Xcc) and C:
#   no red zone (interrupts clobber below %rsp), kernel code model (Limine
#   loads us in the top 2 GiB). SSE is on (Phase D): kernel_main enables it
#   before any other code runs, and the interrupt stubs fxsave/fxrstor it.
KFLAGS=(-mno-red-zone -mcmodel=kernel)
XCC=(); for f in "${KFLAGS[@]}"; do XCC+=(-Xcc "$f"); done

# 1. Swift -> LLVM IR.
#    (heap on: _swift_allocate etc. are implemented in heap.swift/platform.swift)
#    -disable-stack-protector : no __stack_chk_guard/__stack_chk_fail
#    -disable-swift-specific-llvm-optzns : Swift's LLVM ARC passes treat
#      swift_retain as touching nothing but the refcount, and moved a copy's
#      retain past Embedded Swift's inlined uniqueness check (an atomic load
#      of that same refcount): `var b = a; b[i] = x` then wrote into `a`'s
#      buffer too, breaking copy-on-write (fs_selftest copyOnWrite).
#    -import-objc-header      : Limine structs + outb/inb/hcf from C
swiftc \
  -target x86_64-unknown-none-elf \
  -enable-experimental-feature Embedded \
  -wmo -parse-as-library -Osize \
  -Xfrontend -disable-stack-protector \
  -Xfrontend -disable-swift-specific-llvm-optzns \
  -import-objc-header bridge.h \
  "${XCC[@]}" \
  -emit-ir *.swift -o build/kernel.raw.ll

# 2. Drop @llvm.used, which pins embedded runtime stubs
#    (swift_isClassType, _swift_fatalError, ...) so they survive DCE.
#    Then make Swift see kernel-image data at its lower-half alias. Swift keeps
#    tag bits in the top nibble of String literal and object pointers, which
#    0xffffffff8xxxxxxx addresses collide with. FrameAllocator.mapLowerHalf
#    maps the image again at H - 0xffff800000000000 (PML4[255] = PML4[511]):
#    - String literals: "(address - 32) | flags" becomes
#      "(address - (32 + 0xffff800000000000)) | flags" (as a signed i64).
#      Inside statically initialised objects (e.g. an array literal of
#      structs holding Strings, like the shell's command table) the flag bit
#      is folded in: "address + (2^63 - 32)" becomes
#      "address + (2^63 - 32 - 0xffff800000000000)" (mod 2^64, signed).
#    - Static objects (empty-array/box singletons, statically initialised
#      objects "...Tv_", "...Tv_r"): every use, but not the definition, goes
#      through inttoptr(ptrtoint + 0x800000000000), which LLVM can't see through.
ALIAS='inttoptr (i64 add (i64 ptrtoint (ptr \1 to i64), i64 140737488355328) to ptr)'
STATIC_OBJ='@"(\$es[0-9]+_swiftEmpty[^"]*|\$es[0-9]+_empty[A-Za-z]*Storage[^"]*|[^"]*Tv_r?)"'
sed -E -e '/^@llvm\.used = /d' \
  -e 's/sub \(i64 ptrtoint \(ptr (@\.str[^ ]*|@"\.str[^"]*") to i64\), i64 32\)/sub (i64 ptrtoint (ptr \1 to i64), i64 -140737488355296)/g' \
  -e 's/add \(i64 ptrtoint \(ptr (@\.str[^ ]*|@"\.str[^"]*") to i64\), i64 9223372036854775776\)/add (i64 ptrtoint (ptr \1 to i64), i64 -9223231299366420512)/g' \
  -e "s/ ($STATIC_OBJ)/ $ALIAS/g" \
  build/kernel.raw.ll > build/kernel.ll
#    Any String literal reference left in another form would point into the
#    high kernel image and crash at run time, so refuse to build.
if grep -qE 'ptrtoint \(ptr (@\.str[^ ]*|@"\.str[^"]*") to i64\), i64 (32|9223372036854775776)\)' build/kernel.ll; then
  echo "error: String literal reference not rewritten to the lower-half alias" >&2; exit 1
fi

# 3. IR / C -> LTO bitcode objects. Codegen is deferred to the linker so unused
#    runtime functions (e.g. swift_intToFloat32, which can't codegen without SSE)
#    get internalized and deleted first.
clang -target x86_64-unknown-none-elf -flto -Wno-override-module \
  -c build/kernel.ll -o build/kernel.o
clang -target x86_64-unknown-none-elf -flto -ffreestanding -nostdlib -O2 \
  -Wall -Wextra "${KFLAGS[@]}" -fno-stack-protector -fno-pic \
  -c boot.c -o build/boot.o
#    Interrupt stubs + GDT reload: plain assembly, so a real object (not LTO).
clang -target x86_64-unknown-none-elf "${KFLAGS[@]}" -c cpu.S -o build/cpu.o
#    The console font (.incbin of fonts/spleen-8x16.psfu).
clang -target x86_64-unknown-none-elf "${KFLAGS[@]}" -c font.S -o build/font.o

# 4. Link. Only ENTRY(kernel_main), the Limine requests, and what they reach is kept.
#    libswiftUnicodeDataTables: the Unicode normalization/grapheme tables that
#    String ==, < and hashing need (prebuilt for x86_64-unknown-none-elf). Its
#    code uses only PC-relative relocations (fine in the top 2 GiB), no red zone.
SWIFT_RESOURCES="$(swiftc -print-target-info -target x86_64-unknown-none-elf |
  sed -n 's/.*"runtimeResourcePath": "\(.*\)".*/\1/p')"
UNICODE_TABLES="$SWIFT_RESOURCES/embedded/x86_64-unknown-none-elf/libswiftUnicodeDataTables.a"
ld.lld -T linker.ld -nostdlib -static --gc-sections -z norelro -z max-page-size=0x1000 \
  --build-id=none --lto-O2 build/kernel.o build/boot.o build/cpu.o build/font.o \
  "$UNICODE_TABLES" -o build/kernel.elf

# 5. Verify: no undefined symbols (swift_retain etc. are compiled in, but
#    there is no external runtime), and no SSE in the entry point, which runs
#    before SSE is enabled: kernel_main (the @_cdecl thunk) and the Swift
#    kernelEntry it calls (see kernel.swift).
if [[ -n "$(llvm-nm -u build/kernel.elf)" ]]; then
  echo "error: undefined symbols:" >&2; llvm-nm -u build/kernel.elf >&2; exit 1
fi
ENTRY_SYMS="kernel_main$(llvm-nm build/kernel.elf | awk '$3 ~ /kernelEntry/ { printf ",%s", $3 }')"
if llvm-objdump -d --disassemble-symbols="$ENTRY_SYMS" build/kernel.elf | grep -qE '%[xy]mm'; then
  echo "error: SSE instructions in $ENTRY_SYMS (runs before SSE is enabled)" >&2; exit 1
fi
echo "OK: build/kernel.elf"

# 6. Root filesystem (Phase M): rootfs/ as a ustar archive, loaded by Limine as
#    a module (limine.conf module_path) and unpacked into the RAM fs by
#    ustar.swift. No macOS metadata (._ files, xattrs); owner root.
COPYFILE_DISABLE=1 bsdtar --format ustar --no-mac-metadata --no-xattrs --no-fflags \
  --uid 0 --gid 0 --uname root --gname root -cf build/rootfs.tar -C rootfs .

# 7. Bootable hybrid BIOS/UEFI ISOs. wiffer.iso boots limine.conf's first
#    entry (the desktop); wiffer-nodesktop.iso is the same plus
#    `default_entry: 2`: the `nodesktop` cmdline, the Part 2 full-screen shell.
#    Limine's boot files: Homebrew on macOS; elsewhere, share/limine next to
#    the `limine` binary's prefix (or set LIMINE_SHARE).
if [[ -z "${LIMINE_SHARE:-}" ]]; then
  if command -v brew >/dev/null; then
    LIMINE_SHARE="$(brew --prefix limine)/share/limine"
  else
    LIMINE_SHARE="$(dirname "$(dirname "$(readlink -f "$(command -v limine)")")")/share/limine"
  fi
fi
make_iso() { # <iso path> <default entry>
  local root=build/iso_root
  rm -rf "$root"
  mkdir -p "$root/boot/limine" "$root/EFI/BOOT"
  cp build/kernel.elf build/rootfs.tar "$root/boot/"
  { echo "default_entry: $2"; cat limine.conf; } > "$root/boot/limine/limine.conf"
  cp "$LIMINE_SHARE"/limine-bios.sys "$LIMINE_SHARE"/limine-bios-cd.bin \
     "$LIMINE_SHARE"/limine-uefi-cd.bin "$root/boot/limine/"
  cp "$LIMINE_SHARE"/BOOTX64.EFI "$LIMINE_SHARE"/BOOTIA32.EFI "$root/EFI/BOOT/"
  xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
    -apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$root" -o "$1" 2>/dev/null
  limine bios-install "$1" 2>/dev/null
  echo "OK: $1"
}
make_iso build/wiffer.iso 1
make_iso build/wiffer-nodesktop.iso 2
