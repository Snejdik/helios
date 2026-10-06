# Fan control as a safety layer — design

Status: **implemented and physically checked on a Mac16,1** (see §13). This document
explains why the fan layer is built the way it is and what it guarantees. For a short
overview see [HOW_IT_WORKS.md](HOW_IT_WORKS.md); the supported profiles are listed in the
[compatibility contract](APPLE_SILICON_COMPATIBILITY.md).

## 1. Why this exists

Production fan writes were limited to one physically validated tuple (Mac16,1 / 25G83). Newer
macOS builds and other Apple Silicon Macs were blocked by design. The goal is fan control on
**every supported Apple Silicon Mac**, with one overriding requirement: **Helios must never
make a Mac, its fan or its thermals worse than macOS alone.**

In practice that means: if Helios has a bug or stops working, macOS must not be limited by it;
even with the helper active, no Mac may be damaged; the layer sits on top of the system's
values instead of overwriting them; extra memory or CPU is acceptable if it is safer; both Auto
and Manual exist (a user running a local AI model or a render wants a hard floor); and if Auto
ever fails, Manual must still be there.

## 2. Non-goals

- Running a fan **slower** than macOS would. There is no silent/quiet mode.
- Intel Macs, fanless Macs (they are read-only by definition), and any Mac whose probe does not
  pass (they stay read-only; see §8).
- Changing any value Helios cannot restore (factory limits, NVRAM, thermal-policy files).
- Coexisting with another fan controller (TG Pro, Stats, Macs Fan Control): refuse, do not fight.

## 3. Safety invariants (every design decision is checked against these)

1. **Fail-open to System.** Any error, timeout, stale reading, disconnect, crash, sleep, unknown
   state or unexpected readback ends with macOS controlling the fans. Never the other way round.
2. **Only up.** The commanded target is never below what macOS would command at that moment
   (see the effective-target formula in §5). Helios can only add cooling.
3. **Bounded.** Targets are clamped to the live-read factory minimum and maximum of that fan,
   always, even if firmware would accept more.
4. **No unbounded ownership.** Holding the fans always has a deadline that Helios must keep
   renewing; a missed renewal releases. Ownership is never held "until further notice".
5. **Restorable from a dead process.** Before the first write, intent is persisted so a fresh
   process (after crash, SIGKILL, reboot) can restore the complete state without trusting memory.
6. **Verified, not assumed.** Every acquisition and release is confirmed by reading hardware
   state back. An unconfirmed release keeps the recovery evidence and retries.
7. **Independent emergency path.** A hot, trusted sensor forces maximum cooling no matter what
   the user, the rules or the smoothing say. It also works with the menu-bar app closed.
8. **No silent fighting.** If macOS takes the fans back, Helios re-acquires a bounded number of
   times, then stays on System and tells the user (Activity event). It never loops forever.
9. **Honest unsupported state.** A Mac that is not proven is shown as read-only with the reason;
   nothing is guessed or retried against a rejected write.

## 4. What the research established (and did not)

Sources are in §12. Facts used for the design:

- `thermalmonitord` holds fans in mode 3 ("system"). Writes to `F0Md`/`F0Tg` are protected.
  M1 accepts a direct `F0Md=1`; M3 and newer need `Ftst=1`, a wait of about 3 s and retries of
  the mode write (3–6 s in practice) before `F0Tg` is accepted. Return is `F0Md=0` and `Ftst=0`.
  Stats (PR 2924, merged 2026-02-22, tested on M4 Max), macos-smc-fan, ThermalForge and TG Pro
  2.97 all describe this family of sequences. Helios's validated production path uses it on
  Mac16,1 / 25G83.
- **Fans are taken back by macOS** after wake, voice/Siri and some thermal events; the manual
  speed then silently stops while the Mac is still hot (Stats #2094; the tool `stats-fan-keeper`
  exists because of it). An `Ftst` left at 1 partially inhibits macOS thermal management.
