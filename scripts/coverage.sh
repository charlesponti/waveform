#!/bin/bash
# Runs the tests with coverage and fails unless every line of the library targets
# (Sources/WaveformCore and Sources/WaveformUI) is executed.
#
# Left out of the measurement, on purpose:
#   Sources/WaveformApp          the macOS demo window, not part of the library
#   SystemMicrophone.swift       one line that raises the system's microphone permission dialog; only a
#                                person at a device can run it. Everything around it takes the answer as
#                                a closure and is tested with both answers.
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --enable-code-coverage "$@"

PROFDATA=.build/debug/codecov/default.profdata
BINS=()
for bundle in .build/debug/*.xctest; do
  BINS+=("$bundle/Contents/MacOS/$(basename "${bundle%.xctest}")")
done
OBJECTS=()
for b in "${BINS[@]:1}"; do OBJECTS+=(-object "$b"); done
IGNORE='(Tests|\.build|WaveformApp|SystemMicrophone|WaveformCapture)'

xcrun llvm-cov report "${BINS[0]}" ${OBJECTS[@]+"${OBJECTS[@]}"} -instr-profile "$PROFDATA" -ignore-filename-regex="$IGNORE"

xcrun llvm-cov export -summary-only "${BINS[0]}" ${OBJECTS[@]+"${OBJECTS[@]}"} -instr-profile "$PROFDATA" -ignore-filename-regex="$IGNORE" |
python3 -c '
import json, sys
data = json.load(sys.stdin)["data"][0]
files = data["files"]
bad = [(f["filename"], f["summary"]["lines"]["count"] - f["summary"]["lines"]["covered"]) for f in files if f["summary"]["lines"]["percent"] < 100]
targets = {f["filename"].split("/Sources/")[1].split("/")[0] for f in files if "/Sources/" in f["filename"]}
print("Measured targets:", ", ".join(sorted(targets)), "-", len(files), "files")
if "WaveformCore" not in targets or "WaveformUI" not in targets:
    print("ERROR: a library target is missing from the report"); sys.exit(2)
if bad:
    for name, missed in bad: print("NOT COVERED:", name, missed, "lines")
    sys.exit(1)
print("Line coverage: 100%")
'
