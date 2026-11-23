#!/bin/bash
# Runs the bridge check on this Mac: the lookups in scripts/bridge-check.txt through the
# bridge's C interface with no model, as the Windows app would make them. `--update` writes
# scripts/bridge-check-expected.txt, which the Windows build's run must match.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product LongyanBridge >/dev/null
out=.build/bridge-check
mkdir -p "$out"
fw=$(find Vendor/llama.xcframework -maxdepth 2 -path "*macos-arm64*" -type d | head -1)
clang Tests/bridge/check.c -I.build -L.build/release -lLongyanBridge -Wl,-rpath,"$PWD/.build/release" -Wl,-rpath,"$PWD/$fw" -o "$out/check"
scripts/stage-windows-resources.sh "$out/Resources" >/dev/null
"$out/check" "$out/Resources" scripts/bridge-check.txt 2>/dev/null | python3 scripts/bridge-normalize.py > "$out/actual.txt"
if [ "${1:-}" = "--update" ]; then cp "$out/actual.txt" scripts/bridge-check-expected.txt; echo "updated"; exit 0; fi
diff scripts/bridge-check-expected.txt "$out/actual.txt" && echo "bridge check: same as expected"
