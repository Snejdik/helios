# Next23 — UI Architecture Rewrite

Next23 begins after the validated Next22 functional backend freeze (`next22-functional-freeze`). The goal is to replace the diagnostic-first menu-bar interface with a modern, modular macOS UI without widening Helios' privileged or battery-control surface.

## Frozen boundaries

- `Sources/HeliosDaemon/*`, XPC fan-control messages, SMC write keys, leases, recovery journal, ownership state machine and 95°C emergency floor remain unchanged.
- Battery remains telemetry-only. macOS owns charging policy.
- Unknown/raw SMC channels remain expert display-only.
- Runtime remains subprocess-free.

## UI architecture (current UI8)

- The recommended menu-bar layout is **Native Modules**: one native `NSStatusItem` per enabled metric plus an optional Helios solar hub. **Compact Group** remains an alternative for users who prefer one combined readout.
- Fresh/onboarding presets use separate CPU and Temperature modules rather than requiring the combined Cooling metric. Available metrics are CPU, Memory, GPU, Temperature, Cooling, Fan, Battery, System Power and Network.
- Every metric independently chooses Label, Icon or Value-only identity and may use a short custom label. Live text never participates in resizing; configuration changes may deliberately rebuild item geometry.
- Native metric items open metric-specific popups and use AppKit's native selected pill only while that popup is open. CPU opens CPU, Memory opens Memory, Battery opens Battery & Energy, etc. The optional Helios hub opens the complete fixed 420×600 module dashboard.
- Simple / Balanced / Everything remain one-time onboarding/Settings presets, not permanent chrome. The compact dashboard scrolls internally and expert diagnostics stay in the resizable Full Monitor.
- Full Monitor uses a macOS sidebar (`NavigationSplitView`) with Overview, CPU, Memory, GPU, Thermals & Fans, Battery & Power, Storage, Network, Processes, History, Health & Alerts, System, Devices, Maintenance and Expert diagnostics. Overview is pinned; other routes can be hidden, restored, and reordered.
- Charts support independent Raw/Smooth line shape and optional event-driven animation of incoming samples, with 1m/5m/15m/1h/6h/24h ranges backed by a live + persistent 24-hour history merge. Animation must never change telemetry polling cadence.
- Battery & Energy keeps macOS as the authoritative ETA source. While macOS still reports Calculating, an explicitly approximate `≈` Helios fallback may derive time from read-only capacity/voltage and recent discharge power. Selected-range per-app attribution remains relative/descriptive, not billing-grade energy accounting.
- Settings are organized around General, Modules (Menu Bar / Popups / Full Monitor), Graphs & History, Cooling, Battery & Energy, Privacy, Advanced and About. UI preferences remain isolated from privileged fan behavior.
- Primary branding uses a restrained custom Helios solar mark rather than a generic SF sun. Functional metric icons may still use aspect-fitted SF Symbols.

## Design principles

- Use semantic system colors, materials, SF Symbols and system typography instead of hard-coded macOS-version-specific imitation.
- Prefer small reusable cards and module routes over one giant scroll hierarchy.
- Keep main monitoring paths obvious; move raw/advanced diagnostics behind explicit expert navigation.
- The UI should adapt naturally to future macOS appearance changes with minimal conditional styling.

## Next steps after UI acceptance

1. Iterate on spacing, hierarchy and module content from real screenshots on the M4 MacBook Pro.
2. Complete migration of remaining legacy Expert cards into dedicated sidebar modules.
3. Accessibility/keyboard/VoiceOver pass.
4. Performance and wakeup profiling only after UI stabilizes (CoreWLAN cadence, sensors/Bluetooth cost, allocations, history writes, launch time, RAM/app size).
5. Independent architecture/security/performance review, then cross-Mac validation and distribution work.

## UI3 stabilization pass

