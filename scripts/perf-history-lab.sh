#!/bin/bash
# Offline history-store lab: generates a realistic app-energy history file in a
# scratch directory and measures load footprint/peak and compaction cost with the
# real store code. Never touches ~/Library/Application Support/Helios.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TMPDIR:?Set TMPDIR to a scratch directory}"
workdir="$(mktemp -d "${TMPDIR%/}/helios-history-lab.XXXXXX")"
mkdir -p "$workdir/ModuleCache"
xcrun swiftc -O -wmo -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$workdir/ModuleCache" \
  -framework AppKit -framework IOKit -framework SystemConfiguration -framework CoreWLAN \
  -framework CoreGraphics -framework IOBluetooth -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/MetricValue.swift Sources/Shared/SMCClient.swift Sources/Shared/FanModels.swift \
  Sources/Shared/FanOwnershipPreflight.swift Sources/HeliosApp/Telemetry/*.swift Tests/HistoryStoreLab.swift \
  -o "$workdir/HistoryStoreLab"
buckets="${1:-10080}"; apps="${2:-32}"
"$workdir/HistoryStoreLab" "$workdir/data" "$buckets" "$apps"
HELIOS_LAB_LOAD_ONLY=1 "$workdir/HistoryStoreLab" "$workdir/data" "$buckets" "$apps"
rm -rf "$workdir"
