# Pre-beta checklist

This checklist records work to verify, not a declaration that it has passed.
Do not publish, sign, notarize, install a helper, send a report or exercise fan
writes merely because an item appears here. Each needs its own authorized run.

## Candidate review

- [ ] Record commit, app version/build, Xcode, macOS version/build and Mac model.
- [ ] Review `git diff` and `git diff --check`; include new files in the review.
- [ ] Run `./scripts/check-all.sh`, preserve its complete log and exit status.
- [ ] Confirm frozen-backend checks pass without changing golden hashes.
- [ ] Check README feature claims against code; planned utilities remain explicitly unimplemented.
- [ ] Check public links, license and third-party notices accompany the candidate.
- [ ] Review images for private data and record capture provenance.
- [x] Curate supplied **live** captures dated 2026-09-12: Dashboard, Full Monitor,
      Thermals & Fans in System mode, Modules, Colors and About. See
      [image provenance](images/README.md). These precede the final documentation
      commit; they do not replace candidate-specific validation.
- [ ] Add a reviewed Privacy & Diagnostics capture if expanding the gallery; none
      was supplied for this pass.

## Beginner installation on a clean test Mac

Use [Installation](INSTALLATION.md) without developer tools installed.

- [ ] Obtain the exact supplied artifact and record its checksum and signing/notarization status.
- [ ] Download/extract/copy to Applications; record first-launch prompts exactly.
- [ ] Verify the menu-bar app is discoverable without a Dock icon.
- [ ] Verify read-only monitoring with the helper absent and diagnostics off.
- [ ] Verify optional permission denial degrades only the affected information.
- [ ] Separately verify helper approval, registration and authenticated connection if applicable.
- [ ] Confirm unsupported fan profiles remain System/read-only. Do not attempt takeover.
- [ ] Exercise built-in removal with data retention, then reinstall.
- [ ] With disposable test data, exercise complete cleanup and verify files/preferences
      are removed; do not equate “quit” with helper unregistration or data erasure.
- [ ] Record failures and improve instructions using the exact observed UI wording.

## Ordinary tester smoke checks

- [ ] Open Dashboard, Full Monitor, Thermals & Fans and Settings; inspect layout/clipping.
- [ ] Confirm changing readings and clear unavailable states on this machine.
- [ ] Close windows and confirm the menu-bar app remains usable; check sleep/wake.
- [ ] Check battery/no-battery and fanless/multi-fan read-only states on relevant hardware.
- [ ] Inspect diagnostics previews without sending; automatic sharing starts off on a fresh setup.
- [ ] Verify explicit-send/opt-in behavior and server retention only in a separately
      authorized diagnostics test. Native tests do not establish deployed backend behavior.
- [ ] Report app version, Mac/chip, macOS, steps, expected/actual outcome and a reviewed
      screenshot through [Issues](https://github.com/Snejdik/helios/issues/new/choose).
      Send private/security issues to [support](mailto:helios@snejda.cz).

## Distribution gates still separate

- [ ] Developer ID signing of app/helper; hardened-runtime and XPC trust validation.
- [ ] Apple notarization and stapling of the exact distribution artifact.
- [ ] Packaging, clean download/install/uninstall and support matrix validation.
- [ ] Read-only compatibility testing beyond the primary M4 host and on older macOS.
- [ ] Review historical performance evidence against the exact candidate; do not
      promote fixture memory results to live-app performance acceptance.
- [ ] Explicit release decision and authorization before any publication.

See [Release readiness](RELEASE_READINESS.md) for prior host evidence and
[Apple Silicon compatibility](APPLE_SILICON_COMPATIBILITY.md) for hardware limits.
