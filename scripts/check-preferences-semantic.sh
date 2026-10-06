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
sed '/^import Foundation$/d' Sources/HeliosApp/Telemetry/HealthAlertConfiguration.swift >> "$probe"

sed '/^import Combine$/d; /^import Foundation$/d' Sources/HeliosApp/HeliosPreferences.swift >> "$probe"
sed '/^import Foundation$/d' Sources/HeliosApp/V2/HeliosVocabulary.swift >> "$probe"
sed '/^import Foundation$/d' Sources/HeliosApp/V2/HeliosGoals.swift >> "$probe"
sed '/^import Combine$/d; /^import Foundation$/d' Sources/HeliosApp/V2/HeliosInterfacePreferences.swift >> "$probe"

cat >> "$probe" <<'SWIFT'

@main
struct PreferencesProbe {
  static func main() {
    let suite = "Helios.PreferencesPortable.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { fatalError("isolated defaults unavailable") }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let fresh = HeliosPreferences(defaults: defaults)
    precondition(fresh.healthAlerts == .defaults)
    fresh.setHealthAlert(.socHot, enabled: false, threshold: 88.5)
    let alertsReloaded = HeliosPreferences(defaults: defaults)
    precondition(!alertsReloaded.healthAlerts[.socHot].enabled)
    precondition(alertsReloaded.healthAlerts[.socHot].threshold == 88.5)
    precondition(alertsReloaded.healthAlerts[.socCritical].threshold == 95)
    fresh.restoreHealthAlertDefaults()
    precondition(HeliosPreferences(defaults: defaults).healthAlerts == .defaults)
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
    // Simple mode hides Storage, but enabled SSD alerts still use its canonical collector.
    precondition(!fresh.isTelemetryEnabled(.storage))
    precondition(fresh.isTelemetryCollectionRequired(.storage))
    for module in [HeliosTelemetryModule.memory, .battery, .storage] {
      fresh.setTelemetryModuleEnabled(module, enabled: false)
      precondition(!fresh.isTelemetryEnabled(module))
      precondition(fresh.isTelemetryCollectionRequired(module))
      for rule in HealthAlertRule.allCases where rule.collectionDependency == module {
        fresh.setHealthAlert(rule, enabled: false)
      }
      precondition(!fresh.isTelemetryCollectionRequired(module))
      for rule in HealthAlertRule.allCases where rule.collectionDependency == module {
        fresh.setHealthAlert(rule, enabled: true)
        precondition(fresh.isTelemetryCollectionRequired(module))
        precondition(!fresh.isTelemetryEnabled(module))
        fresh.setHealthAlert(rule, enabled: false)
      }
      fresh.setTelemetryModuleEnabled(module, enabled: true)
      precondition(fresh.isTelemetryCollectionRequired(module))
    }
    fresh.restoreHealthAlertDefaults()
    fresh.applyInterfacePreset(.simple)
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

    // Helios 0.2 interface preference: default Helios, persistent Legacy switch,
    // Overview never hidden, layout reset keeps the interface choice.
    let interfaceSuite = "Helios.PreferencesInterface.\(UUID().uuidString)"
    guard let interfaceDefaults = UserDefaults(suiteName: interfaceSuite) else { fatalError("interface defaults unavailable") }
    interfaceDefaults.removePersistentDomain(forName: interfaceSuite)
    defer { interfaceDefaults.removePersistentDomain(forName: interfaceSuite) }
    let firstRun = HeliosPreferences(defaults: interfaceDefaults)
    precondition(firstRun.interface.style == .helios)
    precondition(firstRun.interface.overviewChartMetric == nil)
    precondition(firstRun.interface.popoverSections == HeliosPopoverSection.defaults)
    precondition(firstRun.interface.visiblePages == HeliosPage.allCases)
    firstRun.interface.style = .legacy
    firstRun.interface.overviewChartMetric = .temperature
    firstRun.interface.setPage(.network, visible: false)
    firstRun.interface.setPage(.overview, visible: false)
    firstRun.interface.setPopoverSection(.cooling, enabled: false)
    firstRun.interface.setPopoverSection(.activity, enabled: true)
    firstRun.interface.movePopoverSection(.activity, by: -5)
    let reloadedInterface = HeliosPreferences(defaults: interfaceDefaults)
    precondition(reloadedInterface.interface.style == .legacy)
    precondition(reloadedInterface.interface.overviewChartMetric == .temperature)
    precondition(reloadedInterface.interface.hiddenPages == [.network])
    precondition(reloadedInterface.interface.visiblePages.first == .overview)
    precondition(reloadedInterface.interface.popoverSections == [.activity, .chart, .processes])
    interfaceDefaults.set(["chart", "chart", "bogus", "network"], forKey: HeliosInterfacePreferences.popoverSectionsKey)
    interfaceDefaults.set("bogus", forKey: HeliosInterfacePreferences.styleKey)
    interfaceDefaults.set(["overview", "nonsense"], forKey: HeliosInterfacePreferences.hiddenPagesKey)
    let sanitized = HeliosPreferences(defaults: interfaceDefaults)
    precondition(sanitized.interface.popoverSections == [.chart, .network])
    precondition(sanitized.interface.style == .helios)
    precondition(sanitized.interface.hiddenPages.isEmpty)
    sanitized.interface.style = .legacy
    sanitized.resetInterface()
    precondition(sanitized.interface.style == .legacy)
    precondition(sanitized.interface.popoverSections == HeliosPopoverSection.defaults)
    precondition(sanitized.interface.overviewChartMetric == nil)
    precondition(HeliosPreferences(defaults: interfaceDefaults).interface.overviewChartMetric == nil)

    // Temperature unit: display only, Celsius by default, persisted, bogus values ignored.
    let unitSuite = "Helios.PreferencesUnit.\(UUID().uuidString)"
    guard let unitDefaults = UserDefaults(suiteName: unitSuite) else { fatalError("unit defaults unavailable") }
    defer { unitDefaults.removePersistentDomain(forName: unitSuite) }
    let unitFirst = HeliosPreferences(defaults: unitDefaults)
    precondition(unitFirst.temperatureUnit == .celsius && TemperatureUnit.current == .celsius)
    unitFirst.temperatureUnit = .fahrenheit
    precondition(TemperatureUnit.current == .fahrenheit)
    precondition(TemperatureUnit.fahrenheit.format(50) == "122°F" && TemperatureUnit.celsius.format(50) == "50°C")
    precondition(TemperatureUnit.fahrenheit.format(-10, decimals: 1) == "14.0°F")
    precondition(TemperatureUnit.celsius.format(.nan) == "—" && TemperatureUnit.fahrenheit.format(.infinity) == "—")
    precondition(HeliosPreferences(defaults: unitDefaults).temperatureUnit == .fahrenheit)
    unitDefaults.set("kelvin", forKey: "v2.ui.temperatureUnit")
    precondition(HeliosPreferences(defaults: unitDefaults).temperatureUnit == .celsius)
    unitFirst.temperatureUnit = .celsius

    // Welcome goals: pure plan, union, persistence and effect on every surface.
    let emptyPlan = HeliosGoalPlan.make(for: [])
    precondition(emptyPlan == HeliosGoalPlan.make(for: [.simple]))
    precondition(Set(emptyPlan.samplers) == HeliosGoalPlan.baseSamplers)
    precondition(emptyPlan.menuBarMetrics.isEmpty && emptyPlan.popoverSections == [.chart])
    precondition(!emptyPlan.wantsFanHelper && !emptyPlan.visiblePages.contains(.history))
    let coolPlan = HeliosGoalPlan.make(for: [.cooling])
    precondition(coolPlan.wantsFanHelper && coolPlan.samplers.contains(.fans))
    precondition(coolPlan.menuBarMetrics == [.temperature] && coolPlan.popoverSections.contains(.cooling))
    // The welcome's recommendation is the owner's bar: CPU, RAM, TEMP, PWR (+ cooling when a fan exists).
    let withFan = HeliosMacTraits(hasFans: true, hasBattery: true)
    let fanless = HeliosMacTraits(hasFans: false, hasBattery: true)
    let desktop = HeliosMacTraits(hasFans: true, hasBattery: false)
    precondition(HeliosGoalPlan.recommendedGoals(for: withFan) == [.liveStats, .cooling])
    precondition(HeliosGoalPlan.recommendedGoals(for: fanless) == [.liveStats])
    precondition(HeliosGoalPlan.recommendedGoals(for: .unknown) == [.liveStats])
    let recommended = HeliosGoalPlan.make(for: HeliosGoalPlan.recommendedGoals(for: withFan), traits: withFan)
    // With a fan the temperature item carries the fan state above it; without one it is plain TEMP.
    precondition(recommended.menuBarMetrics == [.cpu, .memory, .cooling, .power])
    precondition(recommended.wantsFanHelper)
    precondition(HeliosGoalPlan.make(for: [.liveStats], traits: fanless).menuBarMetrics == [.cpu, .memory, .temperature, .power])
    precondition(HeliosGoalPlan.make(for: [.liveStats], traits: .unknown).menuBarMetrics == [.cpu, .memory, .temperature, .power])
    // A Mac without a fan never gets the cooling goal or the helper step; a desktop never gets battery.
    let fanlessPlan = HeliosGoalPlan.make(for: [.cooling, .liveStats], traits: fanless)
    precondition(!fanlessPlan.wantsFanHelper && !fanlessPlan.samplers.contains(.fans) && !fanlessPlan.popoverSections.contains(.cooling))
    precondition(!HeliosGoal.available(on: fanless).contains(.cooling) && HeliosGoal.available(on: fanless).contains(.battery))
    precondition(!HeliosGoal.available(on: desktop).contains(.battery) && HeliosGoal.available(on: desktop).contains(.cooling))
    precondition(HeliosGoalPlan.make(for: [.battery], traits: desktop) == HeliosGoalPlan.make(for: [.simple], traits: desktop))
    precondition(HeliosGoal.available(on: .unknown).count == HeliosGoal.allCases.count)
    precondition(coolPlan.visiblePages.contains(.hardware) && !coolPlan.visiblePages.contains(.network))
    let combined = HeliosGoalPlan.make(for: [.battery, .network, .liveStats])
    precondition(combined.samplers.contains(.processes) && combined.samplers.contains(.wifi))
    precondition(combined.menuBarMetrics.count <= HeliosGoalPlan.maximumMenuBarMetrics)
    precondition(combined.visiblePages.contains(.network) && combined.visiblePages.contains(.history))
    precondition(combined.samplers == HeliosTelemetryModule.allCases.filter(Set(combined.samplers).contains))
    for goals in [Set<HeliosGoal>(), [.simple], [.cooling], [.storage], Set(HeliosGoal.allCases)] {
      let plan = HeliosGoalPlan.make(for: goals)
      precondition(HeliosGoalPlan.baseSamplers.isSubset(of: Set(plan.samplers)))
      precondition(plan.visiblePages.contains(.overview) && plan.visiblePages.contains(.diagnostics))
      for area in [HeliosPage.cpu, .gpu, .memory, .thermals, .battery, .storage] {
        precondition(plan.visiblePages.contains(area))
      }
    }
    let goalSuite = "Helios.PreferencesGoals.\(UUID().uuidString)"
    guard let goalDefaults = UserDefaults(suiteName: goalSuite) else { fatalError("goal defaults unavailable") }
    goalDefaults.removePersistentDomain(forName: goalSuite)
    defer { goalDefaults.removePersistentDomain(forName: goalSuite) }
    let goalPreferences = HeliosPreferences(defaults: goalDefaults)
    goalPreferences.completeOnboarding(goals: [.battery])
    let batteryPlan = HeliosGoalPlan.make(for: [.battery])
    precondition(goalPreferences.onboardingCompleted)
    precondition(goalPreferences.telemetryModules == batteryPlan.samplers)
    precondition(goalPreferences.menuBarMetrics == [.battery])
    precondition(goalPreferences.interface.popoverSections == batteryPlan.popoverSections)
    precondition(goalPreferences.interface.goals == [.battery])
    precondition(goalPreferences.interface.hiddenPages.contains(.network))
    precondition(!goalPreferences.interface.hiddenPages.contains(.overview))
    let goalReloaded = HeliosPreferences(defaults: goalDefaults)
    precondition(goalReloaded.interface.goals == [.battery])
    precondition(goalReloaded.telemetryModules == batteryPlan.samplers)
    precondition(goalReloaded.menuBarMetrics == [.battery])
    goalPreferences.applyGoals([])
    precondition(goalPreferences.menuBarMetrics.isEmpty && goalPreferences.showMenuBarHub)
    precondition(HeliosPreferences(defaults: goalDefaults).menuBarMetrics.isEmpty)

    // Diagnostics reminder: a calm, permanent-dismiss nudge one week after first use.
    let reminderSuite = "Helios.PreferencesReminder.\(UUID().uuidString)"
    guard let reminderDefaults = UserDefaults(suiteName: reminderSuite) else { fatalError("reminder defaults unavailable") }
    reminderDefaults.removePersistentDomain(forName: reminderSuite)
    defer { reminderDefaults.removePersistentDomain(forName: reminderSuite) }
    let reminderPreferences = HeliosPreferences(defaults: reminderDefaults)
    let firstSeen = reminderPreferences.interface.firstSeen
    let day: TimeInterval = 86_400
    precondition(!reminderPreferences.interface.shouldShowDiagnosticsReminder(
      sharingDiagnostics: false, now: firstSeen.addingTimeInterval(6 * day)))
    precondition(reminderPreferences.interface.shouldShowDiagnosticsReminder(
      sharingDiagnostics: false, now: firstSeen.addingTimeInterval(7 * day)))
    precondition(!reminderPreferences.interface.shouldShowDiagnosticsReminder(
      sharingDiagnostics: true, now: firstSeen.addingTimeInterval(30 * day)))
    reminderPreferences.interface.dismissDiagnosticsReminder()
    precondition(!reminderPreferences.interface.shouldShowDiagnosticsReminder(
      sharingDiagnostics: false, now: firstSeen.addingTimeInterval(30 * day)))
    let reminderReloaded = HeliosPreferences(defaults: reminderDefaults)
    precondition(reminderReloaded.interface.firstSeen == firstSeen)
    precondition(reminderReloaded.interface.diagnosticsReminderDismissed)
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

printf '%s\n' "PASS Next23 preferences semantic probe: definite initialization, menu-bar reachability, reversible collection regeneration across menu/dashboard/monitor surfaces, cooling gates, spacing, migration, dashboard/color/density persistence, presets, Helios/Legacy interface preference, welcome goals, and warnings-as-errors"
