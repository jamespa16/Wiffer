#!/usr/bin/env bash
# Fetch the pinned test262 commit into build/test262 (gitignored), for the
# parser tests in lib/js/tests (they skip when it's absent). Only test/,
# harness/ and LICENSE are checked out (sparse, shallow).
#
#     lib/js/tools/fetch_test262.sh
#
# test262 is BSD-licensed (build/test262/LICENSE). Bump the commit by hand
# and update the pass-count floor in lib/js/tests/jsparser_tests.swift.
set -euo pipefail
cd "$(dirname "$0")/../../.."
COMMIT=2e58f87d8350ad51224617a041c6e041d52f8444
DEST=build/test262
if [[ -f "$DEST/.wiffer-commit" && "$(cat "$DEST/.wiffer-commit")" == "$COMMIT" ]]; then
  echo "test262 $COMMIT already in $DEST"; exit 0
fi
rm -rf "$DEST"
mkdir -p "$DEST"
git -C "$DEST" init -q
git -C "$DEST" remote add origin https://github.com/tc39/test262.git
git -C "$DEST" sparse-checkout set --no-cone /LICENSE /harness/ /test/language/ /test/annexB/language/
git -C "$DEST" fetch -q --depth 1 --filter=blob:none origin "$COMMIT"
git -C "$DEST" checkout -q FETCH_HEAD
echo "$COMMIT" > "$DEST/.wiffer-commit"
echo "test262 $COMMIT in $DEST: $(find "$DEST/test" -name '*.js' | wc -l) files"
