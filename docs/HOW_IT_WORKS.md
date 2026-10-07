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
- **Knows which sensor is which** only where that is established. On M4 Macs the CPU and
  GPU sensors are verified on real hardware and may drive fan control. On M1, M2, M3,
  M5 and M6 Helios uses a public sensor catalogue to show CPU and GPU temperatures;
  those values are for display and alerts only.
- **Remembers** a bounded history on your Mac (`~/Library/Application Support/Helios`):
  charts, health events, battery health once a day and per-app energy for seven days.
- **Explains** instead of only listing numbers. The Overview answers *Is my Mac
  OK?* and every status has a *Why?* with the readings behind it.
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
  (strongest cooling your limit allows, for 15 minutes, then macOS again),
  *Manual* (at least the speed you choose, more when it gets hot) and *Automatic*
  (your own temperature → speed curve, separately for adapter and battery).
- **A speed limit you control.** Helios stays at or below 90 % of the factory
  maximum. If more cooling is needed, it hands the fans back to macOS, which may
  use full speed. You can allow the full maximum in Settings → Cooling.
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
| **Experimental** | The probe found the expected fans, keys and trusted temperature sensors. Off until you turn it on in Settings → Cooling for this Mac **and** this macOS version; a macOS update asks again. |
| **Unsupported** | No fan, Intel, unknown keys or another fan tool running. Helios stays read-only. |

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
- **Diagnostics are off by default.** If you opt in, a report contains only closed
  categories and buckets (no names, serial numbers, addresses, exact readings or
  logs), and you can read the exact bytes before they are sent. Fan-control
  statistics are a separate switch, also off by default, kept in memory only.

[Privacy](https://www.snejda.cz/helios/privacy) ·
[Diagnostics](https://www.snejda.cz/helios/diagnostics) ·
[Security](https://www.snejda.cz/helios/security)
