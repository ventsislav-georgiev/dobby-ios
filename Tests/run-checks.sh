set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)/api-scheme-check"
xcrun swiftc -o "$OUT" \
  Dobby/AppConfig.swift Dobby/Web/ApiSchemeHandler.swift Tests/ApiSchemeHandlerCheck.swift
"$OUT"

# ServerAddresses.swift is compiled twice: OUT2 without -D DEBUG so the file still compiles
# clean in release configuration (the noServerSeamActive() predicate itself is unconditional,
# only its call site in probe(_:) is #if DEBUG-gated), and OUT3 with -D DEBUG so the
# --expect-no-server run below can actually exercise the guarded call site.
OUT2="$(mktemp -d)/server-addresses-check"
xcrun swiftc -o "$OUT2" \
  Dobby/ServerAddresses.swift Dobby/AppConfig.swift Tests/ServerAddressesCheck.swift
"$OUT2"

OUT3="$(mktemp -d)/server-addresses-check-debug"
xcrun swiftc -D DEBUG -o "$OUT3" \
  Dobby/ServerAddresses.swift Dobby/AppConfig.swift Tests/ServerAddressesCheck.swift
DOBBY_NO_SERVER=1 "$OUT3" --expect-no-server

# Compile-time property with no runtime observable: resolve() reports the same "absent" verdict
# whether the seam call is #if DEBUG-gated or unconditional, and the reason string only reaches
# OSLog, so no assertion above this line can distinguish a shipped guard from a shipped hole.
# A textual check over the source is the only tool that can catch the call site losing its
# DEBUG gate (or a second, ungated call being added elsewhere).
python3 - <<'PY'
import re
import sys

path = "Dobby/ServerAddresses.swift"
with open(path) as f:
    lines = f.readlines()

calls = [i for i, l in enumerate(lines) if "noServerSeamActive()" in l and "func noServerSeamActive" not in l]
if len(calls) != 1:
    sys.stderr.write(f"FAIL: expected exactly one call to noServerSeamActive() outside its declaration, found {len(calls)}\n")
    sys.exit(1)

call_idx = calls[0]

def nearest_nonblank(idx, step):
    i = idx + step
    while 0 <= i < len(lines):
        stripped = lines[i].strip()
        if stripped:
            return stripped
        i += step
    return None

above = nearest_nonblank(call_idx, -1)
below = nearest_nonblank(call_idx, 1)

if above != "#if DEBUG" or below != "#endif":
    sys.stderr.write("FAIL: noServerSeamActive() call site is not #if DEBUG-gated\n")
    sys.exit(1)

print("PASS: noServerSeamActive() call site is #if DEBUG-gated")
PY