- **There is no additive offset key.** Raw metadata observed on 25G83: `F0Mn` attributes `0x84`
  and `F0Mx` `0x85` (no write bit), versus `F0Md`/`Ftst` `0xd0` and `F0Tg` `0xd4`. The bit
  meaning comes from community knowledge, not Apple documentation, so treat "F0Mn is read-only"
  as probable, not certain. If `F0Mn` were writable, raising the floor while macOS keeps control
  above it would be the ideal layer and would fail towards cooling. **Re-read these attributes
  on 26A434 first** (read-only, §10 step 1).
- **macOS 27 is unknown ground.** In September 2026 Macs Fan Control (#913) and ClearPower (#1)
  reported missing sensors/fan data after the update. No one has documented the `Ftst` path
  working on 27. Helios reads thermals and fan RPM fine on the Mac16,1 it was tested on.
- Not established anywhere: crash with `Ftst=1` active, whether the firmware resets it on sleep
  or reboot, and the full thermal-policy effect of `Ftst`. Do not rely on the SoC's own
  protection as a guarantee; it is plausible but unverified from these sources.

## 5. Design: a cool-only layer

Hardware offers only modes and targets, so the layer is implemented in software and constrained
so it behaves like an additive layer.

### Modes (all additive; none can cool less than macOS)

| Mode | Meaning |
|---|---|
| **System** | Default. Helios reads only. `Ftst=0`, `F0Md=3`. |
| **Auto** | Helios engages when its temperature rule asks for more cooling than macOS, and returns to System with hysteresis and smoothing (§6). |
| **Manual** | The user sets a **minimum** (RPM or percent of range) held until stopped or timed out. Effective target is still raised above it whenever the floor below demands. Intended for local AI, renders, long compiles. |
| **Boost** | Maximum cooling for a user-chosen time, then returns to System by itself. |

Auto and Manual are independent choices. If Auto misbehaves or the user does not trust it,
Manual (and Boost) remain available.

### Effective target

```
effective(fan) = clamp( max( user_request,
                             safety_floor(temperature),
                             shadow_floor(temperature) ),
                        fan.minimumRPM … fan.maximumRPM )
emergency: trusted sensor ≥ 95 °C → maximum, bypassing smoothing and user settings
```

- **safety_floor** is a fixed, non-removable curve in the daemon (for example at least about
  half of the range from 80 °C, maximum from 88 °C; exact numbers to be set in the session from
  data and reviewed). The user cannot lower it.
- **shadow_floor** is the system-behaviour model. While Helios is in System mode it records, per
  Mac, what macOS itself commands (`F0Tg`/`F0Ac` against trusted temperature, per power state)
  and keeps a conservative envelope. This costs memory and a little CPU, which is accepted. It is how "never below macOS" can hold while macOS's live target is invisible
  during ownership. If there is not enough history, shadow_floor falls back to the safety floor
  plus a margin and Auto engages only above a conservative threshold.
- `max(...)` is the layer: whichever source asks for the most cooling wins.

### Ownership only when needed

Helios takes ownership only while its effective target exceeds what macOS is doing, or while a
Manual/Boost request is active. In every other situation it stays on System (`Ftst=0`).
Ownership time is therefore short and mostly during load.

## 6. Smoothing ("Response" slider)

Fans must not turn on and off constantly. One user setting, **Response**, maps to four daemon
parameters (the first design used three presets; the shipped control is one continuous value):

1. **Hysteresis** in °C between the engage and release thresholds (today fixed at 3.0).
2. **Minimum dwell** between target changes (today engage debounce 0.5 s, release debounce 3 s).
3. **Slew limit** in RPM per second, applied to rises and, more gently, to falls.
4. **Temperature smoothing** window for the input (EMA).

Asymmetry is mandatory: **rises are fast, falls are slow.** Emergency and safety-floor paths
bypass all four. The chart should show the resulting target next to the temperature so the effect
of the slider is visible. Smoothing parameters live with the rules engine, so they sit in a
protected file (§9).

## 7. Acquisition, hold and release

- **Acquisition is a staged, cancellable state machine**, not a blocking retry loop. The
  published entry time (about 3–6.5 s) is longer than Helios's current five-second calculation
  lease, so the lease must not be extended by retries and arming must never use stale data.
  Production documents an eight-second arbitration with one-second pacing.
- **Transparent first write:** the first target equals what macOS was commanding, so acquiring
  does not change RPM by itself. Only afterwards is the target raised.
- **Journal before the first write** (intent, fan IDs, expected global state, model and OS
  build). The current v2 journal does not encode model/build identity; add it, versioned and
  machine-bound.
- **Lease and heartbeat:** short deadline renewed from the app and checked in the daemon; stale
  trusted thermals also expire it.
- **Release path** (explicit stop, expiry, XPC disconnect, app quit, sleep, screen lock/logout if
  relevant, helper stop): restore per-fan mode, then clear `Ftst` only if Helios set it and every
  fan is back under macOS control, then read back and verify.
- **Sleep:** release before the system sleeps and acknowledge only after verification. After
  wake stay on System, do a fresh read-only probe, and offer *Resume* in the UI. A setting
  "Resume automatically after wake" may exist, off by default.
- **If macOS reclaims the fans:** at most 2–3 re-acquisitions inside a ten-minute window with
  backoff, then System plus an Activity event ("macOS took back control").
- **Start-up recovery** in the daemon from the journal; launchd keep-alive for the daemon.

### Guardian

A crash of the daemon itself with `Ftst=1` is the one failure the daemon cannot repair. The
decision is launchd `KeepAlive` plus start-up recovery from the journal. A second privileged
guardian process was rejected: it would add its own attack surface for a small gain.

## 8. "Every Mac": tiers and probing

A guarantee that it works on every Mac cannot be given without hardware. The guarantee is
**fail-open**: on any Mac, Helios is never worse than macOS.

| Tier | Condition | Behaviour |
|---|---|---|
| **Validated** | Exact model + OS build physically validated | Full layer |
| **Experimental** | Read-only probe passes all invariants, build not validated, user consented | Full layer, marked experimental, optional anonymous diagnostics |
| **Unsupported** | Anything else (fanless, Intel, probe fails, unknown keys) | Read-only, reason shown |

The probe (no writes) collects model, OS build, `FNum`, per fan the mode/target/actual/min/max
keys with types, sizes and attributes, `Ftst` presence and type, current mode and `Ftst`
state, trusted thermal channels. Experimental requires: at least one fan, sane min < max, keys
and types as expected for every fan present (the design must handle several fans, per-fan
state and rollback), baseline `F0Md=3` and `Ftst=0`, no foreign controller, fresh trusted
thermals. If `Ftst` is already 1 or any mode is not 3 at baseline, refuse.

Consent is stored per **model and OS build**; a new build asks again. The consent text states
the risk and that macOS keeps control unless Helios needs to add cooling. A separate checkbox
for fan-control statistics is **off by default** and not a condition of using the feature.
Those statistics are launch-scoped, bucketed and never include raw temperatures, RPM or
commands (see the diagnostics documentation).

## 9. Reuse and protection

The layer reuses signed NSXPC authentication, daemon-only writes, no arbitrary-key command, the
journal and recovery machinery, the five-second lease and clamping. The files that implement
fan safety are protected by `scripts/check-next23-ui-boundary.sh` through SHA-256
fingerprints; changing one needs a deliberate, reviewed manifest update, never a weakened gate.
The Helios UI never decides safety: it calls `FanControlModel` and its gates.

## 10. Order of work

The layer was built in stages: a read-only probe first, simulated failure tests before the
implementation, a runtime switch that defaults off, staged physical validation, then Response, the
learned macOS envelope, UI, consent and diagnostics, and only then the Experimental tier. All
stages are done; §13 lists what remains.

## 11. Failure matrix and validation

Every row needs a simulated test and, where physically meaningful, a staged physical check. The
expected result is always: macOS control restored within a stated time and verified by readback.

app quit · app SIGKILL · helper stop · helper SIGKILL · helper update · XPC disconnect · sleep
with ownership · lid close · wake · reboot · logout and screen lock · stale thermals · missing
sensor · emergency temperature · macOS reclaims fans · external controller present at start ·
`Ftst` already 1 at start · acquisition cancelled mid-way · partial write failure · journal
corrupt or from another model/build · fan count change · two fans with one failing · clock jump.

Physical tests are done carefully: a fan is tried only at or near the factory minimum, for short
periods, with abort rules, and every test ends with readback verification of the return to
macOS. On a Mac whose fan is normally off (minimum 2317 RPM on the Mac16,1), any takeover is
audible.

## 12. Sources

- Stats PR 2924 — https://github.com/exelban/stats/pull/2924
- Stats #2928 (M3/M4+) — https://github.com/exelban/stats/issues/2928
- Stats #2094 (fans reclaimed) — https://github.com/exelban/stats/issues/2094
- stats-fan-keeper — https://github.com/jamubc/stats-fan-keeper
- ThermalForge safety design — https://github.com/XInTheDark/ThermalForge
- macos-smc-fan — https://github.com/agoodkind/macos-smc-fan
- Macs Fan Control #913 (macOS 27) — https://github.com/crystalidea/macs-fan-control/issues/913
- ClearPower #1 (macOS 27) — https://github.com/Clearailhc/ClearPower/issues/1
- TG Pro M4 fan control — https://www.tunabellysoftware.com/blog/files/tgpro-m4-fan-control.html

Claims taken from READMEs and issues are second-hand. Re-verify what the design depends on by
reading source and by physical measurement; do not copy another tool's sequence wholesale.

## 13. Implementation notes

### Decisions

- **Guardian:** launchd `KeepAlive` plus start-up recovery (§7).
- **The daemon reads temperatures itself** (exact M4-family allowlist, same keys as the app's
  `ThermalClassifier`; the app's value may only raise it).
- **Recovery across macOS builds** is allowed. A journal written on another build of the same
  model is recovered with the restore-only writer (`Ftst=0`, `FxMd=0`); a journal from another
  model is set aside without writes (`.quarantined`). The feature is labelled experimental, with
  a no-warranty and no-liability notice.

### Read-only probe (Mac16,1, macOS 27.0.1 / 26A434)

The surface is identical to 25G83: `FNum ui8 1 attr 0x80 = 1`, `Ftst ui8 1 0xd0 = 0`,
`F0Md ui8 1 0xd0 = 3`, `F0Tg flt 4 0xd4 = 0`, `F0Ac flt 4 0x84`, `F0Mn flt 4 0x84 = 2317`,
`F0Mx flt 4 0x85 = 6550`; `F0md` absent. **`F0Mn` has no write bit**, so the floor cannot be
raised in firmware and the layer stays a software layer. Trusted thermals: 8/8 P-core, 4/4
E-core, 8/10 GPU keys present. macOS runs the fan at about 2,500 RPM from roughly 50–70 °C and
keeps it off below.

### What was built

| Part | File |
|---|---|
| Pure policy: effective target, safety curve (0 % ≤ 65 °C, 50 % at 80 °C, 100 % ≥ 88 °C, +5 °C when uninformed), Boost/emergency, smoother (fast rises, slow falls, dwell), learned macOS envelope, reclaim guard (3 in 10 min ⇒ 10 min on System), user speed limit, Response | `Sources/Shared/FanLayerPolicy.swift` |
| Read-only tiers (Validated / Experimental / Unsupported with reasons), key-attribute write bits, machine identity, trusted thermal map | `Sources/Shared/FanLayerProfile.swift` |
| v3 journal (record + model/build, checksum), disposition rules, consent and limit stores (per model + build, root-owned 0600) | `Sources/HeliosDaemon/FanLayerJournal.swift` |
| Restore-only recovery writer (any build) and profile-bound writer (Ftst 0/1, FxMd 0/1, integral FxTg within live factory range), foreign-controller check | `Sources/HeliosDaemon/FanLayerHardware.swift` |
| Daemon trusted thermals | `Sources/HeliosDaemon/FanLayerThermals.swift` |
| Engine on the acquisition/update/recovery executors and the v2 state machine | `Sources/HeliosDaemon/FanLayerEngine.swift` |
| Start-up recovery of v2 + v3 journals, probe, consent, wake reprobe, envelope sampler (macOS target only, 20 s settle after any ownership) | `Sources/HeliosDaemon/FanLayerRuntime.swift` |
| XPC v5 (`calculate(... smoothness:)`, `fanLayerInfo`, `setFanLayerConsent`, `setFanLayerFullMaximum`), coordinator Response, reclaim lockout, one-hour Boost cap, re-acquire cooldown, status detail, restart on consent change | protected daemon and shared files |
| App: consent in Settings › Cooling, speed limit, Response, Manual “at least”, per-power-source Auto curve, Restore Auto, honest unavailable and “macOS already cools” texts | `DaemonClient`, `FanControlModel`, `V2/HeliosThermalsPage.swift` |
| Tests: policy, smoother, envelope, reclaim, tiers, journal, cross-build and foreign recovery, engine failure matrix, coordinator lockout and Boost cap | `Tests/FanLayerChecks.swift`, `scripts/check-fan-layer.sh` |

The default-off switch is the consent record: without it the daemon keeps the previous
behaviour (validated tuple only, otherwise read-only).

### Behaviour worth knowing

- **Speed limit.** The helper never commands more than 90 % of a fan's factory maximum unless
  the user unlocked the full range. When more cooling is needed, it hands the fans back to macOS
  (which may use full speed); this replaces “emergency forces maximum” while the limit is on.
- **Takeover.** `Ftst=1` alone already spins the fan to its minimum, so a takeover is audible
  and cannot be transparent on this Mac. `F0Md` needs about 6 s of paced retries (up to 11 s
  seen). While macOS already spins the fan, a takeover only makes sense for at least 500 RPM more.
- **Cooldown.** After a release the firmware needs a pause before it hands the fans over again;
  Helios waits 15 s (about 5 s is enough for a normal gap, 2 s is slow) and macOS cools meanwhile.
  A refused takeover backs off from 15 s up to 5 minutes.
- **Battery and Low Power Mode** did not make macOS refuse a takeover in a direct test.
- **Fans and short spikes.** Die sensors can jump from about 50 to 110 °C within seconds under
  a synthetic stress and fall back within about 40 s while the chassis stays cool. Fans cannot
  prevent that; they help over minutes.

### Physical checks (Mac16,1 / 26A434)

| Check | Result |
|---|---|
| Consent on → helper restores System, exits 0, launchd relaunches on demand | consented, available, state System |
| Acquire / hold 2317 RPM 20 s / release | `Ftst=1` OK; `F0Md=1` refused 0x82 five times, accepted after ~6 s; `F0Tg=2317` OK; held 2,300–2,322 RPM at 41 °C; release `F0Md=0`, `Ftst=0` OK; readback `Ftst=0 F0Md=3 F0Tg=0`, fan stopped |
| App stops calculating (lease) | fans back to macOS 5.6 s after the last calculation |
| App SIGKILL while holding | helper restored `F0Md=0`, `Ftst=0` 2 ms after disconnect |
| Helper update (unregister ⇒ SIGTERM) while holding | restored in 2 ms, new helper started clean, consent kept |
| Helper `sudo kill -9` while holding | restored about 75 ms after restart |

### Measuring at runtime

`bash scripts/watch-fan-layer.sh [minutes] [interval]` (read-only) writes one CSV row per second
with `Ftst`, mode/target/actual per fan and the hottest trusted SoC temperature, the helper's
log for the same period and a summary in `.build/monitor/fan-layer-<time>.{csv,log,txt}`.

### Still open

- Physical: sleep or lid close while holding, reboot with ownership, macOS reclaiming the fans,
  Boost and higher RPM.
- Trusted thermal maps for M1–M3 and M5 (until then those Macs are Unsupported with a reason).
- Per-power-state envelope, persisting the envelope, a “Resume after wake” offer and an Activity
  event for “macOS took back control”.