- Fixed the UI2 presentation regression: newly enabled menu-bar modules append, each up/down action moves exactly one position, repeated moves are deterministic, bounds are no-ops, and the exact order persists through `UserDefaults` reloads.
- Presentation checks now cover zero-RPM (`Fan off`), running RPM, fanless hardware (`Fanless`), empty menu-bar fallback, reset semantics, symbol-toggle geometry, and light/dark native renders.
- Generic menu-bar modules use a two-row identity/value layout so optional SF Symbols never consume value width. The Cooling module keeps temperature on the first row and actual fan state/RPM on the second.
- Full Monitor now has dedicated History, Health & Alerts, System, and Maintenance routes in addition to the original Next23 module set. Battery & Power has a dedicated non-disclosure diagnostics page so expert battery details can never resize the status popover.
- Settings now also document Privacy and Advanced boundaries, provide a UI-only reset, show build/version information, and link to the project/issue tracker.
- `check-next23-ui-boundary.sh` hashes the validated Next22 fan daemon/control/XPC/SMC and BatteryProvider files. It runs from `check-all.sh` so presentation work cannot silently drift into the frozen safety core.

## Presentation-test isolation

Native UI regression renders are compiled as a standalone command-line executable under `.build/Checks`, not launched as `Helios.app`. Next23 therefore injects a side-effect-free `OverviewViewModel(runtimeServicesEnabled: false)` for presentation fixtures. This mode keeps health evaluation available for rendering while disabling `UNUserNotificationCenter`, persistent history stores, I/O audit stores, and per-app energy persistence. The live app continues to use the default runtime-enabled model. This prevents TCC/bundle-only APIs from crashing deterministic UI tests and prevents presentation tests from mutating user history.


## UI5 stabilization and fail-fast gate

- Fixed the UI4 Swift 6 warnings-as-errors regression in `HealthAlertCenter.schedule`: fixture-mode notification gating no longer creates an unused optional binding.
- Reformatted the Next23 presentation/UI sources with `swift-format` and linted those files strictly before packaging.
- `check-all.sh` now runs the Next23 native presentation suite and a complete Xcode build **before** the longer ownership/IPC/fan/storage/telemetry simulations. UI type/warning/build failures therefore fail early instead of appearing after minutes of backend tests.
- `check-presentation.sh` now also compiles `StatusItemController.swift`, extending the early UI compiler surface to the live status-item coordinator.
- Added `scripts/check-ui-fast.sh` for UI iteration. It runs runtime/battery/frozen-boundary checks, the native presentation suite, and a full Xcode build without repeating the long frozen-backend simulations. Every candidate intended for commit/release must still pass `check-all.sh`.

## UI6 product-polish pass

UI6 turns the first technically complete Next23 shell into a configurable product surface aimed at both casual users and experts without widening the frozen hardware-control boundary.

- First launch now shows a one-time 720×500 welcome setup with three starting points: **Simple**, **Balanced**, and **Everything**. They are presets only; users can freely change the menu bar and dashboard afterward. The safe System fan mode and macOS-owned battery policy are explained before the user enters the app.
- The compact 420×600 popover is now **module-driven** rather than permanently showing a Simple/Advanced/All segmented control. Dashboard presets live in onboarding and Settings. Users can add, remove, and reorder System Summary, Cooling, Performance, Network, Top Processes, and System Status modules.
- Duplicate navigation was removed from the popover. There is one Full Monitor action in the header plus a compact overflow menu for Settings/Quit; the old footer and “open all modules” duplication are gone.
- Cooling is intentionally novice-safe in the popover: a short description explains the current mode, a compact menu switches System/Boost/Manual/Automatic, Manual expands an inline RPM slider only when selected, and Automatic exposes status plus a contextual **Edit Rules…** deep-link into Full Monitor → Thermals & Fans. Full expert controls remain in the dedicated monitor page.
- Fanless Macs hide fan controls and are labeled explicitly instead of pretending 0 RPM is a controllable fan. Cross-Mac throttling/thermal-pressure presentation remains a later capability-validation task.
- The menu-bar readout no longer forces selected/highlighted text colors while the popover is open. Telemetry always uses semantic label colors, avoiding the persistent white/inverted appearance seen in UI5.
- Live charts now reuse the existing bounded in-memory history rather than adding new polling. CPU, Memory, GPU, temperature, system power, battery charge/flow, fan RPM, network traffic, and storage throughput can be graphed without another telemetry provider or privileged path.
- Full Monitor pages received a density pass: Memory now has a live graph and visual breakdown; CPU/GPU have utilization history; Thermals, Battery, Storage, Network, Overview, and History expose trend cards while keeping raw/expert diagnostics separate.
- Settings moved from a cramped horizontal tab bar to a sidebar with General, Dashboard, Menu Bar, Cooling, Privacy, Advanced, and About. Dashboard and menu-bar layouts are independently configurable. Dashboard presets are one-shot **Quick presets**, not modes that lock the interface.
- `check-ui-fast.sh` now includes telemetry-history checks because UI6 graphs depend on those samples, then runs native presentation tests and a complete Xcode build. The full `check-all.sh` remains mandatory before a commit/release candidate.

