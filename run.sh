#!/usr/bin/env bash
# Boot the kernel ISO in QEMU. Serial output (COM1) goes to this terminal.
#   ./run.sh          BIOS boot, with a display window
#   ./run.sh --uefi   UEFI boot (OVMF from Homebrew's qemu)
#   ./run.sh --nographic   no window; serial only (Ctrl-A X to quit)
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

ARGS=(-M q35 -m 256M -cdrom build/wiffer.iso -boot d -no-reboot -no-shutdown)
DISPLAY_ARGS=(-serial stdio)
for a in "$@"; do
  case "$a" in
    --uefi) ARGS+=(-drive "if=pflash,format=raw,readonly=on,file=$(brew --prefix qemu)/share/qemu/edk2-x86_64-code.fd") ;;
    --nographic) DISPLAY_ARGS=(-nographic) ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done
exec qemu-system-x86_64 "${ARGS[@]}" "${DISPLAY_ARGS[@]}"
