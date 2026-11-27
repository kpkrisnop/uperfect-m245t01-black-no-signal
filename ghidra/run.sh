#!/bin/sh
# Split a COPY of the dump into 64K bank images and run headless Ghidra on each.
# Project lives in $PROJ (default /tmp-like, outside Google Drive: Ghidra DB + cloud sync don't mix).
set -e
G="$(cd "$(dirname "$0")" && pwd)"
PROJ="${PROJ:-${TMPDIR:-/tmp}/m245t01-ghidra}"
mkdir -p "$G/banks" "$G/out" "$PROJ"
for b in 0 1 2 3 4 5 6 7 8 9 11; do
  dd if="${DUMP:-$G/../tools/firmware/dump-a.bin}" of="$G/banks/bank$b.bin" bs=65536 skip=$b count=1 2>/dev/null
  /opt/homebrew/opt/ghidra/libexec/support/analyzeHeadless "$PROJ" m245t01 \
    -import "$G/banks/bank$b.bin" -overwrite -processor 8051:BE:16:default \
    -loader BinaryLoader -loader-baseAddr CODE:0000 \
    -scriptPath "$G" -preScript Setup.java $b -postScript Dump.java $b >"$G/out/bank$b.log" 2>&1
  echo "bank $b: $(grep -c '^== ' "$G/out/bank$b.asm") funcs"
done
