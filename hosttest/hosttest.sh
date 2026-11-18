#!/usr/bin/env bash
# Host test runner for the pure-Swift libraries in lib/ (ROADMAP Parts 6-8,
# "Browser and libraries"). `./run.sh --hosttest [lib...]` runs this.
#
# For each lib/<name>/ (or just the ones named):
#   1. Embedded check: lib/<name>/*.swift plus its dependencies' sources
#      compile freestanding for x86_64-unknown-none-elf (what Wiffer user
#      programs use), with no libc and no host header.
#   2. Host test: the same sources plus lib/<name>/tests/*.swift and
#      hosttest/*.swift build as one Embedded Swift module for the host, and
#      the binary runs from the repository root. It prints FAIL lines and a
#      summary, and exits non-zero on any failure.
#
# lib/<name>/DEPS lists the other libs it uses (whitespace-separated, in
# dependency order; transitive deps are followed). One module per binary, so
# type and function names must be unique across a lib and everything it
# depends on: prefix them (HTMLNode, CSSToken, TLSRecord, ...).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/hosttest
mkdir -p "$OUT"

RES="$(swiftc -print-target-info | sed -n 's/.*"runtimeResourcePath": "\(.*\)".*/\1/p')"
TRIPLE="$(swiftc -print-target-info | sed -n 's/.*"unversionedTriple": "\(.*\)".*/\1/p' | head -1)"
case "$TRIPLE" in
  *apple*) EMB="$RES/embedded/$(echo "$TRIPLE" | sed 's/-apple-.*/-apple-macos/')" ;;
  *) EMB="$RES/embedded/$TRIPLE" ;;
esac
HOST_LIBS=("$EMB/libswiftUnicodeDataTables.a" "$EMB/libswiftEmbeddedPlatformPOSIX.a")

SWIFT_FLAGS=(-enable-experimental-feature Embedded -wmo -parse-as-library -Osize
  -Xfrontend -disable-swift-specific-llvm-optzns)

# deps <name>: the lib and its transitive DEPS, dependencies first, no repeats.
declare -a ORDER=()
visit() {
  local n="$1" d
  for d in "${ORDER[@]+"${ORDER[@]}"}"; do [[ "$d" == "$n" ]] && return 0; done
  [[ -d "lib/$n" ]] || { echo "error: no such lib: $n" >&2; exit 1; }
  if [[ -f "lib/$n/DEPS" ]]; then
    for d in $(cat "lib/$n/DEPS"); do visit "$d"; done
  fi
  ORDER+=("$n")
}

if [[ $# -gt 0 ]]; then LIBS=("$@"); else
  LIBS=(); for d in lib/*/; do [[ -d "$d/tests" ]] && LIBS+=("$(basename "$d")"); done
fi

status=0
for lib in "${LIBS[@]}"; do
  ORDER=(); visit "$lib"
  SRCS=()
  for n in "${ORDER[@]}"; do
    for f in lib/"$n"/*.swift; do [[ -e "$f" ]] && SRCS+=("$f"); done
  done
  # 1. Freestanding Embedded compile (what user programs get).
  if ! swiftc -target x86_64-unknown-none-elf "${SWIFT_FLAGS[@]}" \
       -Xcc -mno-red-zone -emit-ir "${SRCS[@]}" -o "$OUT/$lib.elf.ll"; then
    echo "FAIL $lib: does not build for x86_64-unknown-none-elf"; status=1; continue
  fi
  # 2. Host test binary.
  TESTS=(lib/"$lib"/tests/*.swift)
  if ! swiftc "${SWIFT_FLAGS[@]}" -import-objc-header hosttest/host.h \
       "${SRCS[@]}" "${TESTS[@]}" hosttest/harness.swift hosttest/runtime.swift \
       "${HOST_LIBS[@]}" -o "$OUT/$lib"; then
    echo "FAIL $lib: host test build failed"; status=1; continue
  fi
  WIFFER_HOSTTEST_LIB="$lib" "$OUT/$lib" || status=1
done
exit $status
