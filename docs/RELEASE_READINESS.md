# Release readiness

## Current status

The current codebase is an **engineering release-candidate / external-beta source preview**.

The canonical regression and Release gates pass on the primary M4 validation machine. The privileged fan/helper boundary remains frozen, and the latest live-app UI memory stress demonstrates a bounded plateau rather than monotonic post-close growth.

There is still no public binary release.

## Latest primary-host evidence

Primary physical validation host:

- base M4 14-inch MacBook Pro
- model `Mac16,1`
- macOS Tahoe 26.6.2 / build `25G83`

Latest comparable closed-UI Release CPU captures:

| Preset | CPU time |
| --- | ---: |
| Simple | 14.52 ms/s |
| Recommended | 17.31 ms/s |
| Detailed | 21.49 ms/s |

A 15-minute Recommended/System Release soak completed without app restart and finished at 22.53 MiB physical footprint.

The subsequent exact live-app interactive memory test used three repeated cycles of Full Monitor, Energy Inspector, Dashboard and metric popovers. Its physical footprint settled around the same post-warmup level across cycles and finished at **+15.0 MiB vs. its warm baseline** after the final cleanup wait. This clears the earlier monotonic-leak concern for external-beta purposes, while remaining a host-specific result rather than a universal memory guarantee.

## Technical contract

- Apple Silicon (`arm64`) only
- macOS 13.0+
- capability-based read-only telemetry
- unavailable hardware fields fail independently
- privileged helper remains fan-only
- battery remains telemetry-only
- fan writes remain exact-profile gated
- all other Macs remain System/read-only for fan writes unless separately validated

## Before a GitHub source preview

Helios is source-available under the PolyForm Noncommercial License 1.0.0. Publication must include the root `LICENSE` and separate `THIRD_PARTY_NOTICES.md`.

The public tree should not contain local DerivedData, performance captures, private signing logs, local preferences, heap/vmmap dumps, or other machine-specific engineering artifacts.

## Before an external binary beta

A binary shared with people who are not building from source should use an intentional signing/distribution workflow. At minimum, validate:

1. Developer ID Application signing for both app and helper,
2. consistent Team identity and XPC trust,
3. hardened runtime,
4. notarization and stapling,
5. helper registration/approval on a clean machine,
6. installation and removal behavior,
7. read-only smoke testing on more Apple Silicon hardware.

## Before a public release

Still required:

- verify that the source license and third-party notices are included in the release,
- physical read-only validation on additional Apple Silicon generations/device classes,
- Developer ID signing,
- notarization and stapling,
- a clean distributable package such as a DMG,
- clean-machine installation/uninstallation validation,
- final support matrix and release notes.

Do not broaden fan-write support simply because the app launches or telemetry works on another Mac.

## Useful validation commands

```sh
./scripts/check-all.sh
./scripts/check-apple-silicon-release.sh
./scripts/perf-prepare-release.sh
./scripts/perf-final-core-suite.sh 90
./scripts/perf-ui-memory-check.sh 3
```
