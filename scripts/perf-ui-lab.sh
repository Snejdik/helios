#!/bin/bash
# Offline UI performance lab (see Tests/UIPerformanceLab.swift). Builds an
# optimized command-line binary from the app sources minus the app entry point
# and measures CPU time and physical footprint per UI state with full-size
# synthetic histories. Never launches Helios, never contacts the helper, never
# reads SMC. Windows are ordered in far off-screen.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TMPDIR:?Set TMPDIR to a scratch directory}"
workdir="$(mktemp -d "${TMPDIR%/}/helios-ui-lab.XXXXXX")"
mkdir -p "$workdir/ModuleCache"
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
  find Sources/HeliosApp -name '*.swift' ! -name 'HeliosApp.swift' | sort)
xcrun swiftc -O -wmo -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$workdir/ModuleCache" -parse-as-library \
  -framework AppKit -framework SwiftUI -framework IOKit -framework Security -framework ServiceManagement \
  -framework SystemConfiguration -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth \
  -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/*.swift "${sources[@]}" \
  Tests/Fixtures/UIFixtureCatalog.swift Tests/UIPerformanceLab.swift -o "$workdir/UIPerformanceLab"
echo "Binary: $workdir/UIPerformanceLab"
exec "$workdir/UIPerformanceLab" "$@"
