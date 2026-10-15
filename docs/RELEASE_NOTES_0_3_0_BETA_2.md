# Helios 0.3.0 Beta 2 — release notes

Bundle version 0.3.0, build 7, tag `v0.3.0-beta.2`. The first public beta of the 0.3.0 release,
which follows [0.2.1 Beta 1](RELEASE_NOTES_0_2_1_BETA_1.md). Helios now explains *why*, watches how
the Mac holds up over months, runs on every Apple Silicon Mac and adds a few tools that save clicks.

**Beta 1 was withdrawn within hours of its release.** It hid the new Longevity page from everyone
who finished the welcome or pressed *Apply Goals*. Beta 2 fixes that: Longevity is part of every
goal choice, and anyone Beta 1 hid it for sees it again once. Nothing else changed.

The build is **not notarized**. macOS asks you to confirm the first launch; see the
[installation guide](INSTALLATION.md). **Updating from 0.2.x: reinstall the fan helper once**
(What's New or Settings › Cooling); this version changes how the app and helper talk to each other.

## Ask Helios why

- *Ask Helios* on the Overview, and a *Why?* section on the CPU, Thermals, Battery, Storage and
  Network pages, answer: why is my Mac slow, hot or loud, why does the battery drain, why does it
  not sleep, why did it restart, why is the Wi-Fi or internet slow, why is the disk filling up.
- Each answer reads *what I see → why I think so → what you can do*, says how sure it is
  (*Likely* or *Possible*) and what it could not check.
- Restart answers read macOS's own crash and shutdown reports on this Mac. Nothing leaves the Mac.

## Longevity (new page)

- **Battery:** wear over time and a projection to 80 %, cycles, time spent full on the adapter,
  charging while warm, and an optional reminder at 80 %. Helios never changes how the Mac charges.
- **Power adapter and cable:** the adapter's rating, what it offers over this cable and what the
  Mac agreed on, so a cable that holds a 96 W adapter to 60 W is pointed out.
- **SSD:** writes per day, the drive's own endurance estimate and a projection, marked as a rough
  estimate.
- **Cooling:** temperature under similar load compared with the Mac's first four weeks (a sign of
  dust or a blocked vent), honest that Helios cannot measure the room.
- **Memory:** time under memory pressure and how much swap it writes to the SSD.
- Grades in words (*Excellent*, *Good*, *Needs attention*) with the facts behind them, never a
  bare score. Without enough history an area says so instead of guessing.
- Export a report of the week as PDF or HTML, and an optional weekly summary notification.

## Network

- **Network check** on request: Wi-Fi, router, DNS and internet, timed separately, with the answer
  in one sentence (*"The router answers in 4 ms, the internet in 180 ms: the problem is with your
  provider"*). Also notices VPNs and phone hotspots.
- Wi-Fi channel crowding (without asking for Location), and Wi-Fi drops over the last hour.
- **Data usage per app** (optional, off by default), per day, with a note on a phone hotspot. It
  stays on this Mac.
- **Latency over time** (optional, off by default): three tiny echoes to the router and the
  internet every five minutes, a chart of the last day or week, and *Why is the internet slow?*
  compares the last hour with your Mac's usual. Kept for seven days on this Mac.

## Tools

- **Keep Awake:** for a while, while on power, until an app quits, or until you stop it; optionally
  the display too. It ends itself at 10 % battery or critical heat. In the menu-bar popover and
  the Overview.
- **Command palette:** ⌃⌥⌘Space from anywhere: pages, actions and processes.
- **Rules:** "if → then" for temperature, battery, power source, running apps, time of day and CPU load,
  with safe actions only (notify, Keep Awake, fans back to System or Auto, run a Shortcut).
- **Tell me when it's done:** an app quits, the CPU calms down, a download finishes.
- `helios://` links, a `helios` command line (`helios status --json`) and Shortcuts.
- **Mouse (experimental, Settings › Advanced, off by default):** reverse only the scroll wheel so
  the trackpad keeps natural scrolling, and set how far one notch scrolls. Trackpads and Magic
  Mouse are never changed. It needs Accessibility access, which macOS asks for again after every
  update because Helios is not notarized.

## Every Apple Silicon Mac

- Helios recognises every Apple Silicon chip (M1 to M6 with Pro, Max and Ultra, and A18 Pro) and
  59 Mac models.
- **Sensor maps are now checked on your Mac** during normal use and labelled *Confirmed on this
  Mac*, *Validated for this chip* or *From catalogue, may be inaccurate*. **Calibrate** on the
  Thermals page speeds this up. Unconfirmed temperatures never raise alerts or drive Auto.
- The base M3 map was corrected (the catalogue's performance-core keys were GPU keys), and M1
  Ultra's second chip was added.
- **Export SMC Dump…** saves an anonymous list of the Mac's sensor keys for a bug report.

## Fan control (experimental outside one Mac)

- Fan control can now be turned on, as an experiment, on **every Apple Silicon Mac with fans**,
  including Macs that drive the fans without the `Ftst` key (M5 and later) and Macs with two or
  three fans.
- On any Mac other than the validated one (Mac16,1 with macOS build 25G83) it needs your consent
  for that exact model and macOS build, then a **20-second fan test** at the lowest speed. The
  speed limit is **70 %** of the factory maximum and there is no Boost. If a fan does not obey
  during the test, fan control stays off for that model and build; if macOS simply does not hand
  the fans over at that moment, you can run the test again.
- **Your Mac on a newer macOS than 25G83 counts as experimental** too: after updating, confirm
  again in Settings › Cooling and run the fan test.
- Settings › Cooling now says in one line where fan control stands on this Mac.
- Unchanged: Helios never cools less than macOS, hands the fans back on any error, before sleep and
  when it quits, and the helper's own 95 °C guard.

## Also

- The original 0.1 interface (*Legacy*) is gone; Helios has one interface.
- Diagnostics is now **Checkup**: what Helios found (each with its *Why?*), what would let it see
  more, what it can read, and **All readings**, every value Helios reads, unprocessed, on request.
- On a large window the Overview uses a second column for *Ask Helios*, tools and summaries.
- After the update, What's New walks through each new area in a few short pages, including how to
  turn on fan control and what the fan test does.
- Background macOS processes have plain names ("Spotlight indexing", "Web pages (WebKit)").
- Macs with several fans show them all ("2 fans · 2400–2600 RPM").
- A chart that covers only part of its range says how much data it has.
- The Hardware page lists storage and fans, earbuds' left, right and case battery, and says when
  nothing else is connected.
- A high-temperature event now says what else was going on (macOS's thermal verdict and the
  busiest app).
- The Battery page falls back to a Helios estimate of the time remaining while macOS is still
  calculating.

## Known limits

- Fan control is physically tested on one M4 MacBook Pro only. Everything else is experimental by
  design and depends on reports from people who try it.
- The base M5's efficiency-core sensors are unknown; that group shows as *Unknown*.
- Longevity needs time: a battery trend after about a month, the cooling comparison after four
  weeks of use.
- Without a paid Apple Developer ID there are no widgets and no automatic updates, and the helper
  must be reinstalled after every update.
