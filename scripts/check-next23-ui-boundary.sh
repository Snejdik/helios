#!/bin/bash
# Next23 must remain a presentation/settings rewrite over the validated Next22
# functional freeze. Fail if the protected fan-control/battery boundary changes.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
while read -r expected path; do
  [ -n "$expected" ] || continue
  if [ ! -f "$path" ]; then
    echo "FAIL protected Next22 file missing: $path" >&2
    fail=1
    continue
  fi
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL Next23 UI boundary changed protected file: $path" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    fail=1
  fi
done <<'HASHES'
6024b0a165bf9ede7294ef0bedbade4a56af2aab054a47ec89aa50c2abf51b26 Sources/HeliosDaemon/ControlLease.swift
b9a3b2de2f6c7786d4cd1654ef30c1c98177a3cf0c7369fc858a6ceb0a13b01a Sources/HeliosDaemon/DaemonLifecycle.swift
95499dacf91938e3f7d598dbb4570deee2406e43bd7b98ecf6f809eeb892ffed Sources/HeliosDaemon/DaemonListenerDelegate.swift
10d599ac3c35ff6d4fc8795c1cdc461a49e7f9f658193c3ac9261858c0217a6e Sources/HeliosDaemon/DaemonSession.swift
cf388fac2d875cf0ea16f082edc94c522c1da3fc1c4c930ee74c6bf0493d00c6 Sources/HeliosDaemon/DiagnosticLease.swift
a0de62cbea2295d6bc169d46b9133843930fd91fca26c6bf9aee0cf7305f9131 Sources/HeliosDaemon/FanControlCoordinator.swift
7af8742aa1792be993fe9f36019fe6275da34fc2d666030b79064491a8f6303c Sources/HeliosDaemon/FanControlEngine.swift
060ca8d1f4d916146482dc4e44a7a5de942bce810d5868044c2fb702c1eb4f39 Sources/HeliosDaemon/FanHardware.swift
04aa8dc364787db1e3c4112b984ec99c879563c9db37addca7d09d4c10ed2105 Sources/HeliosDaemon/FanOwnershipJournal.swift
798e5604a52ff5479a95f49918bb82faefc9bf6aa7cade30f8cf47ed8442c7e7 Sources/HeliosDaemon/FanOwnershipProductionRecovery.swift
1b5d383811f414e001d920f91fad9e82199b8a1e113259ea636b0e14bcaa48bd Sources/HeliosDaemon/FanOwnershipRecovery.swift
dcaf2a0f7ca2fe9ab91a28a6f52640201ee9001ec1dacbc5eefc5146afb6a0b0 Sources/HeliosDaemon/FanOwnershipTransition.swift
434af87bf299bec68dbdf7fa93fda0ab183179a6da7c2b44d6a9bde6ba3001cf Sources/HeliosDaemon/HeliosDaemon.swift
6a58d23b18bd435059414252e6c186257629c35e3f1a72b9811ef8d26a1f9451 Sources/HeliosApp/CoolingRules.swift
a9e993b7a241d2a0982a536853d17a5a72d795cd55288d23ef52fa836db3c44d Sources/HeliosApp/DaemonClient.swift
5b96b35717690c2db8801e31a1528b41d8070573cbd5d72f54062e8c65456c2a Sources/HeliosApp/FanControlModel.swift
46adf80c769f80e67a0e0ef9bbd7ae4d3f540fce0ac10db18993d3643c237672 Sources/HeliosApp/FanControlView.swift
6c698290f8c6a92f7f006969e8cb2f09bbbec79ee1d2f9cbc0d3d5f06886a10c Sources/HeliosApp/Telemetry/BatteryProvider.swift
a6dee07d1c7b6886dd825b182a39f029c1a08a4b820d572d6a608f63d493aae8 Sources/Shared/FanModels.swift
45ca96112afc2631bdefa77a4b8b4220eec433af3058e66c551454fbb93ec74b Sources/Shared/FanOwnershipPreflight.swift
47311664dbb8e0e947bc497d1f8a157a459009d54c7352654fee8e16bfa0fc4e Sources/Shared/HeliosServiceIdentity.swift
1822fa3a710112e48979602da5950e63113845eb2ae3bde577b9255b35b5b9db Sources/Shared/HeliosXPCProtocol.swift
5ceb7e32fd10efad3a16e7ccc8e295984fafad7f2f35d876874dddc5e58c477c Sources/Shared/SMCClient.swift
414a1e48f601eb21215668c042c7084199641948c08b37fd41cc343e5fd72be5 Sources/Shared/XPCTrustRequirement.swift
HASHES

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "PASS Next23 UI boundary: validated fan daemon/control/XPC/SMC and battery provider remain byte-identical to Next22 functional freeze"

