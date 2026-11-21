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
case "$TRIPLE" in
  *linux*) HOST_LIBS+=(-lm) ;;
esac

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

# The runaway guard (hosttest/guard.c), linked into every test binary.
cc -O1 -c hosttest/guard.c -o "$OUT/guard.o"

# One lib: both builds, then the test. Runs in a subshell, up to JOBS at a
# time (WIFFER_HOSTTEST_JOBS, default 4; the swiftc builds dominate), with
# its output in $OUT/<lib>.log, printed in order at the end.
run_lib() {
  local lib="$1" n f e dup
  ORDER=(); visit "$lib"
  SRCS=()
  for n in "${ORDER[@]}"; do
    for f in lib/"$n"/*.swift; do [[ -e "$f" ]] && SRCS+=("$f"); done
    # lib/<n>/SRCS: repo files shared with the kernel (e.g. surface.swift).
    if [[ -f "lib/$n/SRCS" ]]; then
      for f in $(cat "lib/$n/SRCS"); do
        dup=0; for e in "${SRCS[@]}"; do [[ "$e" == "$f" ]] && dup=1; done
        (( dup )) || SRCS+=("$f")
      done
    fi
  done
  # 1. Freestanding Embedded compile (what user programs get).
  if ! swiftc -target x86_64-unknown-none-elf "${SWIFT_FLAGS[@]}" \
       -Xcc -mno-red-zone -emit-ir "${SRCS[@]}" -o "$OUT/$lib.elf.ll"; then
    echo "FAIL $lib: does not build for x86_64-unknown-none-elf"; return 1
  fi
  # 2. Host test binary.
  TESTS=(lib/"$lib"/tests/*.swift)
  if ! swiftc "${SWIFT_FLAGS[@]}" -import-objc-header hosttest/host.h \
       "${SRCS[@]}" "${TESTS[@]}" hosttest/harness.swift hosttest/runtime.swift \
       "$OUT/guard.o" "${HOST_LIBS[@]}" -o "$OUT/$lib"; then
    echo "FAIL $lib: host test build failed"; return 1
  fi
  WIFFER_HOSTTEST_LIB="$lib" "$OUT/$lib"
}

JOBS="${WIFFER_HOSTTEST_JOBS:-4}"
running=0
for lib in "${LIBS[@]}"; do
  rm -f "$OUT/$lib.status"
  ( if run_lib "$lib" > "$OUT/$lib.log" 2>&1; then echo 0; else echo 1; fi > "$OUT/$lib.status" ) &
  running=$((running + 1))
  if (( running >= JOBS )); then wait; running=0; fi
done
wait
status=0
for lib in "${LIBS[@]}"; do
  cat "$OUT/$lib.log"
  [[ "$(cat "$OUT/$lib.status" 2>/dev/null)" == 0 ]] || status=1
done
exit $status
