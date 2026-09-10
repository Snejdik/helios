#!/bin/bash
# Small portable Swift semantic probe for the UI preferences model.
# It intentionally avoids AppKit/SwiftUI/Combine so initialization/type errors
# fail in seconds before the broader native presentation build.
set -euo pipefail
cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/helios-prefs.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
probe="$tmpdir/PreferencesProbe.swift"

cat > "$probe" <<'SWIFT'
import Foundation

@propertyWrapper
struct Published<Value> {
  var wrappedValue: Value
  init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

final class ObservableObjectPublisher {
  func send() {}
}

protocol ObservableObject {}
extension ObservableObject {
  var objectWillChange: ObservableObjectPublisher { ObservableObjectPublisher() }
}

enum HeliosMonitorRoute: String, CaseIterable, Identifiable, Sendable {
  case overview, cpu, memory, gpu, thermals, battery, energy, storage, network, processes, history, health,
    system, devices, maintenance, expert
  var id: String { rawValue }
}
SWIFT

# Compile the real preferences implementation, replacing only the Combine import
# with the tiny stubs above. This preserves the initializer and persistence code
# exactly, including Swift definite-initialization checking.
sed '/^import Foundation$/d' Sources/HeliosApp/Telemetry/TelemetryCollectionPolicy.swift >> "$probe"

sed '/^import Combine$/d; /^import Foundation$/d' Sources/HeliosApp/HeliosPreferences.swift >> "$probe"

cat >> "$probe" <<'SWIFT'

@main
struct PreferencesProbe {
  static func main() {
    let suite = "Helios.PreferencesPortable.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { fatalError("isolated defaults unavailable") }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let fresh = HeliosPreferences(defaults: defaults)
    precondition(fresh.menuBarMetrics == [.cpu, .temperature])
    precondition(fresh.menuBarLayout == .nativeModules && fresh.showMenuBarHub)
    precondition(fresh.graphLineStyle == .smooth && fresh.animateGraphUpdates)
    precondition(!fresh.memoryGaugeShowsAvailable)
    precondition(fresh.dashboardMetrics == HeliosPreferences.simpleDashboardMetrics)
    precondition(!fresh.detailedMonitorContent)
    precondition(fresh.menuBarSpacing == 2)
    precondition(HeliosMenuBarMetric.cpu.statusWidth == HeliosMenuBarMetric.memory.statusWidth)
    precondition(HeliosMenuBarMetric.cpu.statusWidth == HeliosMenuBarMetric.temperature.statusWidth)
    precondition(fresh.coolingFeaturesEnabled)
    precondition(fresh.telemetryModules == HeliosPreferences.simpleTelemetryModules)
    precondition(!fresh.fanSafetyGuideCompleted)
    precondition(fresh.colorHex(for: .cpu) == HeliosColorRole.cpu.defaultHex)
    precondition(fresh.colorHex(for: .swap) == HeliosColorRole.swap.defaultHex)
    precondition(HeliosGraphScope.allCases.allSatisfy { fresh.graphRange(for: $0) == .fiveMinutes })
    let freshCPU = fresh.menuBarContent(for: .cpu)
    precondition(!freshCPU.showIcon && freshCPU.showLabel && freshCPU.showValue)

    // Persisted preferences from a development build must never make a
    // menu-bar-only app unreachable. Empty native modules force the hub on.
    defaults.set([], forKey: "next23.ui.menuBarMetrics")
    defaults.set(HeliosMenuBarLayout.nativeModules.rawValue, forKey: "next23.ui8.menuBarLayout")
    defaults.set(false, forKey: "next23.ui8.menuBarHub")
    let recovered = HeliosPreferences(defaults: defaults)
    precondition(recovered.menuBarMetrics.isEmpty && recovered.showMenuBarHub)
    recovered.setMenuBarHubVisible(false)
    precondition(recovered.showMenuBarHub)

    recovered.setEnabled(.memory, enabled: true)
    recovered.setMenuBarHubVisible(false)
    precondition(!recovered.showMenuBarHub)
    recovered.setIdentityStyle(.symbol, for: .memory)
    recovered.setLabel("MEM", for: .memory)
    recovered.setGraphRange(.sixHours, for: .memory)
    let reload = HeliosPreferences(defaults: defaults)
    precondition(reload.menuBarMetrics == [.memory])
    precondition(!reload.showMenuBarHub)
    precondition(reload.identityStyle(for: .memory) == .symbol && reload.label(for: .memory) == "MEM")
    precondition(reload.graphRange(for: .memory) == .sixHours)
    var memoryContent = reload.menuBarContent(for: .memory)
    precondition(memoryContent.showIcon && !memoryContent.showLabel && memoryContent.showValue)

    reload.memoryGaugeShowsAvailable = true
    let memoryGaugeReload = HeliosPreferences(defaults: defaults)
    precondition(memoryGaugeReload.memoryGaugeShowsAvailable)

    reload.setMenuBarLabelVisible(true, for: .memory)
    reload.setMenuBarValueVisible(false, for: .memory)
    let contentReload = HeliosPreferences(defaults: defaults)
    memoryContent = contentReload.menuBarContent(for: .memory)
    precondition(memoryContent.showIcon && memoryContent.showLabel && !memoryContent.showValue)

    // Never allow an invisible status item: turning the final visible identity
    // off recovers to a value-only module and persists that normalized state.
    contentReload.setMenuBarIconVisible(false, for: .memory)
    contentReload.setMenuBarLabelVisible(false, for: .memory)
    let normalizedReload = HeliosPreferences(defaults: defaults)
    memoryContent = normalizedReload.menuBarContent(for: .memory)
    precondition(!memoryContent.showIcon && !memoryContent.showLabel && memoryContent.showValue)

    normalizedReload.setEnabled(.memory, enabled: false)
    precondition(normalizedReload.menuBarMetrics.isEmpty && normalizedReload.showMenuBarHub)

    let customSuite = "Helios.PreferencesCustom.\(UUID().uuidString)"
    guard let customDefaults = UserDefaults(suiteName: customSuite) else { fatalError("custom defaults unavailable") }
    customDefaults.removePersistentDomain(forName: customSuite)
    defer { customDefaults.removePersistentDomain(forName: customSuite) }
    let custom = HeliosPreferences(defaults: customDefaults)
    custom.completeOnboarding(with: .custom)
    precondition(custom.onboardingCompleted && custom.dashboardMode == .custom)
    precondition(custom.menuBarMetrics == [.cpu, .memory, .temperature, .power])
    precondition(custom.monitorRoutes == HeliosMonitorRoute.allCases)
    precondition(custom.popoverModules == HeliosPreferences.advancedPopoverModules)
    precondition(custom.dashboardMetrics == HeliosDashboardMetric.allCases)
    precondition(custom.detailedMonitorContent)
    custom.setColorHex("#123456FF", for: .cpu)
    custom.setDashboardMetricEnabled(.gpu, enabled: false)
    let customReload = HeliosPreferences(defaults: customDefaults)
    precondition(customReload.colorHex(for: .cpu) == "#123456FF")
    precondition(!customReload.isDashboardMetricEnabled(.gpu))
    precondition(customReload.detailedMonitorContent)
    precondition(customReload.telemetryModules == HeliosTelemetryModule.allCases)
    customReload.menuBarSpacing = 0.5
    customReload.completeFanSafetyGuide()
    let cpuMenuBefore = customReload.menuBarMetrics
    let cpuDashboardBefore = customReload.dashboardMetrics
    let cpuMonitorBefore = customReload.monitorRoutes
    customReload.setTelemetryModuleEnabled(.cpu, enabled: false)
    precondition(!customReload.isTelemetryEnabled(.cpu))
    precondition(customReload.menuBarMetrics == cpuMenuBefore)
    precondition(customReload.dashboardMetrics == cpuDashboardBefore)
    precondition(customReload.monitorRoutes == cpuMonitorBefore)
    precondition(!customReload.menuBarMetricsForPresentation.contains(.cpu))
    precondition(!customReload.dashboardMetricsForPresentation.contains(.cpu))
    precondition(!customReload.monitorRoutesForPresentation.contains(.cpu))
    customReload.setTelemetryModuleEnabled(.cpu, enabled: true)
    precondition(customReload.isTelemetryEnabled(.cpu))
    precondition(customReload.menuBarMetrics == cpuMenuBefore)
    precondition(customReload.dashboardMetrics == cpuDashboardBefore)
    precondition(customReload.monitorRoutes == cpuMonitorBefore)
    precondition(customReload.menuBarMetricsForPresentation.contains(.cpu))
    precondition(customReload.dashboardMetricsForPresentation.contains(.cpu))
    precondition(customReload.monitorRoutesForPresentation.contains(.cpu))

    let networkPopoverBefore = customReload.popoverModules
    let networkMonitorBefore = customReload.monitorRoutes
    customReload.setTelemetryModuleEnabled(.network, enabled: false)
    precondition(!customReload.isTelemetryEnabled(.network))
    precondition(customReload.popoverModules == networkPopoverBefore)
    precondition(customReload.monitorRoutes == networkMonitorBefore)
    precondition(!customReload.popoverModulesForPresentation.contains(.network))
    precondition(!customReload.monitorRoutesForPresentation.contains(.network))
    customReload.setTelemetryModuleEnabled(.network, enabled: true)
    precondition(customReload.isTelemetryEnabled(.network))
    precondition(customReload.popoverModules == networkPopoverBefore)
    precondition(customReload.monitorRoutes == networkMonitorBefore)
    precondition(customReload.popoverModulesForPresentation.contains(.network))
    precondition(customReload.monitorRoutesForPresentation.contains(.network))

    let telemetryBeforeDashboardReset = customReload.telemetryModules
    customReload.resetDashboard()
    precondition(customReload.dashboardMode == .custom)
    precondition(customReload.popoverModules == HeliosPreferences.advancedPopoverModules)
    precondition(customReload.dashboardMetrics == HeliosPreferences.advancedDashboardMetrics)
    precondition(customReload.telemetryModules == telemetryBeforeDashboardReset)

    customReload.setEnabled(.fan, enabled: true)
    let coolingMenuBefore = customReload.menuBarMetrics
    let coolingPopoverBefore = customReload.popoverModules
    customReload.setCoolingFeaturesEnabled(false)
    precondition(!customReload.coolingFeaturesEnabled)
    // Fan telemetry is independent/read-only and intentionally remains available
    // when helper-facing cooling controls are disabled.
    precondition(customReload.isTelemetryEnabled(.fans))
    precondition(customReload.menuBarMetrics == coolingMenuBefore)
    precondition(customReload.popoverModules == coolingPopoverBefore)
    precondition(customReload.menuBarMetricsForPresentation.contains(.fan))
    customReload.setCoolingFeaturesEnabled(true)
    precondition(customReload.coolingFeaturesEnabled)
    precondition(customReload.isTelemetryEnabled(.fans))
    precondition(customReload.menuBarMetrics == coolingMenuBefore)
    precondition(customReload.popoverModules == coolingPopoverBefore)
    precondition(customReload.menuBarMetricsForPresentation.contains(.fan))
    let modularReload = HeliosPreferences(defaults: customDefaults)
    precondition(modularReload.menuBarSpacing == 0.5)
    precondition(modularReload.fanSafetyGuideCompleted)
    precondition(modularReload.coolingFeaturesEnabled)
    precondition(modularReload.isTelemetryEnabled(.network))

    // Pre-UI10 persisted sidebars could not contain Energy. Schema migration
    // inserts it once without resetting the user's existing route order.
    let migrationSuite = "Helios.PreferencesMigration.\(UUID().uuidString)"
    guard let migrationDefaults = UserDefaults(suiteName: migrationSuite) else { fatalError("migration defaults unavailable") }
    migrationDefaults.removePersistentDomain(forName: migrationSuite)
    defer { migrationDefaults.removePersistentDomain(forName: migrationSuite) }
    migrationDefaults.set(["overview", "cpu", "battery", "history"], forKey: "next23.ui.monitorRoutes")
    migrationDefaults.set(10, forKey: "next23.ui.schemaVersion")
    let migrated = HeliosPreferences(defaults: migrationDefaults)
    precondition(migrated.monitorRoutes.contains(.energy))
    precondition(migrated.monitorRoutes.firstIndex(of: .energy) == (migrated.monitorRoutes.firstIndex(of: .battery) ?? 0) + 1)

    // RC1-RC3 schema 11 could destructively remove CPU from every presentation
    // surface when collection was toggled. RC4 repairs that one-time development
    // state from the still-enabled CPU sampler, persists the repair before bumping
    // schema, and leaves unrelated intentionally hidden routes alone.
    let rc3RepairSuite = "Helios.PreferencesRC3Repair.\(UUID().uuidString)"
    guard let rc3RepairDefaults = UserDefaults(suiteName: rc3RepairSuite) else { fatalError("RC3 repair defaults unavailable") }
    rc3RepairDefaults.removePersistentDomain(forName: rc3RepairSuite)
    defer { rc3RepairDefaults.removePersistentDomain(forName: rc3RepairSuite) }
    rc3RepairDefaults.set(["temperature"], forKey: "next23.ui.menuBarMetrics")
    rc3RepairDefaults.set(["temperature"], forKey: "next23.ui10.dashboardMetrics")
    rc3RepairDefaults.set(["summary", "system"], forKey: "next23.ui.popoverModules")
    rc3RepairDefaults.set(["cpu", "memory"], forKey: "next23.ui10.telemetryModules")
    rc3RepairDefaults.set(["overview", "memory", "battery", "history"], forKey: "next23.ui.monitorRoutes")
    rc3RepairDefaults.set(11, forKey: "next23.ui.schemaVersion")
    let rc3Repaired = HeliosPreferences(defaults: rc3RepairDefaults)
    precondition(rc3Repaired.monitorRoutes.contains(.cpu))
    precondition(!rc3Repaired.monitorRoutes.contains(.storage))
    let rc3RepairReload = HeliosPreferences(defaults: rc3RepairDefaults)
    precondition(rc3RepairReload.monitorRoutes.contains(.cpu))
    precondition(!rc3RepairReload.monitorRoutes.contains(.storage))

    let presetSuite = "Helios.PreferencesGlobalPreset.\(UUID().uuidString)"
    guard let presetDefaults = UserDefaults(suiteName: presetSuite) else { fatalError("preset defaults unavailable") }
    presetDefaults.removePersistentDomain(forName: presetSuite)
    defer { presetDefaults.removePersistentDomain(forName: presetSuite) }
    let preset = HeliosPreferences(defaults: presetDefaults)
    preset.applyInterfacePreset(.all)
    precondition(preset.dashboardMode == .all)
    precondition(preset.detailedMonitorContent)
    precondition(preset.telemetryModules == HeliosTelemetryModule.allCases)
    precondition(preset.dashboardMetrics == HeliosDashboardMetric.allCases)
    precondition(preset.monitorRoutes == HeliosMonitorRoute.allCases)
    precondition(preset.menuBarMetrics == [.cpu, .memory, .temperature, .power])
    preset.setTelemetryModuleEnabled(.network, enabled: false)
    precondition(preset.dashboardMode == .custom)
    preset.applyInterfacePreset(.simple)
    precondition(preset.dashboardMode == .simple)
    precondition(!preset.detailedMonitorContent)
    precondition(preset.telemetryModules == HeliosPreferences.simpleTelemetryModules)
    precondition(preset.monitorRoutes == [.overview, .cpu, .memory, .thermals, .battery])

    let detailedSuite = "Helios.PreferencesDetailed.\(UUID().uuidString)"
    guard let detailedDefaults = UserDefaults(suiteName: detailedSuite) else { fatalError("detailed defaults unavailable") }
    detailedDefaults.removePersistentDomain(forName: detailedSuite)
    defer { detailedDefaults.removePersistentDomain(forName: detailedSuite) }
    let detailed = HeliosPreferences(defaults: detailedDefaults)
    detailed.completeOnboarding(with: .all)
    precondition(detailed.dashboardMode == .all)
    precondition(detailed.detailedMonitorContent)
    precondition(detailed.dashboardMetrics == HeliosDashboardMetric.allCases)
    precondition(detailed.monitorRoutes == HeliosMonitorRoute.allCases)

  }
}
SWIFT

output="$tmpdir/PreferencesProbe"
if command -v swiftc >/dev/null 2>&1; then
  swiftc -parse-as-library -swift-version 6 -warnings-as-errors "$probe" -o "$output"
elif command -v xcrun >/dev/null 2>&1; then
  xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors "$probe" -o "$output"
else
  echo "FAIL: Swift compiler unavailable for preferences semantic probe" >&2
  exit 1
fi
"$output"

printf '%s\n' "PASS Next23 preferences semantic probe: definite initialization, menu-bar reachability, reversible collection regeneration across menu/dashboard/monitor surfaces, cooling gates, spacing, migration, dashboard/color/density persistence, presets, and warnings-as-errors"