# Presentation checks execute as a plain command-line Mach-O, not as Helios.app.
# They must never eagerly instantiate bundle-only notification/persistence services.
if grep -Fq 'let uiModel = OverviewViewModel()' Tests/PresentationChecks.swift; then
  echo "FAIL: Next23 presentation fixture constructed live OverviewViewModel services" >&2
  exit 1
fi
if ! grep -Fq 'OverviewViewModel(runtimeServicesEnabled: false)' Tests/PresentationChecks.swift; then
  echo "FAIL: Next23 presentation fixture is missing side-effect-free OverviewViewModel construction" >&2
  exit 1
fi
if grep -Fq 'private let center = UNUserNotificationCenter.current()' Sources/HeliosApp/Telemetry/HealthAlerts.swift; then
  echo "FAIL: HealthAlertCenter eagerly constructs UNUserNotificationCenter and will crash command-line render fixtures" >&2
  exit 1
fi

printf '%s\n' "PASS Next23 presentation isolation: command-line renders disable app-only notification/persistent services"

# UI8 uses native macOS status-item selection only while the owning popover is open.
# The custom telemetry glyph/text must never switch to selected-menu colors itself.
if grep -Fq 'selectedMenuItemTextColor' Sources/HeliosApp/MenuBarView.swift; then
  echo "FAIL: UI8 menu-bar readout uses selected-menu text colors instead of AppKit's native pill" >&2
  exit 1
fi
if [ "$(grep -Fc 'button.highlight(true)' Sources/HeliosApp/StatusItemController.swift)" -ne 1 ]; then
  echo "FAIL: UI8 must have exactly one transient native status-item highlight entry point" >&2
  exit 1
fi
for required in \
  'highlightedPopover = popover' \
  'highlightedPopover === popover' \
  'highlightedButton?.highlight(false)' \
  'private var metricPopovers: [HeliosMenuBarMetric: NSPopover]' \
  'closeMetricPopovers(except: popover)' \
  'clearHighlight(ifOwnedBy: popover)'; do
  if ! grep -Fq "$required" Sources/HeliosApp/StatusItemController.swift; then
    echo "FAIL: UI8 transient status-item pill lifecycle is incomplete: $required" >&2
    exit 1
  fi
done

if grep -Fq 'private let metricPopover = NSPopover()' Sources/HeliosApp/StatusItemController.swift; then
  echo "FAIL: UI8 reintroduced one shared metric popover; switching modules can race stale close callbacks against the new native pill" >&2
  exit 1
fi
if grep -Fq 'button.isBordered = false' Sources/HeliosApp/StatusItemController.swift ||    grep -Fq 'highlightsBy = []' Sources/HeliosApp/StatusItemController.swift; then
  echo "FAIL: UI8 disables native NSStatusBarButton selected-state rendering" >&2
  exit 1
fi

# The compact dashboard stays module-driven; presets live in onboarding/Settings.
if grep -Fq 'Picker("Dashboard"' Sources/HeliosApp/HeliosDashboardView.swift; then
  echo "FAIL: UI8 dashboard still exposes the old permanent Simple/Advanced/All picker" >&2
  exit 1
fi
if ! grep -Eq 'ForEach\((preferences\.popoverModules|visiblePopoverModules)' Sources/HeliosApp/HeliosDashboardView.swift; then
  echo "FAIL: UI8 dashboard is not driven by configurable modules" >&2
  exit 1
fi
if ! grep -Fq 'Text(expanded ? "Done" : "Change")' Sources/HeliosApp/HeliosDashboardView.swift; then
  echo "FAIL: UI8 compact Cooling control is missing the collapsed Change disclosure" >&2
  exit 1
fi
if ! grep -Fq 'controller.showOnboardingIfNeeded()' Sources/HeliosApp/HeliosApp.swift; then
  echo "FAIL: UI8 first-run onboarding is not wired into app launch" >&2
  exit 1
