#!/usr/bin/env bash
# Boot the kernel ISO in QEMU. Serial output (COM1) goes to this terminal.
#   ./run.sh          BIOS boot into the desktop, with a display window
#   ./run.sh --uefi   UEFI boot (OVMF: Homebrew qemu's edk2, or Linux's ovmf)
#   ./run.sh --nographic   no window; serial only (Ctrl-A X to quit)
#   ./run.sh --nodesktop   the Part 2 full-screen shell (`nodesktop` cmdline)
#   ./run.sh --test   headless: scripted shell checks + in-kernel selftest
#   ./run.sh --test --uefi   the same, booted through OVMF
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

# UEFI firmware: Homebrew qemu's edk2 on macOS, the ovmf package on Linux
# (or set WIFFER_OVMF).
if [[ -z "${WIFFER_OVMF:-}" ]]; then
  if command -v brew >/dev/null; then
    WIFFER_OVMF="$(brew --prefix qemu)/share/qemu/edk2-x86_64-code.fd"
  else
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
      [[ -f "$f" ]] && { WIFFER_OVMF="$f"; break; }
    done
  fi
fi
export WIFFER_OVMF

ISO=build/wiffer.iso
EXTRA=()
DISPLAY_ARGS=(-serial stdio)
if [[ "${1:-}" == "--test" ]]; then
  [[ "${2:-}" == "--uefi" ]] && export WIFFER_UEFI=1
  exec python3 tests/serial_session.py
fi
for a in "$@"; do
  case "$a" in
    --uefi) EXTRA+=(-drive "if=pflash,format=raw,readonly=on,file=$WIFFER_OVMF") ;;
    --nographic) DISPLAY_ARGS=(-nographic) ;;
    --nodesktop) ISO=build/wiffer-nodesktop.iso ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done
exec qemu-system-x86_64 -M q35 -m 256M -cdrom "$ISO" -boot d -no-reboot -no-shutdown \
  ${EXTRA[@]+"${EXTRA[@]}"} "${DISPLAY_ARGS[@]}"
