#!/bin/bash
# Static guard for near-final presentation memory behavior. Runtime reclamation
# is validated separately by perf-ui-memory-check.sh on a real Apple-Silicon Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
windows="$(mktemp "${TMPDIR:-/tmp}/helios-windows.XXXXXX")"
trap 'rm -f "$windows"' EXIT
# The window code lives in Sources/HeliosApp/Windows; read it as one text in its former file order.
for name in HeliosWindowCoordinator HeliosEnergyInspector HeliosSettings HeliosOnboarding HeliosWindowChrome; do
  cat "Sources/HeliosApp/Windows/$name.swift" >> "$windows"
done
status="Sources/HeliosApp/StatusItemController.swift"
icons="Sources/HeliosApp/V2/HeliosAppIcon.swift"

grep -q 'detachPresentationTree(from: window)' "$windows"
grep -q 'window.contentViewController = nil' "$windows"
grep -q 'window.contentView = NSView(frame: .zero)' "$windows"
grep -q 'controller?.window = nil' "$windows"
grep -q 'energyInspectorState.clearDerivedCache()' "$windows"
grep -q 'popover.contentViewController = nil' "$status"
grep -q 'cache.countLimit = 64' "$icons"
grep -q 'cache.totalCostLimit = 64 \* Self.approximateCost' "$icons"
grep -q 'func purge() { cache.removeAllObjects() }' "$icons"
grep -q 'HeliosAppIconCache.shared.purge()' "$windows"
grep -q 'HeliosAppIconCache.shared.purge()' "$status"

# "All readings" reflects the whole snapshot only while it is open and drops the rows on close.
readings="Sources/HeliosApp/V2/HeliosAllReadings.swift"
grep -Fq 'if open { capture() } else { groups = [] }' "$readings"
grep -Fq '@State private var expanded = false' "$readings"

printf '%s\n' 'PASS RC3 UI memory policy: All readings is built only while open, app icons are bounded raster thumbnails, and closed windows/popovers detach reconstructible presentation state'
