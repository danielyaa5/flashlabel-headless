#!/usr/bin/env bash
# Offline test suite: unit tests plus an end-to-end CLI dry run on synthetic labels.
# Never uses Bluetooth and never prints.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/flashlabel-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SWIFTC=(xcrun swiftc -swift-version 5 -parse-as-library -warnings-as-errors)

echo "== compile CLI (warnings are errors)"
"${SWIFTC[@]}" -O "$ROOT"/Sources/Core/*.swift "$ROOT"/Sources/CLI/*.swift -o "$WORK/flashlabel-check"

echo "== compile and run unit tests"
"${SWIFTC[@]}" "$ROOT"/Sources/Core/*.swift "$ROOT"/tests/UnitTests.swift -o "$WORK/unit-tests"
"$WORK/unit-tests"

echo "== end-to-end dry runs through ./flashlabel"
"$WORK/unit-tests" --make-fixtures "$WORK/fixtures" >/dev/null
FL="$ROOT/flashlabel"

expect_size() {  # file, bytes
  local got
  got=$(stat -f %z "$1")
  [[ "$got" == "$2" ]] || { echo "FAIL: $1 is $got bytes, expected $2"; exit 1; }
}

out=$("$FL" print "$WORK/fixtures/label-letter.pdf" --dry-run --preview "$WORK/letter.png" --out-tspl "$WORK/letter.bin")
echo "$out"
grep -q "crop auto" <<<"$out" || { echo "FAIL: letter page was not auto-cropped"; exit 1; }
grep -q "rotate 90" <<<"$out" || { echo "FAIL: letter label was not rotated"; exit 1; }
grep -q "Dry run: nothing sent." <<<"$out" || { echo "FAIL: dry run banner missing"; exit 1; }
expect_size "$WORK/letter.bin" 120125
[[ -s "$WORK/letter.png" ]] || { echo "FAIL: preview missing"; exit 1; }
head -c 19 "$WORK/letter.bin" | grep -q "SIZE 100 mm,150 mm" || { echo "FAIL: TSPL header"; exit 1; }
tail -c 13 "$WORK/letter.bin" | grep -q "PRINT 1,1" || { echo "FAIL: TSPL trailer"; exit 1; }

out=$("$FL" "$WORK/fixtures/label-4x6.pdf" --dry-run --out-tspl "$WORK/4x6.bin")
grep -q "rotate 0" <<<"$out" || { echo "FAIL: 4x6 shorthand"; exit 1; }
expect_size "$WORK/4x6.bin" 120125
out=$("$FL" "$WORK/fixtures/label-landscape.png" --dry-run)
grep -q "rotate 90" <<<"$out" || { echo "FAIL: png"; exit 1; }
out=$("$FL" "$WORK/4x6.bin" --dry-run --preview "$WORK/raw.png")
grep -q "raw TSPL job, 120125 bytes, bitmap 800x1200 dots, PRINT 1" <<<"$out" || { echo "FAIL: raw"; exit 1; }
[[ -s "$WORK/raw.png" ]] || { echo "FAIL: raw preview missing"; exit 1; }

set +e
"$FL" print --dry-run >/dev/null 2>&1; [[ $? == 1 ]] || { echo "FAIL: missing file should exit 1"; exit 1; }
"$FL" "$WORK/nope.pdf" --dry-run >/dev/null 2>&1; [[ $? == 2 ]] || { echo "FAIL: missing input should exit 2"; exit 1; }
set -e
"$FL" --help >/dev/null

echo "== all tests passed"
