#!/bin/bash
# The protected fan-control and battery boundary must not change by accident.
# Each file below is fingerprinted with SHA-256; a change needs a deliberate, reviewed
# manifest update. This list records those updates (never relax what the gate asserts).
#
# - Cool-only fan layer (docs/FAN_LAYER_DESIGN.md): XPC v4, coordinator Response, reclaim
#   limit and Boost cap, start-up recovery for every journal, and the layer files themselves.
#   The validated production writer, v2 journal, recovery state machine and SMC transport
#   stayed byte-identical.
# - XPC v5: Response as one bounded 0...1 value, full-maximum unlock call, limit in
#   fanLayerInfo; 90 % speed limit with handback to macOS enforced by the helper; re-acquire
#   cooldown with refusal backoff (only hardware refusals grow it); continuous fall ramp;
#   Manual debounce; Auto fan curve and presets; curve engage/release debounce; an in-flight
#   takeover is never cancelled for "no demand". Files: DaemonSession, FanControlCoordinator,
#   HeliosDaemon, CoolingRules, DaemonClient, FanControlModel, FanControlView,
#   HeliosServiceIdentity, HeliosXPCProtocol, FanLayerPolicy, FanLayerEngine,
#   FanLayerJournal, FanLayerRuntime. ControlLease, FanLayerHardware, the production writer,
#   journals and SMC transport stayed byte-identical.
# - FanControlModel: optional "Restore Auto when Helios starts"; repeated "returned to
#   System" log lines limited to one per 30 s. Comment text only: CoolingRules,
#   FanLayerPolicy, FanLayerHardware, FanLayerRuntime. No helper, XPC, SMC or safety logic.
# - Privacy only: the helper's start-up executable path is logged privately.
# - 0.2.1, FanControlModel.accept only: a power-gated temperature sensor
#   (`TelemetryError.inactiveSensor`, e.g. GPU keys at -4.5 °C while the GPU sleeps) no longer
#   counts as a Tp/Te/Tg failure. Every group still needs a valid reading and every other
#   failure still releases the fans. Before, Auto/Manual/Boost fell back to System whenever the
#   GPU slept. Helper, XPC, SMC and all other safety logic unchanged.
# - 0.3.0 M2, the single approved batch (owner approval 2026-10-14; PLAN_0_3_0 §3 M2,
#   decisions 2 and 3): fan layer on every Apple Silicon Mac. Takeover strategy from the
#   read-only probe (ftst when the Mac has Ftst, direct when it has none, with a virtual
#   global flag so the v2/v3 journal, executors and recovery are unchanged); lowercase
#   Fxmd mode key; recovery writer works without Ftst; helper temperature map from the
#   shared ChipCatalogue (validated M4 unchanged, cross-checked catalogue elsewhere);
#   unvalidated Macs: 70 % ceiling, no Boost, no full-maximum unlock, and a mandatory
#   20-second entry test per model + build (FanLayerEntryTest, root-owned result);
#   XPC v6 (fanLayerDetails, runFanLayerEntryTest); FanControlModel accepts catalogue
#   maps (Auto only after the P map is confirmed). The validated Mac16,1/25G83 path and
#   the M4 ftst write sequence are byte-for-byte the same writes. Legacy UI retired:
#   FanControlView deleted. Added: ChipCatalogue, FanLayerEntryTest. Simulations:
#   check-fan-layer "fan layer on all Apple Silicon".
# - 0.3.0 Beta 1 review, FanLayerEntryTest only (owner approval 2026-10-15): a takeover macOS
#   refuses or delays, and a failed read during the hold, are inconclusive (nothing stored, the
#   user may run the test again) instead of a permanent failure. A fan that was taken and then
#   lost its target, or that does not return to macOS, still fails the test for good. Writes,
#   limits, journal and restore are unchanged.
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
986a5b1d0f6bc2344959b95ed552d04e07617f993cf44c72ebcd273eb079bd53 Sources/HeliosDaemon/DaemonLifecycle.swift
9282686444bef9fc287d54ed95ed4561ab75b23fe7e6e889464ec6dbf2be1ba8 Sources/HeliosDaemon/DaemonListenerDelegate.swift
fdb7ade1e7e20baaec100f3b31cabad4b27780fe8da9ec9b347f03c57a34da94 Sources/HeliosDaemon/DaemonSession.swift
cf388fac2d875cf0ea16f082edc94c522c1da3fc1c4c930ee74c6bf0493d00c6 Sources/HeliosDaemon/DiagnosticLease.swift
b057d7befbc59674fa41a86aac8ba347c3ccf3a1320565bb67201a5b9e9d92b2 Sources/HeliosDaemon/FanControlCoordinator.swift
39729e0b1623d85756b12bcac0dd8bc4d325dc1b7f106c0b19aebd30c88bbfc9 Sources/HeliosDaemon/FanControlEngine.swift
060ca8d1f4d916146482dc4e44a7a5de942bce810d5868044c2fb702c1eb4f39 Sources/HeliosDaemon/FanHardware.swift
04aa8dc364787db1e3c4112b984ec99c879563c9db37addca7d09d4c10ed2105 Sources/HeliosDaemon/FanOwnershipJournal.swift
798e5604a52ff5479a95f49918bb82faefc9bf6aa7cade30f8cf47ed8442c7e7 Sources/HeliosDaemon/FanOwnershipProductionRecovery.swift
1b5d383811f414e001d920f91fad9e82199b8a1e113259ea636b0e14bcaa48bd Sources/HeliosDaemon/FanOwnershipRecovery.swift
dcaf2a0f7ca2fe9ab91a28a6f52640201ee9001ec1dacbc5eefc5146afb6a0b0 Sources/HeliosDaemon/FanOwnershipTransition.swift
5cf547aebe4c4aa82fe2c5ef1abd5158a0fb51e263253bf699e0296b140a96da Sources/HeliosDaemon/HeliosDaemon.swift
7e128093ed68c391074ff4cb00e35492c47e8fa74d5692d59f6a21c256598234 Sources/HeliosApp/CoolingRules.swift
ec277280f2682582381df9379c7c09898cfea9c1711276085ab9fca57f974e26 Sources/HeliosApp/DaemonClient.swift
067879574e53ed955619a7cc4ea7e840f984b957a238fa659209b1210a4ddc3c Sources/HeliosApp/FanControlModel.swift
6c698290f8c6a92f7f006969e8cb2f09bbbec79ee1d2f9cbc0d3d5f06886a10c Sources/HeliosApp/Telemetry/BatteryProvider.swift
a6dee07d1c7b6886dd825b182a39f029c1a08a4b820d572d6a608f63d493aae8 Sources/Shared/FanModels.swift
ab45f2d43af026051ef6bf04480b03e5e1293865275755948f6b9298aa391bd8 Sources/Shared/FanOwnershipPreflight.swift
510e63fb8498e47f1f06cfd73df77807c0ff22fe8142bd01b55d9e3374773061 Sources/Shared/HeliosServiceIdentity.swift
1e1624d433d155497b4cf36982603765f9e3677c9e812a665d04e2096d053885 Sources/Shared/HeliosXPCProtocol.swift
5ceb7e32fd10efad3a16e7ccc8e295984fafad7f2f35d876874dddc5e58c477c Sources/Shared/SMCClient.swift
414a1e48f601eb21215668c042c7084199641948c08b37fd41cc343e5fd72be5 Sources/Shared/XPCTrustRequirement.swift
2cc8de97f6f1f133da7f67be4d8c6ce348725a8e1869d943c2390cd14ebf0229 Sources/Shared/FanLayerPolicy.swift
a871194c3c46bd4eda59d5f8cb2b0f78abf8f511935a5fa9cab5e3c4eb715f6b Sources/Shared/FanLayerProfile.swift
a6423ccab363d311ecaa75b7af03d1f0bd46c314dac2fd33701d60fb05a39252 Sources/HeliosDaemon/FanLayerEngine.swift
a72e11d9657dd95663628af4f34fedff50c0d6466ca44a693cc25e7d6917bc1c Sources/HeliosDaemon/FanLayerHardware.swift
bd4009415a510140889540e50f8fb050e4768b7ca0507c3ff41a3c8200585471 Sources/HeliosDaemon/FanLayerJournal.swift
ee25510bb8c3dbf9f7dbd07137bd6ee0f35fb60c328a39c1785b564b396c9bdf Sources/HeliosDaemon/FanLayerRuntime.swift
01ad6913124569a38298a1071a18003e0cafc6443f7095ae6c8392a49a573777 Sources/HeliosDaemon/FanLayerThermals.swift
fa83eb0d2015685c3df9dce922de1833dc7bf3575d5647be49af364a493dbf03 Sources/Shared/ChipCatalogue.swift
b68c5c6937bee8293cfe72e31eec3b0404146c94da585b907970bdf1ed339fcc Sources/HeliosDaemon/FanLayerEntryTest.swift
HASHES

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "PASS Next23 boundary: 32 protected fingerprints verified (0.3.0 M2 manifest update 2026-10-14); fan control/authentication/XPC/SMC/battery sources change only through a reviewed manifest update"

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

