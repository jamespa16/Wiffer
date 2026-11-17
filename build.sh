#!/usr/bin/env bash
# Build a freestanding x86-64 kernel (no external runtime) and a bootable Limine ISO.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

# Kernel codegen flags shared by Swift (via -Xcc) and C:
#   no red zone (interrupts clobber below %rsp), no SSE/MMX/FPU state,
#   kernel code model (Limine loads us in the top 2 GiB).
KFLAGS=(-mno-red-zone -mno-sse -mno-mmx -msoft-float -mcmodel=kernel)
XCC=(); for f in "${KFLAGS[@]}"; do XCC+=(-Xcc "$f"); done

# 1. Swift -> LLVM IR.
#    (heap on: _swift_allocate etc. are implemented in heap.swift/platform.swift)
#    -disable-stack-protector : no __stack_chk_guard/__stack_chk_fail
#    -import-objc-header      : Limine structs + outb/inb/hcf from C
swiftc \
  -target x86_64-unknown-none-elf \
  -enable-experimental-feature Embedded \
  -wmo -parse-as-library -Osize \
  -Xfrontend -disable-stack-protector \
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
#    - Static objects (empty-array/box singletons, statically initialised
#      objects "...Tv_", "...Tv_r"): every use, but not the definition, goes
#      through inttoptr(ptrtoint + 0x800000000000), which LLVM can't see through.
ALIAS='inttoptr (i64 add (i64 ptrtoint (ptr \1 to i64), i64 140737488355328) to ptr)'
STATIC_OBJ='@"(\$es[0-9]+_swiftEmpty[^"]*|\$es[0-9]+_empty[A-Za-z]*Storage[^"]*|[^"]*Tv_r?)"'
sed -E -e '/^@llvm\.used = /d' \
  -e 's/sub \(i64 ptrtoint \(ptr (@\.str[^ ]*|@"\.str[^"]*") to i64\), i64 32\)/sub (i64 ptrtoint (ptr \1 to i64), i64 -140737488355296)/g' \
  -e "s/ ($STATIC_OBJ)/ $ALIAS/g" \
  build/kernel.raw.ll > build/kernel.ll

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

# 4. Link. Only ENTRY(kernel_main), the Limine requests, and what they reach is kept.
ld.lld -T linker.ld -nostdlib -static --gc-sections -z norelro -z max-page-size=0x1000 \
  --build-id=none --lto-O2 build/kernel.o build/boot.o build/cpu.o -o build/kernel.elf

# 5. Verify: no undefined symbols (swift_retain etc. are compiled in, but
#    there is no external runtime), no SSE.
if [[ -n "$(llvm-nm -u build/kernel.elf)" ]]; then
  echo "error: undefined symbols:" >&2; llvm-nm -u build/kernel.elf >&2; exit 1
fi
if llvm-objdump -d build/kernel.elf | grep -qE '%[xy]mm'; then
  echo "error: SSE instructions present" >&2; exit 1
fi
echo "OK: build/kernel.elf"

# 6. Bootable hybrid BIOS/UEFI ISO.
LIMINE_SHARE="$(brew --prefix limine)/share/limine"
ISO_ROOT=build/iso_root
rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT/boot/limine" "$ISO_ROOT/EFI/BOOT"
cp build/kernel.elf "$ISO_ROOT/boot/"
cp limine.conf "$LIMINE_SHARE"/limine-bios.sys "$LIMINE_SHARE"/limine-bios-cd.bin \
   "$LIMINE_SHARE"/limine-uefi-cd.bin "$ISO_ROOT/boot/limine/"
cp "$LIMINE_SHARE"/BOOTX64.EFI "$LIMINE_SHARE"/BOOTIA32.EFI "$ISO_ROOT/EFI/BOOT/"
xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
  -apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
  -efi-boot-part --efi-boot-image --protective-msdos-label \
  "$ISO_ROOT" -o build/wiffer.iso 2>/dev/null
limine bios-install build/wiffer.iso 2>/dev/null
echo "OK: build/wiffer.iso"