fi
if ! grep -Fq 'List(preferences.monitorRoutes' Sources/HeliosApp/HeliosWindows.swift; then
  echo "FAIL: UI8 Full Monitor sidebar is not driven by user-configurable modules" >&2
  exit 1
fi
if ! grep -Fq 'HeliosMenuBarPreview(' Sources/HeliosApp/HeliosWindows.swift; then
  echo "FAIL: UI8 menu-bar customization is missing its live preview" >&2
  exit 1
fi

# Preferences initialization must remain definite-initialization safe.
if grep -Fq 'Self.modules(for: dashboardMode)' Sources/HeliosApp/HeliosPreferences.swift; then
  echo "FAIL: UI8 preferences initializer reads dashboardMode through self before full initialization" >&2
  exit 1
fi
if ! grep -Fq 'Self.modules(for: resolvedDashboardMode)' Sources/HeliosApp/HeliosPreferences.swift; then
  echo "FAIL: UI8 preferences initializer is missing local preset resolution" >&2
  exit 1
fi

# UI8 menu-bar architecture: real status items, per-module identity, contextual popovers,
# and an optional compact group/hub. Geometry remains value-independent.
for required in \
  'case nativeModules' \
  'case compactGroup' \
  'private var nativeItems: [HeliosMenuBarMetric: NSStatusItem]' \
  'private func buildNativeItems()' \
  'item.autosaveName = "com.snejda.Helios.status.\(metric.rawValue)"' \
  'item.autosaveName = "com.snejda.Helios.status.hub"' \
  'item.autosaveName = "com.snejda.Helios.status.compact"' \
  'HeliosMetricPopoverView(' \
  'func identityStyle(for metric: HeliosMenuBarMetric)' \
  'func setIdentityStyle(' \
  'func setLabel(' \
  '"Menu bar layout"' \
  '"Show Helios dashboard hub",' \
  'setMenuBarHubVisible' \
  'preferences.showMenuBarHub || metrics.isEmpty'; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: UI8 native/per-module menu-bar architecture is missing: $required" >&2
    exit 1
  fi
done

# UI8 graph engine: raw/smooth line shape is user-selectable, time windows are
# persistent-history backed, and live motion is event-driven rather than a permanent timer.
# Fixed2 deliberately moved the hot rendering path out of SwiftUI Shape interpolation:
# a native AppKit backing layer draws the final frame once and Core Animation slides
# that layer by the exact elapsed time fraction. This mirrors the low-work pattern used
# by mature menu-bar monitors without importing their implementation.
for required in \
  'enum HeliosGraphLineStyle' \
  'enum HeliosGraphRange' \
  'case twentyFourHours' \
  'NSViewRepresentable' \
  'HeliosNativeTimeSeriesView' \
  'CABasicAnimation(keyPath: "transform.translation.x")' \
  'CATransaction.setDisableActions(true)' \
  'NSWorkspace.shared.accessibilityDisplayShouldReduceMotion' \
  'stableDynamicRange' \
  'niceCeiling(' \
  'decimated(' \
  'monotoneTangents(for:' \
  'HeliosChartSeries.merged('; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: UI8 graph engine is missing: $required" >&2
    exit 1
  fi
done
if grep -Fq 'TimelineView(' Sources/HeliosApp/HeliosGraphKit.swift; then
  echo "FAIL: UI8 graph animation uses a permanent TimelineView instead of sample-driven motion" >&2
  exit 1
fi
if grep -Eq 'AnimatablePair<Double, Double>|renderedSamples|onChange\(of: samples\.last\)' Sources/HeliosApp/HeliosGraphKit.swift; then
  echo "FAIL: UI8 graph engine regressed to per-point SwiftUI morphing instead of native layer motion" >&2
  exit 1
fi
if ! grep -Fq 'memoryPercent: value(' Sources/HeliosApp/Telemetry/PersistentHistory.swift; then
  echo "FAIL: UI8 persistent history is missing memory percentage for long-range charts" >&2
  exit 1
fi

# Battery remains read-only but gets a fast approximate ETA and bounded local energy attribution.
for required in \
  'HeliosBatteryEstimateEngine.estimate(' \
  'case helios = "Helios estimate"' \
  'remainingEnergyWh' \
  'recentDischargeWatts' \
  'What is using your battery?' \
  'activeBatteryEnergy' \
  'AppEnergyHistoryEngine.summary('; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: UI8 Battery & Energy surface is missing: $required" >&2
    exit 1
  fi