if ! grep -Fq 'controller.showOnboardingIfNeeded()' Sources/HeliosApp/HeliosApp.swift; then
  echo "FAIL: UI8 first-run onboarding is not wired into app launch" >&2
  exit 1
fi
if ! grep -Fq 'HeliosMenuBarPreview(' Sources/HeliosApp/Windows/*.swift; then
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
  'AppEnergyHistoryEngine.summary('; do
  if ! grep -R -Fq "$required" Sources/HeliosApp; then
    echo "FAIL: UI8 Battery & Energy surface is missing: $required" >&2
    exit 1
  fi
done


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
  '.onExitCommand' \
  'forceCloseAllPopovers()' \
  'CABasicAnimation(keyPath: "transform.translation.x")' \
  'ThermalDisplayClassifier.classify(raw)' \
  'Validated hotspot' \
  'Unclassified SMC temperature' \
  'advisoryRefreshInterval: Duration = .seconds(15)' \
  'advisoryReadingsCapturedAt' \
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
if grep -Fq '@Published var history = TelemetryHistory()' Sources/HeliosApp/OverviewViewModel.swift; then
  echo "FAIL: UI8 publishes live history separately from the same 1 Hz snapshot and doubles UI invalidation" >&2
  exit 1
fi
if grep -Fq '@ObservedObject var service: DaemonService' Sources/HeliosApp/V2/HeliosMetricPopover.swift; then
  echo "FAIL: UI8 metric popup observes unrelated service-registration refreshes" >&2
  exit 1
fi

if ! grep -Fq 'enum ThermalDisplayClassifier' Sources/HeliosApp/Telemetry/ThermalProvider.swift; then
  echo "FAIL: UI8 thermal expert inventory is missing display-only sensor classification" >&2
  exit 1
fi
if grep -Fq 'chart(samples: memorySamples' Sources/HeliosApp/V2/HeliosMetricPopover.swift; then
  echo "FAIL: UI8 memory popup regressed to a history line chart instead of the compact usage gauge" >&2
  exit 1
fi
if grep -Fq 'HeliosBrandMark(size:' Sources/HeliosApp/V2/HeliosMetricPopover.swift; then
  echo "FAIL: UI8 metric popovers repeat the Helios brand mark" >&2
  exit 1
fi
for required in \
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
  'continuous graph motion' \
  'func menuBarContent(for metric:' \
  'setMenuBarIconVisible' \
  'setMenuBarLabelVisible' \
  'setMenuBarValueVisible' \
  'case custom'; do
  if ! grep -R -Fiq "$required" Sources/HeliosApp; then
    echo "FAIL: UI9 interaction/polish surface is missing: $required" >&2
    exit 1
  fi
done
if grep -Fq 'clock.arrow.circlepath' Sources/HeliosApp/V2/HeliosMetricPopover.swift; then
  echo "FAIL: UI9 metric popover range control still uses the misleading refresh/history symbol" >&2
  exit 1
fi
if ! grep -Fq 'window.setContentSize(NSSize(width: 720, height: 560))' Sources/HeliosApp/Windows/*.swift || \
   ! grep -Fq '.frame(minWidth: 600, idealWidth: 720, minHeight: 440, idealHeight: 560)' Sources/HeliosApp/Windows/*.swift || \
   ! grep -Fq 'window.contentMinSize = NSSize(width: 600, height: 440)' Sources/HeliosApp/Windows/*.swift; then
  echo "FAIL: Onboarding must retain its default size and bounded resizing geometry" >&2
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
  'enum HealthNotificationPolicy' \
  'case notified' \
  'struct HeliosEnergyInspectorView' \
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
# 0.3.0: the Legacy interface (and its interactive thermal popup) was retired (decision 3).
# Fan modes live on the Helios Thermals page and still go through FanControlModel.setMode;
# every retired Legacy surface points there instead of offering a second control path.
if ! grep -Fq 'struct HeliosCoolingSection' Sources/HeliosApp/V2/HeliosThermalsPage.swift \
  || ! grep -Fq 'model.setMode(mode)' Sources/HeliosApp/V2/HeliosThermalsPage.swift \
  || grep -R -Fq 'FanModeControls(' Sources/HeliosApp; then
  echo "FAIL: fan modes must be reachable only through the Helios Thermals page" >&2
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
  'Graphs & Colors' \
  'ColorPicker(' \
  'preferences.color(for: .memoryApp)' \
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

printf '%s\n' "PASS Next23 UI10 modular foundation: edge-to-edge continuous charts, first-class Energy and per-series colors are wired over the frozen backend"

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
  'resetDashboard()' \
  'HeliosFanSafetyNotice' \
  'Before changing fan control' \
  'case alerts' \
  'firstVisible - 6' \
  'plotCanvasOverscan' \
  'x: -overscan' \
  'maximumSafeSlide' \
  'predecessorTail.append(sample)' \
  'let visualSpan = range.seconds'; do
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

printf '%s\n' "PASS Next23 UI10 RC4 finalization: reversible collection gates, cooling opt-out, regular compact spacing, fan safety guide and exact-range rollover overscan are wired over the frozen backend"


# RC5 complete telemetry/lifecycle presentation. These checks intentionally stay
# above the frozen backend and complement check-detailed-ui-coverage.sh.
for required in \
  'func applyInterfacePreset' \
  'Temperature & Fan' \
  'Launch Helios at Login' \
  'func setLaunchAtLogin(_ enabled: Bool) async -> Bool' \
  'Boot registration' \
  'Uninstall Helios?' \
  'func uninstall() async -> Bool' \
  'Uninstall stopped: Launch at Login could not be turned off.' \
  'Uninstall stopped: the privileged helper is still registered.' \
  'struct HeliosUninstaller' \
  'Erase local Helios settings and monitoring history'; do
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


printf '%s\n' "PASS Next23 UI10 RC5 complete telemetry/lifecycle: global presets, exhaustive published diagnostics, combined thermal/fan presentation, startup/helper lifecycle and removal cleanup are wired over the frozen backend"

# RC7 bugfix boundary: the one-time fan safety alert must restore the metric
# popover to a canonical top scroll state, and the scroll surface must clip
# under the fixed header/footer. The IPC regression also consumes the Bool
# returned by asynchronous uninstall under warnings-as-errors.
if ! grep -Fq '_ = await removal.value' Tests/IPCChecks.swift; then
  echo "FAIL: RC7 IPC warnings-as-errors fix is missing" >&2
  exit 1
fi

printf '%s\n' "PASS Next23 UI10 RC7 bugfix boundary: IPC async results are consumed under warnings-as-errors"


# 0.3.0 M7: the retired Legacy surfaces (Full Monitor, module detail, dashboard popover,
# Legacy metric popovers and the OverviewViewController cards) are gone for good. The
# Helios main window, popover and metric popovers are the only presentation surfaces.
for retired in \
  Sources/HeliosApp/OverviewViewController.swift \
  Sources/HeliosApp/HeliosDashboardView.swift \
  Sources/HeliosApp/HeliosMetricPopovers.swift \
  Sources/HeliosApp/Windows/HeliosMonitorWindow.swift \
  Sources/HeliosApp/Windows/HeliosModuleDetail.swift; do
  if [ -e "$retired" ]; then
    echo "FAIL: retired Legacy surface came back: $retired" >&2
    exit 1
  fi
done
if grep -R -Eq 'HeliosMonitorWindowController|OverviewViewController|HeliosMetricPopoverView|interface\.style == ' Sources/HeliosApp; then
  echo "FAIL: a Legacy presentation path is referenced again" >&2
  exit 1
fi

printf '%s\n' "PASS 0.3.0 Legacy interface removed: one presentation path (Helios window, popover, metric popovers)"
