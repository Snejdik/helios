# Apple Silicon compatibility

Helios runs on **Apple Silicon Macs (`arm64`) with macOS 13 or later**. Intel Macs are not supported.

In short: **monitoring works on every Apple Silicon Mac. Fan control is tested on one Mac (an M4 MacBook Pro) and experimental everywhere else.**

## Support matrix

| Chip family | Temperatures | Sensor map | Fan control |
| --- | --- | --- | --- |
| **M4, M4 Pro, M4 Max** | Yes | Checked on real hardware (M4) | **Validated** on Mac16,1 with macOS 26 build 25G83. Every other M4 model or macOS build: **experimental** |
| M1, M1 Pro, M1 Max, M1 Ultra | Yes | From catalogue, confirmed per Mac at run time | Experimental |
| M2, M2 Pro, M2 Max, M2 Ultra | Yes | From catalogue, confirmed per Mac at run time | Experimental |
| M3, M3 Pro, M3 Max, M3 Ultra | Yes | From catalogue, confirmed per Mac at run time | Experimental |
| M5 (and Pro, Max) | Yes; efficiency cores unknown on base M5 | From catalogue, confirmed per Mac at run time | Experimental |
| M6 | Yes | From catalogue (one source only) | Experimental |
| A18 Pro (MacBook Neo) | Yes | From catalogue | Experimental if it has a fan |
| Any Mac without a fan (MacBook Air) | Yes | as above | Not applicable |
| Unknown or future chips | Shown as unclassified | None | Unsupported until a map exists |

**Experimental** means: Helios has not been tested on that Mac, so fan control is off until you turn it on yourself, and it runs within stricter limits (below). Whether a Mac really works is learned from people who try it and choose to send a compatibility report.

## Monitoring (every Mac)

Each reading either shows what the Mac and macOS expose or is marked **Unavailable**; a missing sensor never stops Helios from starting and is never shown as zero. Fanless Macs are fully supported for monitoring, and Macs with two or three fans are shown fan by fan.

### Temperature sensor maps

Apple does not document which SMC keys hold which temperatures. Helios carries one key list per chip family, compiled from public sources and cross-checked against each other (a key the sources disagree on is left out). The same key can mean different things on different chips, so keys are matched to the detected chip only.

Each map has a visible status in Thermals and the popovers:

- **Confirmed on this Mac**: Helios watched the sensors follow the load of their own part of the chip (performance cores, efficiency cores, GPU) during normal use. **Calibrate** on the Thermals page speeds this up with a 40-second load.
- **Validated for this chip**: the map checked on real hardware (M4 family).
- **From catalogue, may be inaccurate**: not confirmed yet.
- **Does not match this Mac**: the sensors followed a different part of the chip; Helios does not rely on them.

Temperatures from a map that is not confirmed or validated are shown, but **never raise temperature alerts and never drive automatic fan control**.

## Fan control

Production fan writes remain pinned to the exact validated Mac16,1/25G83 profile. Every other Mac stays read-only unless its owner opts in to the experimental layer for that exact model and macOS build and its fan test passes.

Off by default on every Mac. A read-only check classifies the Mac as **Validated**, **Experimental** or **Unsupported**. It is Unsupported when the Mac has no fans, Helios has no temperature map for the chip, the trusted sensors cannot be read, a fan or key looks different from what Helios expects, or another fan controller seems to be running.

### What turning it on involves

1. **Install the helper** (Settings › Cooling). It is a small, fan-only program that macOS asks you to approve.
2. **Consent.** Settings › Cooling shows what this Mac is and asks you to confirm three plain sentences: it is experimental, macOS stays in control and Helios only adds cooling, and temperatures on this Mac may be inaccurate. The helper stores the consent for this **exact Mac model and macOS build**; after a macOS update it asks again.
3. **Fan test (experimental Macs).** Helios holds each fan at its lowest factory speed for 20 seconds, checks that the Mac obeys, and hands the fans back to macOS. If the Mac does not obey, fan control stays off for that model and macOS build. The test stops without a verdict, and can be run again, if the Mac is hotter than 85 °C or macOS does not hand over the fans at that moment.
4. **Automatic mode** needs the performance-core sensors confirmed on this Mac first (or the validated M4 map).

### Limits

| | Validated Mac | Experimental Mac |
| --- | --- | --- |
| Speed limit | 90 % of the factory maximum (can be unlocked) | 70 % of the factory maximum, fixed |
| Boost | Yes | No |
| Manual and Auto | Yes | Yes, never below what macOS is doing |

On every Mac, Helios **never runs the fans slower than macOS would**: it takes the fans only when you ask for more cooling than macOS is giving, and above the speed limit it hands them back to macOS, which may use full speed. Control returns to macOS on any error, when the app stops responding, before sleep, when Helios quits and when the helper restarts; after a crash the helper restores macOS control when it starts. At 95 °C the helper acts on its own and cools as hard as it is allowed to, or returns the fans to macOS.

Battery charging is never controlled; the helper has no battery code at all.

### Physical checks so far

Fan control has been physically tested on one Mac: a 14-inch MacBook Pro with M4 (Mac16,1), on macOS 26 (25G83) and macOS 27.0.1 (26A434), at the factory minimum and above, with every return to macOS verified by reading the fans back. Everything else in the matrix is experimental by design.

## Helping Helios learn your Mac

Settings › Privacy & Diagnostics › **Send a weekly compatibility report** (off by default) sends which temperature sensors and fans your Mac has and what they read, without names or identifiers. The separate **Include fan-control statistics** option adds how the fan layer behaved, including the fan test result. You can read the exact report before anything is sent. Thermals › All sensors › **Export SMC Dump…** saves an anonymous list of the Mac's sensor keys to a file you can attach to an issue.