done

# Raw thermal keys stay behind an expert disclosure and never become fan-safety inputs.
if ! grep -Fq 'Other raw / unclassified' Sources/HeliosApp/HeliosWindows.swift; then
  echo "FAIL: UI8 thermals page does not isolate raw sensor inventory behind expert disclosure" >&2
  exit 1
fi

# Every Swift source under Sources/HeliosApp must be present in the Xcode project.
missing=0
while IFS= read -r source; do
  base="$(basename "$source")"
  if ! grep -Fq "path = $base;" Helios.xcodeproj/project.pbxproj; then
    echo "FAIL: Xcode project is missing source reference: $base" >&2
    missing=1
  fi
  if ! grep -Fq "/* $base in Sources */" Helios.xcodeproj/project.pbxproj; then
    echo "FAIL: Xcode target is missing source build-phase membership: $base" >&2
    missing=1
  fi
done < <(find Sources/HeliosApp -name '*.swift' -type f | sort)
if [ "$missing" -ne 0 ]; then exit 1; fi


# UI8 fixed2 runtime polish: status popovers must be defensively dismissible,
# Escape is routed through a key popover responder, memory uses a gauge instead
# of a redundant live chart, and graph style/animation live in Settings rather
# than every detail page.
for required in \
  'startDismissMonitoring(sourceButton:' \
  'addGlobalMonitorForEvents' \
  'stopDismissMonitoring()' \
  'HeliosEscapableHostingView' \
  'override func cancelOperation' \
  '.onExitCommand' \
  'window.makeKey()' \
  'window.makeFirstResponder(view)' \
  'forceCloseAllPopovers()' \
  'struct HeliosArcGauge' \
  'CABasicAnimation(keyPath: "transform.translation.x")' \
  'ThermalDisplayClassifier.classify(raw)' \
  'CPU die maximum · community' \
  'Virtual / derived sensors' \
  'Inactive / placeholder-like' \
  'LazyVStack(spacing: 5)' \
  'advisoryRefreshInterval: Duration = .seconds(15)' \
  'advisoryReadingsCapturedAt' \
  'dashboardHistoryTail' \
  'var history = TelemetryHistory()'; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: UI8 fixed2 runtime polish is missing: $required" >&2
    exit 1
  fi
done
if grep -Fq 'service.refresh()' Sources/HeliosApp/StatusItemController.swift; then
  echo "FAIL: UI8 menu-bar click path performs synchronous service refresh/XPC work" >&2
  exit 1
fi
if grep -Fq '@Published var history = TelemetryHistory()' Sources/HeliosApp/OverviewViewController.swift; then
  echo "FAIL: UI8 publishes live history separately from the same 1 Hz snapshot and doubles UI invalidation" >&2
  exit 1
fi
if grep -Fq '@ObservedObject var service: DaemonService' Sources/HeliosApp/HeliosMetricPopovers.swift; then
  echo "FAIL: UI8 metric popup observes unrelated service-registration refreshes" >&2
  exit 1
fi
# NSHostingView declares init(rootView:) as required. Any custom hosting subclass
# must provide that initializer even when Helios normally constructs it through
# the richer rootView:onCancel: initializer. Keep this early boundary check so
# an SDK-required initializer regression fails before the expensive Xcode gate.
for required in \
  'required init(rootView: Content)' \
  'self.onCancel = {}' \
  'init(rootView: Content, onCancel: @escaping () -> Void)'; do
  if ! grep -Fq "$required" Sources/HeliosApp/StatusItemController.swift; then
    echo "FAIL: UI8 escapable NSHostingView subclass is missing required initializer contract: $required" >&2
    exit 1
  fi
done

if ! grep -Fq 'enum ThermalDisplayClassifier' Sources/HeliosApp/Telemetry/ThermalProvider.swift; then
  echo "FAIL: UI8 thermal expert inventory is missing display-only sensor classification" >&2
  exit 1
fi
if grep -Fq 'chart(samples: memorySamples' Sources/HeliosApp/HeliosMetricPopovers.swift; then
  echo "FAIL: UI8 memory popup regressed to a history line chart instead of the compact usage gauge" >&2
  exit 1
