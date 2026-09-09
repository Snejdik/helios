#!/bin/bash
# Static guard for near-final presentation memory behavior. Runtime reclamation
# is validated separately by perf-ui-memory-check.sh on a real Apple-Silicon Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
windows="Sources/HeliosApp/HeliosWindows.swift"
status="Sources/HeliosApp/StatusItemController.swift"
icons="Sources/HeliosApp/HeliosMetricPopovers.swift"

grep -q 'detachPresentationTree(from: window)' "$windows"
grep -q 'window.contentViewController = nil' "$windows"
grep -q 'window.contentView = NSView(frame: .zero)' "$windows"
grep -q 'controller?.window = nil' "$windows"
grep -q 'energyInspectorState.clearDerivedCache()' "$windows"
grep -q 'private let content: () -> Content' "$windows"
grep -q '@ViewBuilder content: @escaping () -> Content' "$windows"
grep -q 'popover.contentViewController = nil' "$status"
grep -q 'cache.countLimit = 64' "$icons"
grep -q 'cache.totalCostLimit = 64 \* Self.approximateCost' "$icons"
grep -q 'func purge() { cache.removeAllObjects() }' "$icons"
grep -q 'HeliosAppIconCache.shared.purge()' "$windows"
grep -q 'HeliosAppIconCache.shared.purge()' "$status"

# Compile the actual disclosure implementation and exercise both branches.
# Searching for a stored closure alone missed RC3's uncalled-content build bug.
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/helios-lazy-panel.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
printf 'import AppKit\nimport SwiftUI\n' > "$probe_dir/Probe.swift"
sed -n '/^private struct HeliosDiagnosticDisclosurePanel</,/^}/p' "$windows" >> "$probe_dir/Probe.swift"
cat >> "$probe_dir/Probe.swift" <<'SWIFT'
@main
@MainActor
struct LazyPanelProbe {
  static func main() {
    var constructions = 0
    let collapsed = HeliosDiagnosticDisclosurePanel(title: "Test", symbol: "info.circle") {
      constructions += 1
      return Text("Diagnostic content")
    }
    _ = collapsed.body
    precondition(constructions == 0, "Collapsed diagnostics constructed their content")
    let expanded = HeliosDiagnosticDisclosurePanel(
      title: "Test", symbol: "info.circle", defaultExpanded: true
    ) {
      constructions += 1
      return Text("Diagnostic content")
    }
    _ = expanded.body
    precondition(constructions == 1, "Expanded diagnostics must build their content")
  }
}
SWIFT
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$probe_dir/Probe.swift" -o "$probe_dir/Probe"
"$probe_dir/Probe"

printf '%s\n' 'PASS RC3 UI memory policy: collapsed diagnostics build content lazily, app icons are bounded raster thumbnails, and closed windows/popovers detach reconstructible presentation state'