## UI6 completion — configurable product UX

The completed UI6 pass turns the earlier shell into a more opinionated but user-configurable product surface:

- First-run setup defaults to **Balanced** as the recommended starting point while keeping **Simple** and **Everything** one click away. Each card states what will appear in the menu bar, compact dashboard, and Full Monitor. The choice is only a preset; nothing is locked.
- Full Monitor navigation is now user-configurable as well. Overview is pinned as a safe landing page; every other sidebar module can be hidden, restored, and reordered in Settings → Full Monitor. Existing installs retain all routes until the user chooses otherwise.
- Dashboard summary tiles deep-link to the corresponding CPU, Memory, Thermals & Fans, and Battery & Power pages instead of forcing users through a generic monitor landing page.
- Compact Cooling no longer exposes a permanent four-way segmented control. It shows one human-readable current state and a **Change** disclosure. Expanding it reveals explained System/Boost/Manual/Automatic choices, with System explicitly marked Recommended. Manual exposes the RPM slider only while Manual is selected; Automatic exposes rule status and a contextual Edit Rules link.
- The menu-bar button explicitly suppresses AppKit pressed/alternate inversion (`NSButtonCell` transparent/no highlight masks), keeping Helios telemetry visually stable instead of flashing a bright selected background.
- Settings → Menu Bar includes a deterministic layout preview before the user changes the real status item.
- Full-page trend cards now show current/min/max context, while the shared chart renderer adds guide lines, a current-sample marker, and a zero baseline for signed values such as battery charge/discharge power. Dynamic graph ranges no longer incorrectly clamp negative values to zero.
- Memory received a second density pass: live percentage, used/available values, pressure, history, and the existing visual breakdown are visible without leaving large dead areas.
- `check-ui-fast.sh` now uses a focused `--ui-history-only` telemetry path so UI/chart iterations validate rolling-history semantics without executing the entire long telemetry suite. `check-all.sh` remains unchanged as the mandatory full pre-commit gate.

## UI7 final-polish direction

- Menu-bar identity is now an explicit presentation choice: **Labels**, **Symbols**, or **Values only**. Text labels are the fresh-install/onboarding default because CPU/RAM/GPU are immediately legible without learning icon semantics. Identity changes never alter per-module width, so live geometry remains deterministic.
- The shared chart renderer now uses monotone cubic interpolation through the exact sampled points. This produces visually smooth curves without bridging unavailable/stale gaps or inventing new extrema between samples.
- Thermals & Fans is layered for both novices and experts: fan control appears before sensor inventory; identified SoC groups remain visible; raw/unclassified SMC keys are collapsed behind an explicit expert disclosure and retain their warning that they do not feed Max SoC, Cooling Rules, or fan safety.

## UI8 native-module / history architecture

UI8 is the last planned large Next23 UX architecture pass before pixel-level polish and later performance profiling. It keeps the Next22 fan/SMC/XPC and battery-control boundaries frozen while making the menu bar, popups, history, and Battery & Energy surfaces behave like first-class macOS utilities.