fi
if grep -Fq 'HeliosBrandMark(size:' Sources/HeliosApp/HeliosMetricPopovers.swift; then
  echo "FAIL: UI8 metric popovers repeat the Helios brand mark" >&2
  exit 1
fi
chart_toolbar="$(sed -n '/private var chartToolbar/,/^  }/p' Sources/HeliosApp/HeliosWindows.swift)"
if printf '%s\n' "$chart_toolbar" | grep -Eq 'graphLineStyle|animateGraphUpdates'; then
  echo "FAIL: UI8 Raw/Smooth or Animate controls leaked back into every Full Monitor page" >&2
  exit 1
fi
for required in \
  'Energy Attribution' \
  'batteryEnergyRow(' \
  'HeliosAppIdentityIcon('; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: UI8 independent Battery & Energy attribution surface is missing: $required" >&2
    exit 1
  fi
done

# UI9 interaction/polish gate. These are deliberately presentation-only additions
# over the same protected Next22 functional freeze.
for required in \
  'HeliosGraphRangeMenu' \
  'override func mouseMoved(with event: NSEvent)' \
  'drawInspector(context:' \
  'seriesLabel:' \
  'HeliosSegmentedArcGauge' \
  'HeliosMemoryComposition' \
  'Reclaimable cache' \
  'private var fanSamples:' \
  'continuous graph motion' \
  'func menuBarContent(for metric:' \
  'setMenuBarIconVisible' \
  'setMenuBarLabelVisible' \
  'setMenuBarValueVisible' \
  'case custom' \
  'batteryPeriodInsight('; do
  if ! grep -R -Fiq "$required" Sources/HeliosApp; then
    echo "FAIL: UI9 interaction/polish surface is missing: $required" >&2
    exit 1
  fi
done
if grep -Fq 'clock.arrow.circlepath' Sources/HeliosApp/HeliosMetricPopovers.swift; then
  echo "FAIL: UI9 metric popover range control still uses the misleading refresh/history symbol" >&2
  exit 1
fi
if ! grep -Fq 'window.setContentSize(NSSize(width: 720, height: 560))' Sources/HeliosApp/HeliosWindows.swift || \
   ! grep -Fq '.frame(width: 720, height: 560)' Sources/HeliosApp/HeliosWindows.swift; then
  echo "FAIL: UI9 four-choice onboarding does not use the expanded fixed geometry" >&2
  exit 1
fi

# UI9 polished2 closes the runtime issues found on the real M4: the moving path
# now sits behind a fixed clip aperture, compact range menus expose one arrow,
# memory colors are semantically unique, thermal popovers can actually change
# the validated fan modes, alerts are debounced/logged, and battery attribution
# has a dedicated inspector window. None of these may widen the protected backend.
for required in \
  'plotClipView.layer?.masksToBounds = true' \
  'plotCanvasView.layer?.add(animation' \
  'windowWithPredecessor' \
  '.menuIndicator(.hidden)' \
  'memoryGaugeShowsAvailable' \
  'static let compressed = Color.pink' \
  'static let cache = Color.cyan' \
  'static let swap = Color.orange' \
  'FanModeControls(' \
  'Open full cooling controls…' \
  'enum HealthNotificationPolicy' \
  'case notified' \
  'Label("Alert log"' \
  'showEventLog: true' \
  'struct HeliosEnergyInspectorView' \
  'Open Energy Inspector…' \
  'func showEnergyInspector()'; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: UI9 polished2 runtime correction is missing: $required" >&2
    exit 1
  fi
done

if ! grep -Fq '@Published var memoryGaugeShowsAvailable: Bool' Sources/HeliosApp/HeliosPreferences.swift; then
  echo "FAIL: UI9 memory-gauge Available preference is not persisted" >&2
  exit 1
fi
if ! grep -Fq 'FanModeControls(' Sources/HeliosApp/HeliosMetricPopovers.swift; then
  echo "FAIL: UI9 thermal metric popup is still display-only instead of interactive" >&2
  exit 1
fi

printf '%s\n' "PASS Next23 UI9 polished2 boundary: fixed-edge chart motion, single range indicator, non-overlapping memory colors, direct thermal fan controls, anti-spam alert log, and dedicated Energy Inspector are wired over the frozen backend"


