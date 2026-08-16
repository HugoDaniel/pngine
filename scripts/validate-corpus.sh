#!/bin/bash
# Validate every hand-authored example through `pngine validate`.
#
# This is the corpus false-positive gate for the semantic-validation work
# (R1–R5, journal §153+): every real example is valid WebGPU, so a new
# SJON↔WGSL / SJON↔SJON check that rejects one of these is a FALSE POSITIVE,
# not a catch. Run this after adding or tightening any validation check.
#
# Covers examples/*.sjon + examples/samples/*.sjon only. examples/invalid/*
# is deliberately excluded — those fixtures are MEANT to fail (they live in
# tests/zig/sjon_invalid.zig, not here).
#
# Exit codes: 0 = all clean, 1 = a file failed validation, 2 = build failed.
set -u

CLI=./zig-out/bin/pngine

echo "==> Building CLI..."
zig build || { echo "BUILD FAILED"; exit 2; }

echo "==> Validating corpus (examples/*.sjon + examples/samples/*.sjon)..."
pass=0
fail=0
failed=()
for f in examples/*.sjon examples/samples/*.sjon; do
  if out=$("$CLI" validate "$f" 2>&1); then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed+=("$f")
    echo "  FAIL: $f"
    echo "$out" | sed 's/^/      /'
  fi
done

total=$((pass + fail))
echo "==> $pass/$total validated"
if [ "$fail" -ne 0 ]; then
  echo "==> $fail file(s) failed:"
  for f in "${failed[@]}"; do echo "    $f"; done
  exit 1
fi
echo "==> corpus clean"