- **Native metric status items:** Native Modules is the recommended layout. CPU, Memory, GPU, Temperature, Cooling, Fan, Battery, System Power, and Network can each exist as their own `NSStatusItem`, with a separate optional Helios solar hub. Compact Group remains available for users who want one combined item.
- **Per-module identity:** every metric independently chooses Label, Icon, or Value-only identity and may store a short custom label. Live telemetry never changes an item's width; label edits are configuration changes and rebuild geometry deliberately.
- **Native active pill:** every native metric owns its own transient `NSPopover`. The owning `NSStatusBarButton` is highlighted only while that exact popover is open, then cleared on close/rebuild/switch. Separate popover instances prevent a stale close callback from one metric from clearing another metric's active pill.
- **Reachability:** disabling the final native metric cannot hide the final way back into a menu-bar-only app; the Helios hub is restored/retained as the recovery item.
- **Context popups:** CPU, Memory, GPU, Thermals/Fan, Battery, System Power, and Network open focused 360-point popups with their own trend/context data and a single deep-link into the corresponding Full Monitor route. Memory adds a colored Apps/Compressed/Cache/Available breakdown, swap and top-memory processes.
- **Graph engine v2:** Raw and monotone-Smooth shape are independent from **Animate new telemetry smoothly**. Animation is event-driven (~0.34 s on a new sample), moves the visible timeline and morphs the newest point without changing polling cadence or running a permanent frame timer. Ranges are 1m, 5m, 15m, 1h, 6h, and 24h; every scope remembers its selection.
- **Persistent/live merge:** 1m–24h charts combine the high-frequency in-memory tail with existing 24-hour persistent telemetry. Overlap is de-duplicated by timestamp ordering and long missing intervals stay explicit pen-up gaps. Persistent history now includes optional Memory percent using backward-compatible Codable semantics.
- **Single shared presentation feed:** `StatusItemController` owns one shared `OverviewViewModel`; metric popups, the compact dashboard, and Full Monitor read that model instead of independently accepting/persisting the same snapshot. This makes history useful even when windows are closed without multiplying writes when several UI surfaces are open.
- **Battery remaining fallback:** authoritative macOS/IOPowerSources time wins whenever valid. While macOS reports Calculating, Helios may derive an explicitly approximate `≈` ETA from read-only remaining capacity/voltage and recent discharge power, with current electrical telemetry only as a fast fallback. Implausible or insufficient data stays Calculating.
- **Battery & Energy:** Battery popup and Full Monitor expose SoC, signed battery flow, health/cycles/temperature, selected-range graphs, and selected-range relative per-app energy attribution. Process energy remains descriptive and may omit inaccessible/system processes; do not present it as billing-grade joules. Battery remains telemetry-only and macOS-managed.
- **Branding:** the generic SF sun is replaced in primary Helios branding surfaces by a small custom SwiftUI solar mark (flat circular core with eight restrained rays); status-bar hub rendering has a monochrome equivalent. Keep it simple and legible at menu-bar scale.
- **Fail-fast validation:** `check-ui8-portable.sh` typechecks/runs the actual ETA engine against exact-shape stubs and probes the real persistent/live chart merge before native AppKit/SwiftUI compilation. `check-ui-fast.sh` runs runtime/battery/frozen-boundary guards, preference definite-init, UI8 portable semantics, native presentation compilation/renders, focused history semantics, then full Xcode build. `check-all.sh` adds the long frozen backend suites and remains mandatory before a freeze/commit.


## UI8 fixed1 runtime polish

- Native metric popovers retain the macOS selected pill but add defensive outside-click and Escape dismissal monitoring on top of `NSPopover.transient`.
- Metric popovers no longer repeat the Helios brand mark; branding remains in the dashboard/onboarding/About surfaces.
- Full Monitor defaults to denser geometry and avoids stretching CPU/Memory summary values across large empty spaces.
- Raw/Smooth and live-animation preferences live in Settings → Graphs & History; Full Monitor keeps only the per-module time-range selector.
- Raw/Smooth replaces the whole visible chart rendering immediately.
- Live chart animation stages a newly appended point at the previous visible value and moves the time axis/end point together, avoiding an immediate topology jump followed by a cosmetic animation.

## UI8 fixed2 presentation polish

