# Phase 2.1 — UI & Presentation Polish

The existing Phase 2 read-only data providers are unchanged. This phase replaces the menu-bar string and diagnostic popover, using the supplied Stats/TG Pro screenshots as visual references. It adds no fan controls, SMC writes, daemon IPC, or service registration.

## Fixed-width status item

`StatusItemController` creates an `NSStatusItem` with an explicit length of **80 points**. `MenuBarView` draws inside two fixed 40-point columns; neither intrinsic text size nor changing values can resize the item. CPU has an 8-point caption, and the right column has the `thermometer.medium` SF Symbol. Values use 11-point semibold monospaced digits in fixed 36 × 14-point text rectangles. This reserves enough room for `100%` and `150°C`, as well as one-digit values and unavailable dashes.

The native `NSStatusBarButton` handles clicks and the popover action. The drawing view passes hit testing through to that button. Highlighting, semantic light/dark colors, tooltips, and a combined VoiceOver label/value are retained. Redrawing occurs only when the displayed rounded values change; the status item's length is never reassigned from text.

## Popover

A lazily created, retained SwiftUI view replaces multiline debug labels. It updates from the existing monitor only while the popover is open. The popover has a fixed 380-point width and a 700-point preferred height, capped to available display height, with scrolling for shorter displays.

- **Thermals & Cooling:** prominent Max SoC, then aligned Average/Max columns for P-Cores, E-Cores, and GPU clusters. No raw key dumps or physical-core-count claims. Averages include the available sensors in that group; a missing group displays a dash with failure details in help/accessibility.
- **CPU & Memory:** CPU total, muted User/System/Nice/Idle breakdown, a labeled kernel pressure badge, and aligned Active/Wired/Inactive/Compressed/Free/Physical memory values. Pressure remains an independent native measurement.
- **Battery & Power:** battery charge/discharge/idle watts with instantaneous/averaged labeling, raw health and capacities, cycle count, and cell temperature. Total System Power stays separately labeled Unavailable, including when battery telemetry is missing.

Cards use semantic native colors, 12-point internal padding, rounded borders, bold section titles, and subtle horizontal dividers. Numeric values use monospaced digits. Typed failures and the existing freshness limits are preserved; detailed error codes are available through help and accessibility instead of the main layout.

## Verification

Run from the repository root:

```sh
./scripts/check-presentation.sh
./scripts/check-telemetry.sh
```

Presentation checks exercise actual `MenuBarView` updates with one-, two-, and three-digit percentages/temperatures, the 150°C reader bound, unavailable values, and stale samples. They verify an unchanged 80-point frame/intrinsic width, glyph fit within each fixed text rectangle, and click-through behavior. Native AppKit status renders are produced at 1× and 2× scale. Group-average checks verify that unrelated sensors are excluded and that a missing group does not become a zero average.

SwiftUI's native `ImageRenderer` produces light/dark card fixtures for normal, unavailable, and partial data. These are rendered from the same card views as the live popover; they are illustrative fixture values, not current measurements from the Mac. The normal card stack is 678 points high and the partial/unavailable stack is 698 points high at 380 points wide. Rendered text, spacing, missing-value states, and pressure colors were visually inspected.

Generated previews (ignored by git):

- [Dark cards](../.build/Presentation/popover-normal-dark.png)
- [Light cards](../.build/Presentation/popover-normal-light.png)
- [Partial sensor data](../.build/Presentation/popover-partial-dark.png)
- [Unavailable data](../.build/Presentation/popover-unavailable-light.png)
- [One-digit status](../.build/Presentation/status-one-digit-2x.png)
- [Three-digit status](../.build/Presentation/status-three-digit-2x.png)

The existing telemetry regression suite passes. Hash comparison confirms all eight telemetry files, the daemon source, and `DaemonService.swift` are byte-for-byte unchanged from the start of Phase 2.1.

Debug and Release builds use Swift 6 complete concurrency checks with warnings treated as errors, the installed macOS 26.5 SDK, the macOS 13 deployment floor, and approved ad-hoc signing. Signature verification covers the app and its unchanged embedded helper. Build output and check logs are kept in `.build/Verification`. The existing non-fatal Xcode App Intents/simulator diagnostics are unrelated to Swift compilation.

Seven identified Helios artifacts were removed from `/tmp`: the Phase 1/2 build/check logs and a temporary research reference image. No unrelated temporary files were removed. New renders, compiler caches, and logs stay inside ignored `.build` directories.

Native fixture rendering does not exercise WindowServer placement among other menu-bar utilities, menu relocation between displays, or screen-reader navigation. Those remain interactive checks after relaunching the rebuilt app. This task does not replace an already running older Helios process. No new telemetry/performance or privileged-service claims are made in this UI phase.
