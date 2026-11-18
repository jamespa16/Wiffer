#!/usr/bin/env bash
# Boot the kernel ISO in QEMU. Serial output (COM1) goes to this terminal.
#   ./run.sh          BIOS boot into the desktop, with a display window
#   ./run.sh --uefi   UEFI boot (OVMF: Homebrew qemu's edk2, or Linux's ovmf)
#   ./run.sh --nographic   no window; serial only (Ctrl-A X to quit)
#   ./run.sh --nodesktop   the Part 2 full-screen shell (`nodesktop` cmdline)
#   ./run.sh --test   headless: scripted shell checks + in-kernel selftest
#   ./run.sh --test --uefi   the same, booted through OVMF
#   ./run.sh --smp N   N virtual CPUs (default 4, or env WIFFER_SMP); works with --test
# Options may be given in any order.
set -euo pipefail
cd "$(dirname "$0")"

TEST=0 UEFI=0 NODESKTOP=0 NOGRAPHIC=0
SMP="${WIFFER_SMP:-4}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test) TEST=1 ;;
    --uefi) UEFI=1 ;;
    --nographic) NOGRAPHIC=1 ;;
    --nodesktop) NODESKTOP=1 ;;
    --smp)
      [[ $# -ge 2 ]] || { echo "--smp needs a count" >&2; exit 1; }
      SMP="$2"; shift ;;
    --smp=*) SMP="${1#--smp=}" ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
[[ "$SMP" =~ ^[1-9][0-9]*$ ]] || { echo "invalid --smp count: $SMP" >&2; exit 1; }

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

if (( TEST )); then
  export WIFFER_SMP="$SMP"
  (( UEFI )) && export WIFFER_UEFI=1
  exec python3 tests/serial_session.py
fi

ISO=build/wiffer.iso
(( NODESKTOP )) && ISO=build/wiffer-nodesktop.iso
EXTRA=()
DISPLAY_ARGS=(-serial stdio)
(( UEFI )) && EXTRA+=(-drive "if=pflash,format=raw,readonly=on,file=$WIFFER_OVMF")
(( NOGRAPHIC )) && DISPLAY_ARGS=(-nographic)
exec qemu-system-x86_64 -M q35 -m 256M -cpu max -smp "$SMP" -cdrom "$ISO" -boot d -no-reboot -no-shutdown \
  ${EXTRA[@]+"${EXTRA[@]}"} "${DISPLAY_ARGS[@]}"