- Metric popovers use bounded, scroll-safe geometry with a fixed header/footer. Escape dismissal is routed through a key AppKit hosting responder (`cancelOperation`/`onExitCommand`) in addition to transient/outside-click behavior; no Accessibility permission is required.
- Memory's menu-bar popup is purpose-built instead of reusing the generic history-chart layout: a 270° usage gauge, memory-pressure state, Used/Available/Swap summary, Apps/Compressed/Cache/Available detail tiles, and top-memory processes. The Full Monitor keeps its history graph and now uses the same gauge as the summary anchor.
- Live chart motion moved from SwiftUI per-point interpolation to one native AppKit backing surface. On a fresh sample the final frame is drawn once and Core Animation translates the complete layer by the elapsed fraction of the visible time range. The animation is event-driven, linear, Reduce-Motion aware, and does not raise polling frequency or run a permanent display timer.
- Dynamic positive-only charts keep a zero baseline and use coarse 1/2/5×10ⁿ scale ceilings with headroom. The scale expands only when required during a range session, reducing visual jumps caused by autoscaling while preserving spikes. Long ranges remain width-decimated with min/max preservation and explicit telemetry gaps.
- Battery & Energy now has an explicit Energy Attribution section with app identity, ranked tracked share, observed on-battery coverage, and optional previous-hour trend context. The wording remains diagnostic/relative: per-process attribution is not represented as billing-grade energy measurement and inaccessible/system processes can be absent.
- External open-source utilities may be reviewed during development for UX/architecture research, but Helios keeps an independent implementation. Development references are not shown as product chrome unless a license actually requires an acknowledgement.

### UI8 fixed2 thermal inventory + menu-popover cost guard

- Opening a metric status item is presentation-only: it no longer performs an explicit service-registration/XPC refresh. The shared live model now publishes one 1 Hz snapshot invalidation per telemetry tick; its in-memory history is appended synchronously without a second `@Published` invalidation. Metric popovers also do not observe the unrelated three-second service-registration monitor, and dashboard sparklines are bounded to the recent live tail instead of reprocessing the full hour buffer on every redraw.
- Thermal sampling is split by trust level. Curated M4 SoC keys that feed Max SoC/Cooling Rules retain the existing fast cadence. The much larger raw/unclassified inventory is diagnostic-only and refreshes about every 15 seconds, with its own capture timestamp shown in expert UI. This reduces SMC read volume without weakening the safety path or pretending cached raw values are freshly sampled.
- The menu-bar temperature remains **trusted Max SoC**, computed only from the curated M4 CPU/GPU keys already covered by the Next22 safety tests. Raw/auxiliary SMC keys never silently become Cooling Rules, health, or emergency inputs.
- Thermals & Fans now classifies the diagnostic inventory into trusted SoC groups, corroborated/community auxiliary channels, virtual/derived channels, placeholder-like low Ta0* clusters, and truly unknown raw keys. Friendly labels are explicitly advisory because Apple does not publish most Apple-Silicon SMC meanings.
- `TCMz` is shown as the community-mapped **CPU die maximum** but remains advisory. `TVmS`/`TVms` and related exact keys are community-mapped virtual-memory channels; an observed uppercase `TVMS` is only identified as a **TVM* virtual/derived family** because SMC key case is significant and that exact variant is not asserted. Repeated Ta0* readings clustered around an implausibly low value are labeled **placeholder-like**, preserved raw, and excluded from safety decisions.
- Additional display-only family grouping covers community-catalogued SoC thermal-diode (`TD0*`/`TD1*`/`TD2*`), board-diode, power-delivery, RF-delivery, memory, battery, storage/heatsink, ambient/airflow, and unvalidated processor/GPU-family channels. Family classification is descriptive only; exact undocumented roles are not invented.

## UI8 fixed3 compile-contract stabilization

- `HeliosEscapableHostingView` now explicitly implements SwiftUI/AppKit's required `NSHostingView.init(rootView:)` in addition to Helios' richer `rootView:onCancel:` initializer. The required path installs a no-op cancel closure, while production popovers keep the explicit dismissal closure.
- The Next23 fail-fast boundary now checks this required initializer contract before the expensive native Xcode/presentation gate, so an SDK-required-initializer regression is caught immediately.

## UI9 interaction and visualization polish

