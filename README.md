<div align="center">

<img src="Resources/Assets.xcassets/AppIcon.appiconset/helios-appicon-256.png" alt="Helios official application icon" width="96" height="96">

# Helios

**Know what your Mac is doing.**

A menu-bar Mac doctor for Apple Silicon: what your Mac is doing, why, and how it
holds up over the years, with carefully gated fan controls.

**[⬇ Download Helios 0.3.0 Beta 2](https://github.com/Snejdik/helios/releases/tag/v0.3.0-beta.2)**

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111111?logo=apple&logoColor=white)
![Apple Silicon / arm64](https://img.shields.io/badge/Apple%20Silicon-arm64-111111)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Beta](https://img.shields.io/badge/status-beta-orange)
[![PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue)](LICENSE)

[Installation guide](docs/INSTALLATION.md) · [How it works](docs/HOW_IT_WORKS.md) ·
[Build from source](docs/BUILDING.md) ·
[Report a bug](https://github.com/Snejdik/helios/issues) ·
[Buy Me a Coffee](https://buymeacoffee.com/snejda)

</div>

Helios tells you whether your Mac is OK, what is happening and why. Open the
menu-bar popover for a quick answer, or the main window for charts, processes,
sensors, battery, energy and longevity. Ask it why the Mac is slow, hot or draining
the battery, or why the Wi-Fi crawls, and it shows what it sees and what you can do.
The details are always one step away, never in the way.

<p align="center">
  <a href="docs/images/popover-overview-dark.png"><img src="docs/images/popover-overview-dark.png" alt="Helios menu-bar popover: Your Mac is doing well, with four health areas, a CPU chart, the busiest apps, cooling, network and Keep Awake" width="300"></a>
  &nbsp;
  <a href="docs/images/popover-cooling-dark.png"><img src="docs/images/popover-cooling-dark.png" alt="Cooling popover with temperature, fan and System, Boost, Manual and Auto modes" width="300"></a>
</p>

<p align="center">
  <a href="docs/images/menu-bar-dark.png"><img src="docs/images/menu-bar-dark.png" alt="Helios menu-bar items: CPU, RAM, fan state over average and hottest temperature, power, and the Helios sun" width="420"></a>
</p>

> **Helios is in beta: this is an external test build.** It is not notarized, and it is
> tested on one M4 MacBook Pro. Monitoring works on every Apple Silicon Mac and adapts to
> what yours exposes. **Fan control is experimental on every other Mac, off until you turn
> it on, and System (macOS) is always the recommended mode.**

## What you get

| | |
| --- | --- |
| **Overview & Why?** | One honest answer for your Mac, four health areas, and *Ask Helios*: slow Mac, hot or loud, battery drain, cannot sleep, unexpected restart, slow Wi-Fi, disk filling up. |
| **Longevity** | Battery wear and charging habits, power adapter and cable, SSD writes and endurance, cooling compared with the Mac's first weeks, memory and swap. Words, not a score; estimates marked as estimates; a weekly report to export. |
| **Menu bar** | Live items you choose (CPU, memory, temperature, power, cooling…) and a compact popover with Keep Awake. |
| **CPU, memory, GPU** | Per-core activity, memory pressure and breakdown, swap, GPU load where available. |
| **Thermals & cooling** | Average and hottest temperature with the status of each sensor map, fan speed, and optional fan control: Boost, Manual or your own Automatic curve. |
| **Battery & Energy** | Health, cycles and power flow, plus which apps use the most energy, compared with the period before. |
| **Network** | An on-demand check of Wi-Fi, router, DNS and internet that says where it is slow, Wi-Fi channel crowding and drops, and optional latency history and data usage per app (kept on your Mac). |
| **Tools** | Keep Awake (for a while, while on power, until an app quits), a command palette (⌃⌥⌘Space), simple rules, "tell me when it's done", `helios://` links, a command line and Shortcuts. Experimental mouse settings: reverse only the scroll wheel, scroll distance per notch. |
| **Activity & History** | A timeline of health events, power changes and peaks, with history charts. |
| **Checkup** | What Helios found, what would let it see more, and what it can read right now, down to every raw value. |
| **Storage & Hardware** | Free space, SSD health, throughput, what this Mac is, what is connected and every raw reading. |
| **Alerts** | Optional notifications with thresholds you can edit. They only inform; they never change fan control. |

Some readings depend on your Mac and macOS. An unavailable reading is shown as
unavailable, never as zero.

## A look inside

<a href="docs/images/overview-dark.png"><img src="docs/images/overview-dark.png" alt="Helios Overview with the four health areas, a live CPU chart, Ask Helios, Keep Awake, Tell me when it's done and the Longevity row" width="760"></a>

<details>
<summary><strong>Ask Helios and Longevity</strong></summary>

Pick a question and Helios answers with what it sees, why it thinks so and what you can do.

<a href="docs/images/overview-ask-dark.png"><img src="docs/images/overview-ask-dark.png" alt="Ask Helios answering why the Mac is slow: macOS closed apps for memory, and Low Power Mode is on" width="760"></a>

Longevity grades the battery, power adapter, SSD, cooling and memory in words, with the facts behind each grade.

<a href="docs/images/longevity-dark.png"><img src="docs/images/longevity-dark.png" alt="Longevity page: grades for battery, power adapter, SSD, cooling and memory, and the battery health trend" width="760"></a>

<a href="docs/images/longevity-details-dark.png"><img src="docs/images/longevity-details-dark.png" alt="Longevity details: power adapter and cable, SSD endurance, memory pressure and swap, and the two optional reminders" width="760"></a>

</details>

<details>
<summary><strong>Network and Checkup</strong></summary>

<a href="docs/images/network-dark.png"><img src="docs/images/network-dark.png" alt="Network page with Why is the internet slow, optional data usage per app, latency over time and download and upload charts" width="760"></a>

<a href="docs/images/checkup-dark.png"><img src="docs/images/checkup-dark.png" alt="Checkup page: what Helios found, what it can read, helper and fan control status, all readings and support" width="760"></a>

</details>

<details>
<summary><strong>Thermals and your own fan curve</strong></summary>

Drag points on the curve, or type exact values. The curve is kept separately for
power adapter and battery. Above your speed limit Helios hands the fans back to
macOS.

<a href="docs/images/fan-curve-dark.png"><img src="docs/images/fan-curve-dark.png" alt="Automatic cooling with an editable temperature to fan speed curve" width="760"></a>

<a href="docs/images/thermals-dark.png"><img src="docs/images/thermals-dark.png" alt="Thermals page with temperature history, sensor groups and cooling modes" width="760"></a>

</details>

<details>
<summary><strong>CPU, GPU and memory</strong></summary>

<a href="docs/images/cpu-dark.png"><img src="docs/images/cpu-dark.png" alt="CPU page with per-core usage and temperatures" width="760"></a>

<a href="docs/images/gpu-dark.png"><img src="docs/images/gpu-dark.png" alt="GPU page with device, renderer and tiler utilization" width="760"></a>

<a href="docs/images/memory-dark.png"><img src="docs/images/memory-dark.png" alt="Memory page with pressure, breakdown and swap" width="760"></a>

</details>

<details>
<summary><strong>Battery, energy and activity</strong></summary>

<a href="docs/images/battery-dark.png"><img src="docs/images/battery-dark.png" alt="Battery page with health, capacity, power and health over time" width="760"></a>

<a href="docs/images/energy-dark.png"><img src="docs/images/energy-dark.png" alt="Energy page with ranges, the apps using the most energy and a selected-app detail" width="760"></a>

<a href="docs/images/activity-dark.png"><img src="docs/images/activity-dark.png" alt="Activity timeline of health events, power changes and daily peaks" width="760"></a>

</details>

<details>
<summary><strong>Popovers</strong></summary>

<a href="docs/images/popover-cpu-dark.png"><img src="docs/images/popover-cpu-dark.png" alt="CPU popover with cores, load and temperature" width="280"></a>
&nbsp;
<a href="docs/images/popover-memory-dark.png"><img src="docs/images/popover-memory-dark.png" alt="Memory popover with pressure and breakdown" width="280"></a>
&nbsp;
<a href="docs/images/popover-power-dark.png"><img src="docs/images/popover-power-dark.png" alt="System power popover" width="280"></a>

</details>

<details>
<summary><strong>Settings</strong></summary>

<a href="docs/images/settings-general-dark.png"><img src="docs/images/settings-general-dark.png" alt="General settings with goals, units and updates" width="660"></a>

<a href="docs/images/settings-modules-dark.png"><img src="docs/images/settings-modules-dark.png" alt="Modules: what Helios collects and what it costs" width="660"></a>

<a href="docs/images/settings-menu-bar-dark.png"><img src="docs/images/settings-menu-bar-dark.png" alt="Menu bar layout and visible metrics" width="660"></a>

<a href="docs/images/settings-cooling-dark.png"><img src="docs/images/settings-cooling-dark.png" alt="Cooling settings with helper status and experimental fan control" width="660"></a>

<a href="docs/images/settings-privacy-dark.webp"><img src="docs/images/settings-privacy-dark.webp" alt="Privacy and diagnostics settings, all sharing off by default" width="660"></a>

<a href="docs/images/settings-notifications-dark.png"><img src="docs/images/settings-notifications-dark.png" alt="Notification thresholds" width="660"></a>

<a href="docs/images/settings-graphs-colors-dark.png"><img src="docs/images/settings-graphs-colors-dark.png" alt="Graph style, default ranges and colors" width="660"></a>

<a href="docs/images/settings-automation-dark.png"><img src="docs/images/settings-automation-dark.png" alt="Automation settings: rules, the command palette and the command line" width="660"></a>

<a href="docs/images/settings-advanced-dark.png"><img src="docs/images/settings-advanced-dark.png" alt="Advanced settings: reset, the experimental mouse settings and uninstall" width="660"></a>

</details>

Captures from a MacBook Pro with Apple M4. Select an image to see it in full size.

## How it works

Helios is two programs.

- **Helios.app** runs as you. It only reads: sensors, system counters and its own
  local history.
- **A small helper** exists only for fan control and is optional. It is fan-only,
  accepts requests from the signed Helios app alone, and gives the fans back to
  macOS the moment anything looks wrong: the app stops responding, the Mac sleeps,
  Helios quits, the helper restarts or it gets too hot.

Helios never cools *less* than macOS. It adds cooling on top, within a speed limit
you set, and macOS stays in charge otherwise.
[Read the full explanation →](docs/HOW_IT_WORKS.md)

## Install the beta

1. Download **Helios-0.3.0-beta.2.dmg** from
   [GitHub Releases](https://github.com/Snejdik/helios/releases/tag/v0.3.0-beta.2).
2. Open it and drag **Helios** to Applications. If you got a ZIP, unzip it first.
3. Open Helios from Applications and look for it in the menu bar.

The build is **not notarized** (Helios has no paid Apple Developer ID yet), so macOS
may block the first launch. Open **System Settings → Privacy & Security → Open
Anyway**. The [installation guide](docs/INSTALLATION.md) walks through it, the
optional helper approval, troubleshooting and removal (**Settings → Advanced → Uninstall Helios**).

**Updating?** Quit Helios, replace the app in Applications with the new one and open it.
A short *What's New* window appears once. If you use fan control, click **Reinstall Helper**
there (or in **Settings → Cooling**) and approve it; a new version changes the helper's
signature, and 0.3.0 also changes how the app and helper talk to each other. Until then macOS
manages the fans and monitoring works as usual. Experimental fan control stays off until you
turn it on in Settings → Cooling.

GitHub's **Code → Download ZIP** is source code, not the app. To build it yourself,
see the [developer guide](docs/BUILDING.md) or ask [support](mailto:helios@snejda.cz).

## Compatibility and cooling safety

- **Apple Silicon only, macOS 13 or later.**
- Monitoring works on every Apple Silicon Mac; unavailable sensors are simply marked.
- Temperatures: verified on M4 Macs. On M1, M2, M3, M5, M6 and A18 Pro they come from a
  public sensor catalogue, and Helios checks each map on your Mac during normal use. Until
  it is confirmed, a temperature is labelled as such and never raises alerts or drives Auto.
- Fan control is **validated on one M4 MacBook Pro and experimental everywhere else.** You
  turn it on yourself, for your exact Mac model and macOS version; on an experimental Mac a
  20-second fan test runs first, the speed limit is 70 % and there is no Boost.
- Installing the helper does not by itself make a Mac fan-controllable.
- Battery charging is always left to macOS.

See the [support matrix](docs/APPLE_SILICON_COMPATIBILITY.md) for every chip and [security information](https://www.snejda.cz/helios/security) for the
protection boundaries.

## Privacy

Monitoring history, longevity records, network checks and data usage per app stay on
your Mac. Helios may ask GitHub for the latest release
(Settings → General: never, daily, weekly or monthly); that request contains
nothing about your Mac.

**Diagnostics are off by default.** If you opt in, reports contain only coarse
categories, you can read exactly what is sent first, and manual reports need a
separate Send. A weekly compatibility report (which sensors and fans the Mac has and
what they read) and fan-control statistics are separate opt-ins. Microphone access is
never requested.

[Privacy information](https://www.snejda.cz/helios/privacy) ·
[Diagnostics information](https://www.snejda.cz/helios/diagnostics)

## Bugs, questions and support

[Open a GitHub issue](https://github.com/Snejdik/helios/issues/new/choose) for a
reproducible bug. Please include the Helios version (Settings → About), your Mac
model, macOS version, what you did and what happened, and review screenshots for
personal information first.

Helios is tested mostly on one M4 MacBook Pro. If you have another Mac, turning on the
weekly compatibility report (Settings → Privacy & Diagnostics) is the easiest way to help
it work well there.

For private or security-sensitive reports, write to
[helios@snejda.cz](mailto:helios@snejda.cz).

Helios is independently developed by Jakub Šnejda. If it helps you,
[Buy Me a Coffee](https://buymeacoffee.com/snejda).

## Roadmap

Next up: testing on more Macs through compatibility reports and confirming the sensor maps
for every chip. See the [roadmap](docs/ROADMAP.md).

## For developers

[Building Helios](docs/BUILDING.md) covers Xcode, local signing and the regression
gate. The app uses Swift 6, AppKit and SwiftUI with no third-party runtime
packages. `Sources/HeliosApp` is the app, `Sources/HeliosDaemon` the fan-only
helper and `Sources/Shared` the shared contracts. The canonical check is:

```sh
./scripts/check-all.sh
```

## License and notices

Helios original material is source-available under the
[PolyForm Noncommercial License 1.0.0](LICENSE); commercial use requires separate
permission. [Third-party notices](THIRD_PARTY_NOTICES.md), including the MIT-licensed
Stats mappings, keep their own terms.

Helios is independent software and is not affiliated with or endorsed by Apple.
Hardware telemetry can depend on undocumented or macOS-version-specific interfaces.