# UI10 modular foundation/final-polish gate. The hot backend remains frozen; this
# gate protects the user-configurable presentation architecture added after the
# real-M4 UI9 runtime review.
for required in \
  'private static let horizontalPlotInset: CGFloat = 0.5' \
  'if !animateUpdates, cursorPoint == nil' \
  'enum HeliosDashboardMetric' \
  'enum HeliosColorRole' \
  '@Published private(set) var dashboardMetrics' \
  '@Published var detailedMonitorContent: Bool' \
  'setDashboardMetricEnabled' \
  'moveDashboardMetric' \
  'resetColors()' \
  'case energy' \
  'Open Energy' \
  'frame(maxWidth: 1280' \
  'GridItem(.adaptive(minimum: 190, maximum: 360)' \
  'Detailed Full Monitor content' \
  'Graphs & Colors' \
  'ColorPicker(' \
  'preferences.color(for: .cpu)' \
  'preferences.color(for: .temperature)' \
  'preferences.color(for: .storageRead)' \
  'preferences.color(for: .networkDownload)' \
  'preferences.color(for: .memoryApp)' \
  'ForEach(preferences.dashboardMetrics)' \
  'Reset Colors'; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: UI10 modular/final-polish surface is missing: $required" >&2
    exit 1
  fi
done

if grep -R -Fq 'Product inspiration: Stats · OpenMacBattery' Sources/HeliosApp; then
  echo "FAIL: UI10 About still exposes development inspiration as product chrome" >&2
  exit 1
fi

printf '%s\n' "PASS Next23 UI10 modular foundation: edge-to-edge continuous charts, customizable dashboard/monitor density, first-class Energy, responsive Full Monitor, and per-series colors are wired over the frozen backend"

# UI10 RC4 closes the remaining real-M4 feedback before visual freeze: telemetry
# collection is independently switchable, cooling UI can disappear without
# weakening trusted thermal health, menu-bar geometry is user-compactable, the
# Quick Dashboard is edited in place, custom fan control has a first-use safety
# gate, Expert is a focused diagnostic workspace, and chart rollover retains real
# predecessor overscan until the animated path reaches the clip edge.
for required in \
  'enum HeliosTelemetryModule' \
  '@Published var menuBarSpacing: Double' \
  '@Published var coolingFeaturesEnabled: Bool' \
  '@Published private(set) var telemetryModules' \
  '@Published private(set) var fanSafetyGuideCompleted' \
  'setTelemetryModuleEnabled' \
  'setCoolingFeaturesEnabled' \
  'menuBarMetricsForPresentation' \
  'monitorRoutesChangedByMigration' \
  'Data Collection' \
  'Stop work you do not need' \
  'Metric spacing' \
  'setModuleSpacing' \
  'editingDashboard' \
  'dashboardCustomizationFooter' \
  'dashboardModuleEditBar' \
  'resetDashboard()' \
  'HeliosFanSafetyNotice' \
  'Before changing fan control' \
  'case alerts' \
  'Open active health alerts' \
  'enum HeliosExpertSection' \
  'Diagnostic Workspace' \
  'expertSensors' \
  'expertTelemetry' \
  'expertServices' \
  'expertLogs' \
  'firstVisible - 6' \
  'plotCanvasOverscan' \
  'x: -overscan' \
  'maximumSafeSlide' \
  'predecessorTail.append(sample)' \
  'let visualSpan = range.seconds' \
  'onReceive(preferences.$monitorRoutes)'; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: UI10 RC4 finalization surface is missing: $required" >&2
    exit 1
  fi
done

if grep -Fq 'hidePrimarySurfaces(for module:' Sources/HeliosApp/HeliosPreferences.swift; then
  echo "FAIL: UI10 RC4 collection toggles still destroy saved presentation layout" >&2
  exit 1
fi
if grep -Fq 'range.seconds + visualRetentionGrace' Sources/HeliosApp/HeliosGraphKit.swift; then
  echo "FAIL: UI10 RC4 chart still expands/compresses the selected visible range instead of using offscreen predecessor overscan" >&2
  exit 1
fi

if grep -Fq 'if let lastPoint {' Sources/HeliosApp/HeliosDashboardView.swift; then
  echo "FAIL: UI10 RC1 mini charts still force a permanent frontier dot" >&2
  exit 1