- The validated UI8 fixed3 runtime foundation is preserved: metric popovers remain transient/keyboard-dismissible and opening them does not add synchronous telemetry or helper work. The Next22 fan/XPC/SMC/BatteryProvider freeze is still byte-identical.
- The shared AppKit graph renderer now separates sampled telemetry from presentation. Raw draws straight segments through the exact samples; Smooth redraws the same complete history with monotone geometry only. A real new sample stages the final path one sample-width to the right and Core Animation glides it into place over the observed sampling interval without increasing telemetry cadence or fabricating intermediate measurements.
- Every graph has a native hover inspector with a vertical guide, highlighted real sample, timestamp, and unit-aware exact value. Reduce Motion still disables live sliding; hover never changes the stored samples.
- Compact popovers use a clear history-range menu (`1 min` through `24 hours`) instead of the ambiguous circular-refresh symbol. Full Monitor retains the roomy segmented range control, and both bind to the same per-scope persisted range.
- Memory uses one exclusive physical composition model: App + Wired + Compressed + Available always partition physical memory. Reclaimable cache stays visible as diagnostic context but is not falsely counted as a fifth physical segment. The 270° gauge and breakdown share the same colors and percentages.
- The Thermals popup pairs Max SoC and fan state/control, with separate temperature and fan-speed charts. Raw/advisory SMC inventory remains confined to Full Monitor expert diagnostics and stays out of fan safety.
- Battery & Energy adds a selected-period summary above the existing battery details and relative per-app attribution, answering both “what changed in this window?” and “which tracked app contributed most?” without adopting OpenMacBattery source code or presenting relative process energy as billing-grade measurement.
- Menu-bar presentation is independently configurable per metric: Icon, Label and Value can each be enabled or disabled. An invisible status item is rejected by normalization (Value is restored), while removing the module remains an explicit action. Legacy Label/Icon/Value-only settings are retained as migration compatibility.
- First-run setup now offers four starting points — Simple, Recommended, Detailed and Custom — in a 2×2 layout. They remain one-shot starting configurations; all menu-bar, dashboard, Full Monitor and graph choices are editable later in Settings.


## UI10 modular foundation and final-polish direction

- The moving chart viewport uses a near-edge-to-edge plotting aperture. Continuous motion never draws a permanent newest-sample bead; the exact sample marker belongs to hover inspection, while discrete/non-animated mode may retain a frontier dot.
- Full Monitor is responsive instead of being locked to the former narrow content column. Standard content can grow to a bounded desktop width and overview/trend cards use adaptive grids, so fullscreen and smaller windows both remain intentional rather than producing large dead bands.
- Energy is a first-class Full Monitor route and a visible Quick Dashboard destination. The dedicated Energy Inspector remains available for focused per-app analysis rather than being the only way to discover historical energy attribution.
- Quick Dashboard composition is user-owned. The System Summary has independently reorderable/optional CPU, Memory, GPU, Temperature, Battery, Energy and Power metrics; dashboard modules themselves are also reorderable/optional.
- Full Monitor sidebar modules remain independently reorderable/optional. A separate Detailed Content preference controls whether expert-density per-core/process/diagnostic blocks are exposed by default. Detailed and Custom onboarding presets enable that density; Simple intentionally does not. No preset locks later customization.
- Graph/gauge colors are semantic persisted preferences for all primary modules and data series, not a RAM-only feature. Safety/health severity colors remain semantic rather than user-customizable.
- Public About UI contains Helios identity/version/project links and its safety/privacy boundary; development inspiration research is not displayed as product chrome when no imported code/license requires it.
- UI10 still does not widen the Next22 privileged/helper/battery boundary.

## UI10 Final RC4 — visual freeze candidate

RC4 is intentionally bugfix/polish-only before the performance optimization phase.

- Continuous time-series charts keep an exact selected time range while retaining real predecessor samples on an oversized offscreen plot canvas. The animation distance is bounded by that real overscan, so the outgoing line stays present until it crosses the fixed left clip instead of exposing a blank strip. Continuous mode has no permanent frontier bead; hover remains sample-exact.
- Telemetry collection and presentation layout are independent. Turning CPU/network/etc. collection off never deletes menu-bar, Quick Dashboard, or Full Monitor placement; re-enabling the sampler resumes the same layout without restarting Helios. A one-time schema-11 development migration repairs the RC1–RC3 CPU sidebar-loss state and persists the repair before advancing schema.
- Cooling opt-out hides fan/helper-facing presentation without destroying the remembered cooling-card/menu-bar position. Re-enabling cooling restores the prior surface placement.
- Quick Dashboard customization now lives at the bottom of the dashboard instead of crowding the title-bar controls. Dashboard, Full Monitor, and menu-bar layouts all retain explicit reset affordances.
- Common two-line menu-bar metrics use one optical slot grid and a bounded spacing control, avoiding live-value geometry changes and the previous CPU/RAM/TEMP irregularity.
- Full Monitor falls back to Overview if the user explicitly hides the currently selected route, preventing an invisible sidebar selection.

