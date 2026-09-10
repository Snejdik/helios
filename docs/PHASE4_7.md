# Phase 4.7 — Cooling Rules / Auto mode (Next15)

Next15 builds a TG-Pro-style automatic cooling policy on top of the physically
validated Next14 Manual/Boost backend. It does **not** add raw SMC keys or a new
privileged write primitive. Auto rules compile to the same authenticated
`.override` / `.boost` calculations already bounded by the daemon lease,
recovery journal, factory limits, sleep handling and external-controller gate.

## User-facing model

The app now exposes four presentation modes:

- **System** — Apple owns fan control.
- **Boost** — validated factory maximum.
- **Manual** — the Next14 validated RPM slider (internally `.override`).
- **Auto** — a rule engine inspired by TG Pro Auto Boost rules.

Auto provides separate **Power Adapter** and **Battery** profiles. The current
profile is selected from the battery power-source reading; if that reading is
missing/stale, Auto fails closed to System instead of guessing.

Each rule contains:

- target: `All Fans` or a specific fan id,
- speed: 0...100%, where `0% = MIN` and `100% = MAX`,
- sensor source,
- optional `above` temperature threshold,
- enabled state.

Built-in sensor selectors mirror the useful TG-style aggregates we can support
with trusted current telemetry: `Any Sensor`, `Always`, `Average CPU`,
`Highest CPU`, `Max SoC`, P-Cores, E-Cores, GPU and Battery. The editor also
lists each currently trusted individual SoC SMC sensor. Unknown/unclassified
SMC keys are deliberately excluded from rule inputs. SSD/HDD rule sources stay
staged until SMART temperature telemetry is implemented.

When multiple rules match a fan, only the highest percentage wins. Rule order is
therefore organizational, not semantic. Rules can be reordered and copied
between Power Adapter and Battery profiles. Configuration is persisted in UserDefaults, but **control mode is not**: every
app launch still begins in System. Manual/Boost failures disarm. While Auto is
explicitly selected, a transient acquisition failure may leave the policy armed
only after the daemon has independently verified clean System restoration; retry
then requires a bounded backoff and newer thermal telemetry.

## Safer-than-reference behavior

Because Apple Silicon takeover removes Apple's ability to alter the fan while
Helios owns it, Next15 keeps additional protections above user rules:

1. Rule engage debounce: 0.5 s.
2. Rule release hysteresis: 3°C below the threshold.
3. Rule release debounce: 3 s.
4. Upward rule changes are immediate. The user transition control smooths only
   downshifts, so a cosmetic setting cannot delay required cooling.
5. Trusted Max SoC >=95°C latches an app-side emergency 100% demand and releases
   only after <=88°C for five seconds.
6. Independently, the **privileged coordinator forces `.boost` for every fresh
   calculation at >=95°C**, even if a buggy/custom Manual or Auto rule asks for
   a low RPM. The daemon still cannot read sensors or accept raw keys; it only
   constrains the authenticated Max SoC value already passed with each fresh
   calculation.
7. Missing/stale thermal/fan telemetry, disconnect, sleep, shutdown, lease
   expiry or recovery bypasses all rule transitions and restores System.

## Default profiles

The shipped defaults intentionally omit an `Always` rule. Below the first
threshold Apple retains full control, including zero-RPM behavior. The adapter
profile steps Highest CPU through 20/40/60/80/100% at 55/65/75/82/88°C. The
battery profile uses 20/40/70/100% at 60/70/80/88°C. Users can add an Always
rule if they explicitly want complete low-temperature override.

## Reference behavior mirrored

TG Pro's public guide documents the same core rule concepts that inspired this
phase: separate battery/adapter rule sets, All Fans/per-fan targets, 0...100%
relative MIN/MAX speed, built-in Any Sensor/Always/Average CPU/Highest CPU
sources, individual temperature sensors, highest-speed-wins rule resolution,
copying and reordering rules, and custom full fan curves. Helios keeps its own
UI, naming, trust model and safety constraints rather than copying TG Pro's
implementation.

## Still staged

- SMART/SSD/HDD temperature rules.
- Multi-fan production writes on hardware other than the pinned one-fan
  Mac16,1 / 25G83 profile. The app data model already carries per-fan targets.
- Rule-trigger notifications and historical rule logging.
- Distribution signing/notarization.

## Fixed5 Auto-state hardening audit

The first live Auto Rules test exposed a state-machine race rather than an SMC
failure. An accepted XPC calculation was being treated app-side as if hardware
ownership had already been confirmed. Editing the rule while acquisition was
still in flight then intentionally issued System release, but the UI barrier only
cleared when ownership had previously reached Boost/Override. That could leave
Auto permanently displaying “Waiting for verified System release” even though
the daemon had already restored `Ftst=0` / System.

Fixed5 separated **pending command** from **daemon-confirmed ownership** and
made a verified System reply sufficient to clear its old reconfiguration barrier.
That removed the permanent wedge, but the barrier itself was later found too
aggressive for interactive editing: cancelling acquisition on every live rule edit
created avoidable Ftst/F0Md churn. Fixed7 supersedes that policy by keeping live
edits under the same ownership transaction whenever demand still exists. Manual ->
Auto with an empty profile still preserves knowledge of existing ownership long
enough to return it to System rather than forgetting the Manual state.

Additional audit hardening in Fixed5:

- failure to create a release remote proxy clears the app request timeout/state
  instead of leaving the client wedged busy;
- `Always` is a permanent first-class source even before dynamic sensor discovery
  and never renders a temperature threshold;
- edits to the **inactive** Power Adapter/Battery profile no longer tear down a
  healthy Auto target on the currently active power profile;
- changing the cosmetic downshift duration no longer forces a System round-trip;
- sleep immediately marks fan telemetry unavailable and pushes thermal failure
  through the app control path in addition to the daemon's independent pre-sleep
  restoration;
- power-source notifications publish immediately so AC/Battery profile changes
  cannot wait for the next periodic redraw.

Regression coverage now includes in-flight acquisition -> rule edit -> verified
System -> fresh-sample retry, inactive-profile isolation, and Manual -> empty
Auto -> System handoff. These tests use a deterministic fake coordinator engine
and never touch AppleSMC.

## Fixed7 live stabilization

Physical/UI testing exposed a second-order Auto problem: configuration editing was
modelled as a safety boundary. Each change to a live rule cancelled whatever
acquisition/update was running, issued System release, reset rule state and waited
for another thermal sample to reacquire. This was safe but operationally unstable
on Mac16,1 because F0Md arbitration can legitimately take several seconds. Normal
Stepper interaction could therefore keep pre-empting ownership before it settled.

Fixed7 separates **policy editing** from **safety restoration**. Live rule changes
now reset only the app-side rule debounce/downshift runtime. The next fresh 500 ms
thermal batch evaluates the newest configuration. If Helios already owns the fan,
that becomes the validated steady-state F0Tg update path. If acquisition is still
in flight, it is not cancelled; after completion, a newer sample applies the newest
target. If the new configuration has no active demand, the next fresh sample issues
one verified System release.

A recoverable hardware failure is also treated differently for Auto than Manual:
when the daemon replies with verified System and the capability remains available,
Auto stays armed, waits two seconds and retries from a newer sample. Repeated retry
does not renew from heartbeats/UI; the original lease freshness rules still apply.
Manual and Boost continue to require explicit re-selection after failures.

The UI now reports matching rules separately from confirmed ownership and exposes
Add Rule > Always Rule directly. No root/SMC write primitive changed in Fixed7.
