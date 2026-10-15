# Helios 0.3.0 Beta 1 — validation

Identity: tag `v0.3.0-beta.1`, bundle version 0.3.0, build 6. Date 2026-10-15.
This page records what was verified for 0.3.0 Beta 1 and what was not. It extends the
[0.2.1 Beta 1 validation](VALIDATION_0_2_1_BETA_1.md).

## Automated gates

| Gate | Result | New for 0.3.0 |
|---|---|---|
| `git diff --check` | pass | — |
| `scripts/check-all.sh` | pass, ends with `PASS full Helios regression gate and Xcode build` | Five new gates below |
| `scripts/check-next23-ui-boundary.sh` | pass, 32 protected fingerprints | One approved batch for fan control on every Apple Silicon Mac (strategy `ftst`/`direct`, `Fxmd`, 70 % limit, no Boost, entry test, XPC v6, Legacy UI removed); one reviewed follow-up in `FanLayerEntryTest.swift` (a takeover macOS refuses is inconclusive, not a permanent failure) |
| `scripts/check-chip-profiles.sh` | pass | 24 chip fixtures (M1…M6, Pro/Max/Ultra, A18 Pro, Macs without fans, unknown chips), cluster layout, passive sensor-map verifier, anonymous SMC dump |
| `scripts/check-fan-layer.sh` | pass | Fan layer on all Apple Silicon: `direct` strategy, lowercase mode key, 70 % ceiling, entry test (pass, reclaim, refusal, too warm, stale), three fans with partial rollback, helper crash with the `direct` strategy |
| `scripts/check-diagnose.sh` | pass | "Why?" engine: seven questions, at least five scenarios each, honest confidence, network history |
| `scripts/check-tools.sh` | pass | Keep Awake safety stops, rules (edge, rate limit, schema), `helios://` links, status summary, mouse wheel transform |
| `scripts/check-longevity.sh` | pass | Day records, battery and SSD projections, adapter and cable, cooling trend, memory, report escaping, reminders |
| Debug build (warnings as errors) | pass | — |
| Release build (warnings as errors) | pass; bundle reports 0.3.0 (6), `v0.3.0-beta.1`, arm64, signature verifies | — |
| `scripts/package-release.sh --build` | pass; DMG (styled, with an Applications link), ZIP and checksums verified, helper version matches | — |

The web backend needs the `system.chip` and `fan_layer.strategy` / `entry_test` fields
(validator and migration `012_helios_chip_profile_view.sql`) before this app version sends
diagnostics. The report schema is still version 1.

## Run on a real Mac (Mac16,1, macOS 27.0.1, 26A434)

- Sensor map and chip profile read live; anonymous SMC dump: 2,806 keys in 0.5 s, no text values.
- Network check: router 4 ms and internet 17 ms, matching the system `ping`; Wi-Fi scan works
  without Location permission (network names stay hidden).
- Longevity: adapter "70W USB-C Power Adapter" (70 W rated, 68 W offered and agreed), SSD
  written 3.26 TB, battery 103 %; the day record is written to
  `~/Library/Application Support/Helios/longevity-v1.ndjson`.
- Checkup (formerly Diagnostics) › All readings, Hardware (storage, fans), Overview Longevity row, What's New 0.3.0.
- **Idle cost** (Release build, window closed, 6 minutes right after launch, default modules):
  physical footprint 46–49 MB, CPU 0.59 % on average (1.2 % at most), about 2 wakeups a second;
  helper 8.6 MB and 0.04 % CPU; no errors or faults in the log. A longer run with the owner's
  usual modules follows in the owner tests.

## Owner tests (2026-10-15, the DMG build installed over 0.2.1 Beta 1)

- **Update from 0.2.1 Beta 1:** What's New appeared once and said the old helper does not answer
  this version; **Reinstall Helper** fixed it (XPC v6 handshake in the log).
- **Consent and fan test** on Mac16,1 / 26A434: the consent dialog, then *Run Fan Test*: the fan
  held its minimum (2,317 RPM) for 20 seconds and returned to macOS; result **Passed**, status
  *Experimental, on*. Boost stays unavailable; Manual and Auto drive the fans within the 70 % limit.
  The sensor map shows P-cores and GPU *Confirmed on this Mac*, E-cores *Validated for this chip*.
- **Longevity:** adapter 70 W rated, 68 W offered and agreed, *Excellent*; SSD 3.27 TB written;
  battery 103 %, 6 cycles, a trend after 12 days of records.
- **Checkup, palette, links:** Checkup with 12 of 12 sources readable; ⌃⌥⌘Space opens the palette;
  `helios open …` opens the page.
- **Idle, window closed, 10 minutes:** physical footprint 97–98 MB, CPU 0.77 % on average (1.4 % at
  most), about 3 wakeups a second; helper 11.7 MB; no errors or faults.

Found during these tests and fixed before release: the fan curve editor jumped while a point was
dragged during a takeover (the Auto status line changed height); the cooling popover hid the
Manual slider while the fans were being handed over; the Thermals page and popover still showed
0.2's "not available yet" text before the fan test; Checkup showed *Blocked* for the validated-profile
check next to *Available*; *Why is the internet slow?* treated one lost echo of five as a router
problem; What's New was a single page and now walks through each new area, including fan control.

## Not verified

- Fan control on any chip other than M4 (simulation only; experimental by design).
- The `direct` takeover strategy (M5 and newer) on real hardware.
- Sensor-map confirmation on non-M4 Macs (catalogue maps until a tester's Mac confirms them).
- The mouse tools need Accessibility permission and were tested by their transform only.
- Everything listed as not verified for 0.2.1 Beta 1.