The validated Next22 fan daemon/control/XPC/SMC and battery provider remain frozen. After RC4 passes the native macOS gate and runtime acceptance, Next23 UI should be visually frozen and work should move to profiling/optimization rather than another redesign.

## UI10 Final RC5 — complete telemetry presentation and lifecycle polish

RC5 remains a presentation/application-lifecycle pass over the frozen Next22 hardware boundary. No validated fan daemon/control, XPC, SMC, or battery-provider implementation is changed.

- Settings → General exposes **Simple / Recommended / Detailed / Custom** as a complete interface preset selector. Detailed enables all normal telemetry collectors, every Full Monitor route, and per-route complete diagnostic blocks. Structural manual edits move the selector to Custom without discarding the user's layout.
- Full Monitor → Expert → **All Diagnostics** intentionally exposes every telemetry value the frozen backend retains and publishes to the app layer. Focused CPU, Memory, GPU, Thermals/Fans, Battery, Energy, Storage, Network, Processes, System, Devices, History, and Health pages also append their complete published model when Detailed content is enabled.
- Complete storage diagnostics restore physical-device counters, read/write operations/errors, NVMe SMART health, 128-bit raw counter halves, lifetime read/write totals, power cycles, power-on hours, unsafe shutdowns, media errors, error-log entries, current throughput, process-attributed I/O, and the 24-hour physical I/O audit.
- Complete process diagnostics expose every bounded list plus PID/path, physical/neural footprint, CPU/power/performance-core power, disk rates, wakeups, instruction/cycle counters, IPC, and session I/O for each published process entry. Equivalent complete blocks exist for network/Wi-Fi, battery/electrical/cells, devices, power assertions, clocks, histories, health events, capabilities, sampler timestamps, raw numeric SMC inventory, and the existing on-demand Maintenance scans.
- `check-detailed-ui-coverage.sh` statically audits the frozen app-published telemetry model surface so a future UI refactor cannot silently drop a stored/derived field without failing the RC gate. Internal transient parser/rate-calculator scratch state is not a retained metric and would require a backend change, so it remains outside this presentation-only contract.
- Read-only fan RPM collection is independent from fan-control opt-out. Disabling Cooling removes helper-facing write controls but does not silently stop RPM telemetry. The menu bar offers a combined **Temperature & Fan** module as well as separate Temperature/Fan choices.
- Native menu-bar slots use content-derived fixed worst-case widths. At 0 pt spacing Helios adds no own outer padding; macOS still controls separation between independent native status items. **Single compact group** remains the tightest layout.
- Startup/removal controls now distinguish app login launch from the root helper. The helper card exposes its RunAtLoad registration state and explicit Install/Reinstall/Uninstall actions. Removal can optionally erase local Helios preferences/history after returning fans to System, disabling app login launch, and unregistering the helper; Helios never attempts to delete its own app bundle.


## UI10 RC7 bugfix polish

- Fixed the strict Swift 6 IPC check by explicitly consuming the Boolean result returned by the concurrent helper-uninstall task. This is test-only and does not change the frozen daemon/helper implementation.
- Metric popovers now clip their scrolling content beneath the fixed native header/footer.
- Dismissing the one-time fan-control safety alert recreates the metric popover scroll surface at its canonical top position, preventing the focused cooling control from leaving the hero telemetry partially drawn under the header.
- The fan safety guide, validated factory-range wording, 95°C helper guard description, and frozen fan-control backend remain unchanged.

## UI10 RC8 — exhaustive diagnostics polish

RC8 keeps the 462-field backend-published telemetry coverage but replaces the permanently expanded full-width diagnostic dumps with compact expandable panels. Normal route summaries remain primary; advanced diagnostics are clearly labeled and collapsed by default. Storage devices are presented as device cards, thermal/raw SMC sensors use compact grouped grids, per-process rankings use reusable process cards, and energy history groups retained app identities by display name while preserving every raw app key. This is presentation-only: the Next22 backend, sampling cadence, fan control, XPC/SMC and BatteryProvider remain unchanged.
