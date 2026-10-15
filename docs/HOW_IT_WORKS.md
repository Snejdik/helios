# How Helios works

Helios is two programs and a clear line between them.

```text
 ┌──────────────────────────────┐                    ┌──────────────────────────────┐
 │ Helios.app (your user)       │   XPC, signed      │ HeliosDaemon (root helper)   │
 │ menu bar · window · history  │ ─────────────────▶ │ fan control only, optional   │
 │ reads sensors, never writes  │ ◀───────────────── │ always hands back to macOS   │
 └──────────────────────────────┘                    └──────────────────────────────┘
        │ read-only                                          │ SMC, fan keys only
        ▼                                                    ▼
   macOS · IOKit · SMC · sysctl                        Apple Silicon fan controller
```

## The app

`Helios.app` is a menu-bar app. It runs as you, with no special privileges.

- **Samples** CPU, memory, GPU, temperatures, fans, battery, power, storage,
  network and processes. Every provider is independent: a sensor that does not
  exist on your Mac shows *Unavailable*, never a made-up zero, and never stops the
  rest. A sensor that is switched off for a while (the GPU's, while it sleeps) is shown
  as *not measuring*, not as an error.
- **Knows which sensor is which** only where that is established. Every chip family has a
  key map compiled from public sources; Helios then checks it on your Mac during normal
  use (the performance-core sensors must warm with performance-core load, and so on) and
  shows the result next to each temperature: *Confirmed on this Mac*, *Validated for this
  chip* (M4) or *From catalogue, may be inaccurate*. Only confirmed or validated sensors
  raise alerts or drive automatic fan control.
- **Remembers** a bounded history on your Mac (`~/Library/Application Support/Helios`):
  charts, health events, battery health once a day, per-app energy for seven days, and
  one small longevity record a day (battery habits, SSD writes, temperature under load,
  memory pressure) for about a year.
- **Explains** instead of only listing numbers. The Overview answers *Is my Mac
  OK?*, every status has a *Why?*, and *Ask Helios* walks through a question (slow, hot,
  draining the battery, not sleeping, restarting, slow Wi-Fi, disk filling up) as *what I
  see → why I think so → what you can do*, saying how sure it is.
- **Looks after the long run.** The Longevity page grades the battery, power adapter and
  cable, SSD, cooling and memory in words, compares the Mac with its own first weeks, and
  marks every projection as an estimate.
- **Saves you a few clicks.** Keep Awake, a command palette (⌃⌥⌘Space), simple rules
  ("if the battery is below 20 %, notify me"), "tell me when it's done", `helios://` links,
  a `helios` command line and Shortcuts. Each can be left off entirely.
- **Only collects what you ask for.** The welcome screen turns your goals into the
  samplers that actually run, so a quiet setup stays light.

Basic monitoring never needs the helper.

## The helper

macOS only lets a privileged process write to the fan controller, so fan control
lives in a small separate helper, `HeliosDaemon`. You install it once in
**Settings → Cooling**; macOS asks for your approval in *Login Items*.

What keeps it narrow:

- **Fans only.** It cannot change battery charging, run commands or touch files
  outside its own state records. Its SMC write list contains the fan keys and
  nothing else.
- **Only the signed Helios app can talk to it.** Connections are checked by code
  signature, one session at a time, with a handshake and ordered requests.
- **Dead-man lease.** The app must keep sending fresh calculations. If it stops
  (quit, crash, freeze, sleep, lost connection), the lease runs out and the helper
  gives the fans back to macOS by itself.
- **Journal and recovery.** Before it takes the fans, the helper writes a small
  record. If the helper itself is killed or the Mac restarts mid-takeover, the next
  start restores macOS control before anything else.
- **Its own thermal guard.** The helper reads the temperature itself and does not
  rely on the app's number.

## The fan layer

Helios does not replace macOS fan control; it adds to it.

- **Never cools less than macOS.** Helios asks for a speed only when that is
  above what macOS is doing, and never below a fixed safety curve.
- **Four modes.** *System* (macOS decides, the recommended default), *Boost*
  (strongest cooling your limit allows, for 15 minutes, then macOS again; validated Mac only),
  *Manual* (at least the speed you choose, more when it gets hot) and *Automatic*
  (your own temperature → speed curve, separately for adapter and battery).
- **A speed limit.** Helios stays at or below 90 % of the factory maximum on the
  validated Mac (you can allow the full maximum in Settings → Cooling) and at or below
  70 % on an experimental Mac, without Boost. If more cooling is needed, it hands the
  fans back to macOS, which may use full speed.
- **Smooth.** *Response* sets how gently the speed falls; extra cooling for heat
  is always immediate.
- **A takeover is not instant.** The firmware needs roughly 6–11 seconds to hand
  the fans over, and it needs a short pause after Helios releases them. Helios
  waits and explains instead of retrying blindly; macOS keeps cooling meanwhile.

### Which Macs

A read-only probe checks every Mac before anything can be written.

| Tier | Meaning |
| --- | --- |
| **Validated** | The exact model and macOS build Helios was physically tested on. |
| **Experimental** | The probe found the expected fans, keys and a temperature map for the chip. Off until you turn it on in Settings → Cooling for this Mac **and** this macOS version (a macOS update asks again), then a 20-second fan test at the lowest speed must pass. |
| **Unsupported** | No fan, no temperature map for the chip, unknown keys or another fan tool running. Helios stays read-only. |

Experimental means exactly that: use it with the understanding that it comes with
no warranty. Details of the profiles are in the
[compatibility contract](APPLE_SILICON_COMPATIBILITY.md).

### What fans can and cannot do

Apple Silicon chips can jump from cool to their limit within seconds under heavy
bursts, faster than a fan can react. Fans help over minutes: they keep a
sustained load cooler and quieter. They do not prevent the chip from throttling
itself during a short spike. Helios shows both temperatures and fan speed so you
can judge it.

## Your data

- Monitoring history stays on your Mac.
- Update checks ask GitHub for the latest release and send nothing about your Mac.
- Longevity history, data usage per app and network checks stay on your Mac; they are
  never part of any report. The weekly health report is a file you export yourself.
- **Diagnostics are off by default.** If you opt in, a report contains only closed
  categories and buckets (no names, serial numbers, addresses, exact readings or
  logs), and you can read the exact bytes before they are sent. Fan-control
  statistics are a separate switch, also off by default, kept in memory only.

[Privacy](https://www.snejda.cz/helios/privacy) ·
[Diagnostics](https://www.snejda.cz/helios/diagnostics) ·
[Security](https://www.snejda.cz/helios/security)