fi
if ! grep -Fq 'if showsFrontierPoint, let lastPoint {' Sources/HeliosApp/HeliosDashboardView.swift; then
  echo "FAIL: UI10 RC1 mini-chart frontier point is not opt-in" >&2
  exit 1
fi
# Swift rejects covariant Self references from instance stored-property initializers.
# Keep the menu-bar spacing default concrete so this regression fails in the cheap
# boundary gate instead of waiting for the full macOS compiler surface.
if grep -Fq 'private var moduleSpacing: CGFloat = Self.defaultModuleSpacing' Sources/HeliosApp/MenuBarView.swift; then
  echo "FAIL: UI10 RC1 menu-bar spacing uses covariant Self in a stored-property initializer" >&2
  exit 1
fi
if ! grep -Fq 'private var moduleSpacing: CGFloat = MenuBarView.defaultModuleSpacing' Sources/HeliosApp/MenuBarView.swift; then
  echo "FAIL: UI10 RC1 menu-bar spacing default is not initialized through the concrete MenuBarView type" >&2
  exit 1
fi
for required in \
  'telemetryEnabled(.network)' \
  'telemetryEnabled(.processes)' \
  'telemetryEnabled(.fans)'; do
  if ! grep -Fq "$required" Sources/HeliosApp/Telemetry/TelemetryMonitor.swift; then
    echo "FAIL: UI10 RC collection toggle is not wired into the runtime sampler: $required" >&2
    exit 1
  fi
done
if grep -R -Fq 'HeliosPreferences' Sources/HeliosApp/Telemetry; then
  echo "FAIL: telemetry layer depends directly on UI preferences; standalone telemetry checks would not typecheck" >&2
  exit 1
fi
if ! grep -Fq 'enum HeliosTelemetryModule' Sources/HeliosApp/Telemetry/TelemetryCollectionPolicy.swift; then
  echo "FAIL: telemetry collection policy is not defined in the telemetry layer" >&2
  exit 1
fi
if ! grep -Fq 'TelemetryCollectionPolicy.swift in Sources' Helios.xcodeproj/project.pbxproj; then
  echo "FAIL: telemetry collection policy is missing from the HeliosApp Xcode target" >&2
  exit 1
fi
if [ "$(grep -R -l -F 'enum HeliosTelemetryModule' Sources/HeliosApp --include='*.swift' | wc -l | tr -d ' ')" != "1" ]; then
  echo "FAIL: telemetry collection module must have exactly one canonical definition" >&2
  exit 1
fi
for script in scripts/check-telemetry.sh scripts/check-presentation.sh; do
  if ! grep -Fq 'Sources/HeliosApp/Telemetry/*.swift' "$script"; then
    echo "FAIL: $script does not compile the complete telemetry layer" >&2
    exit 1
  fi
done
if ! grep -Fq 'telemetryEnabled: @escaping @MainActor (HeliosTelemetryModule) -> Bool' Sources/HeliosApp/Telemetry/TelemetryMonitor.swift; then
  echo "FAIL: TelemetryMonitor collection gate is not injected through the telemetry-layer policy" >&2
  exit 1
fi

printf '%s\n' "PASS Next23 UI10 RC4 finalization: reversible collection gates, cooling opt-out, regular compact spacing, bottom dashboard customization, fan safety guide, expert workspace, and exact-range rollover overscan are wired over the frozen backend"


# RC5 complete telemetry/lifecycle presentation. These checks intentionally stay
# above the frozen backend and complement check-detailed-ui-coverage.sh.
for required in \
  'func applyInterfacePreset' \
  'CPU internals' \
  'NVMe SMART / Lifetime' \
  'Process sampler' \
  'Raw SMC numeric inventory' \
  'Temperature & Fan' \
  'Launch Helios at login' \
  'func setLaunchAtLogin(_ enabled: Bool) async -> Bool' \
  'Boot registration' \
  'Prepare Helios for Removal' \
  'func uninstall() async -> Bool' \
  'Removal stopped: Launch at Login could not be disabled.' \
  'Removal stopped: the privileged helper is still registered.' \
  'Erase local Helios settings and monitoring history' \
  'validated factory fan range'; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: RC5 complete telemetry/lifecycle surface is missing: $required" >&2
    exit 1
  fi
done

