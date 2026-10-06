#!/bin/bash
# Offline renderer for the Helios 0.2 interface: deterministic fixtures → PNG.
# Builds a plain command-line binary from the app sources minus the app entry
# point. Never launches Helios, never constructs DaemonService/TelemetryMonitor,
# never contacts the helper and never reads SMC. Output defaults to TMPDIR.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TMPDIR:?Set TMPDIR to a scratch directory}"
workdir="$(mktemp -d "${TMPDIR%/}/helios-ui-render.XXXXXX")"
output="${1:-$workdir/images}"
shift || true
mkdir -p "$workdir/ModuleCache"
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
  find Sources/HeliosApp -name '*.swift' ! -name 'HeliosApp.swift' | sort)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$workdir/ModuleCache" -parse-as-library \
  -framework AppKit -framework SwiftUI -framework IOKit -framework Security -framework ServiceManagement \
  -framework SystemConfiguration -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth \
  -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/*.swift "${sources[@]}" \
  Tests/Fixtures/UIFixtureCatalog.swift Tests/UIRenderChecks.swift -o "$workdir/UIRenderChecks"
"$workdir/UIRenderChecks" "$output" "$@"
echo "Images: $output"
