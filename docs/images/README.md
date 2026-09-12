# Helios images and capture provenance

## Live screenshots — 2026-09-12

The maintainer supplied these live captures from the **current Helios pre-beta
working tree before the final documentation commit**, on the **base M4 14-inch
MacBook Pro**. An exact capture commit was not supplied; no commit hash is inferred
from HEAD. The About capture shows version **0.1.0 (1)**; Full Monitor shows
**Apple M4 · macOS 26.6.2 (25G83)**.

The app windows use **dark appearance**. The narrow menu-bar capture visibly has
a light background and dark monochrome glyphs, so it is named `menu-bar-light.png`.
Monitoring screenshots contain **live telemetry**; Settings/About show configuration
and project information. They illustrate the UI only and **do not prove universal
hardware compatibility**, fan-write eligibility or clean-machine installation.

All nine supplied PNGs were renamed without changing their bytes, dimensions,
telemetry, colors or visible text. No fixture render is presented as a live capture.
Original names began `Snímek obrazovky 2026-09-12`; the table records their time suffixes.

| File | Original time suffix | Pixels | Bytes | Purpose |
| --- | --- | --- | ---: | --- |
| [dashboard-dark.png](dashboard-dark.png) | v 17.02.05.png | 984 × 1344 | 565,721 | README: Quick Dashboard; System control |
| [full-monitor-overview-dark.png](full-monitor-overview-dark.png) | v 17.02.47.png | 3248 × 2122 | 994,507 | README: Full Monitor Overview |
| [thermals-fans-system-dark.png](thermals-fans-system-dark.png) | v 17.03.19.png | 3248 × 2122 | 974,042 | README: primary cooling view; System selected |
| [thermals-fans-auto-rules-dark.png](thermals-fans-auto-rules-dark.png) | v 17.03.26.png | 3248 × 2122 | 1,003,719 | Secondary: Auto Rules editor on this validated host; not a recommended default |
| [settings-modules-dark.png](settings-modules-dark.png) | v 17.03.52.png | 1664 × 1328 | 581,251 | README: Modules / Data Collection |
| [settings-colors-dark.png](settings-colors-dark.png) | v 17.04.05.png | 1664 × 1328 | 557,763 | Secondary: Graphs & Colors customization |
| [energy-inspector-empty-dark.png](energy-inspector-empty-dark.png) | v 17.04.29.png | 1864 × 1464 | 463,845 | Installation troubleshooting: no on-battery history; excluded from README showcase |
| [about-dark.png](about-dark.png) | v 17.24.42.png | 1664 × 1328 | 493,312 | README: About with official app icon; visible version 0.1.0 (1) |
| [menu-bar-light.png](menu-bar-light.png) | v 17.25.54.png | 474 × 68 | 54,345 | Installation reference: compact metric items and monochrome sun on a light menu-bar background |

## Curation decisions

- The fresh Dashboard replaces the old `dashboard-dark.png` whose capture provenance was unknown.
- The fresh menu-bar strip replaces the old `menu-bar-dark.png`; the old file was removed.
- The live empty-state Energy Inspector replaces the old `energy-inspector-dark.png`
  of unknown provenance. The old file was removed. The new image is useful for
  troubleshooting initial history, but is not a main feature showcase.
- **System mode is the primary public cooling screenshot.** The
  [Auto Rules image](thermals-fans-auto-rules-dark.png) documents the editor only;
  those rules are not a universal configuration or the default recommendation.
- [Colors](settings-colors-dark.png) is retained as a distinct customization view
  outside the curated README gallery.
- No Privacy & Diagnostics screenshot was in the supplied set. No other image is
  relabeled to fill that role. The README explains privacy in text and links to
  the existing diagnostics documentation.

## Branding

The seven existing images in `branding/` are preserved artwork, not screenshots:
`helios-symbol-{light,dark,transparent}.png`,
`helios-lockup-{light,dark,transparent}.png` and `helios-social-preview.png`.
Their creation date/method is not recorded here.

The README hero references the existing 256-pixel app-icon PNG directly from
[AppIcon.appiconset](../../Resources/Assets.xcassets/AppIcon.appiconset/).
That catalog, including the 1024-pixel source, remains unchanged. No documentation
copy, crop, recoloring or regeneration was needed.

## Future captures

Capture the intended build and record date, app version/build, machine, appearance
and commit when available. Review visible content for serial numbers, paths,
addresses and private process/document names before publishing. Keep original
resolution for readable text, descriptive lowercase filenames and useful alt text.
Do not install/approve a helper, send diagnostics or change fan control just to
obtain a screenshot. System remains the recommended cooling mode.

`./scripts/check-presentation.sh` writes native **fixture renders** to ignored
`.build/Presentation`. They are layout-test evidence, not live captures.