if grep -R -Fq 'Boost is temporary' Sources/HeliosApp; then
  echo "FAIL: RC5 fan guide still describes Boost as time-limited" >&2
  exit 1
fi
if grep -R -Fq 'inside the safe fan range' Sources/HeliosApp; then
  echo "FAIL: RC5 fan guide still uses the unverified generic safe-range wording" >&2
  exit 1
fi

# RC6 compile-stability boundary: the exhaustive Detailed surface must not be
# folded directly into HeliosModuleDetail.body as a giant opaque SwiftUI type.
# Xcode 26 / Swift 6.3 can abort in substOpaqueTypesWithUnderlyingTypes when
# that tree contains every route plus the complete diagnostics extension.
if ! grep -Fq 'private var routeContent: AnyView' Sources/HeliosApp/HeliosWindows.swift; then
  echo "FAIL: Full Monitor route switch is missing its concrete AnyView compile boundary" >&2
  exit 1
fi
if ! grep -Fq 'private var detailedBackendTelemetry: AnyView' Sources/HeliosApp/HeliosWindows.swift; then
  echo "FAIL: exhaustive Detailed telemetry is missing its concrete AnyView compile boundary" >&2
  exit 1
fi

printf '%s\n' "PASS Next23 UI10 RC5 complete telemetry/lifecycle: global presets, exhaustive published diagnostics, combined thermal/fan presentation, startup/helper lifecycle and removal cleanup are wired over the frozen backend"
printf '%s\n' "PASS Next23 UI10 RC6 compile-stability boundary: exhaustive Full Monitor routes and diagnostics are type-erased before the root SwiftUI body"

# RC7 bugfix boundary: the one-time fan safety alert must restore the metric
# popover to a canonical top scroll state, and the scroll surface must clip
# under the fixed header/footer. The IPC regression also consumes the Bool
# returned by asynchronous uninstall under warnings-as-errors.
if ! grep -Fq '.clipped()' Sources/HeliosApp/HeliosMetricPopovers.swift || \
   ! grep -Fq '.id(scrollGeneration)' Sources/HeliosApp/HeliosMetricPopovers.swift || \
   ! grep -Fq 'scrollGeneration &+= 1' Sources/HeliosApp/HeliosMetricPopovers.swift; then
  echo "FAIL: RC7 metric popover scroll restoration/clipping regression guard is missing" >&2
  exit 1
fi
if ! grep -Fq '_ = await removal.value' Tests/IPCChecks.swift; then
  echo "FAIL: RC7 IPC warnings-as-errors fix is missing" >&2
  exit 1
fi

printf '%s\n' "PASS Next23 UI10 RC7 bugfix boundary: fan-guide dismissal restores a clipped canonical popover scroll state and IPC async results are consumed under warnings-as-errors"


# RC8 diagnostics polish: exhaustive backend telemetry remains reachable, but
# the Full Monitor must present it as compact, expandable, design-consistent
# diagnostics rather than a permanently expanded full-width key/value dump.
for required in \
  'HeliosDiagnosticDisclosurePanel' \
  'Advanced diagnostics' \
  'Complete backend telemetry, grouped into compact expandable sections.' \
  'private func diagnosticSection' \
  'private func diagnosticRow' \
  'private func diagnosticMiniMetric' \
  'private func diagnosticEntityCard' \
  'Grouped by display name; raw app identities remain visible' \
  'thermalSensorChip' \
  'Storage devices' \
  'Raw NVMe counters' \
  'Process sampler'; do
  if ! grep -Fq "$required" Sources/HeliosApp/HeliosWindows.swift; then
    echo "FAIL: RC8 compact diagnostics polish is missing: $required" >&2
    exit 1
  fi
done

if grep -Fq 'Complete Process Telemetry' Sources/HeliosApp/HeliosWindows.swift || \
   grep -Fq 'Complete Storage Telemetry' Sources/HeliosApp/HeliosWindows.swift || \
   grep -Fq 'Complete Thermal Telemetry' Sources/HeliosApp/HeliosWindows.swift; then
  echo "FAIL: RC8 still exposes legacy full-width Complete-* diagnostic headings" >&2
  exit 1
fi

printf '%s\n' "PASS Next23 UI10 RC8 diagnostics polish: exhaustive backend telemetry is grouped into compact expandable panels without removing published fields"
