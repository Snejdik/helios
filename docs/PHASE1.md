# Phase 1 — Scaffold and Local Build Verification

Validated on 2026-09-06. This phase covers compilation, ad-hoc signing, and packaging, with no daemon installation or hardware access.

## Environment

| Item | Verified value |
| --- | --- |
| Hardware target | M4 MacBook Pro, confirmed by the user |
| Host OS | macOS Tahoe 26.6.2, build 25G83 (`sw_vers`) |
| Selected Xcode | `/Applications/Xcode.app/Contents/Developer` |
| Xcode | 26.6, build 17F113 |
| Swift compiler | 6.3.3, Swift 6 language mode |
| Installed macOS SDK | 26.5 |
| Build architecture | arm64 |
| Deployment floor | macOS 13.0; other releases not validated |
| Signing | Ad-hoc (`-`), empty Team ID, hardened runtime enabled |

Xcode's version, the macOS SDK version, and the running OS version differ here. `SDKROOT = macosx` selects the installed SDK. Both Release Mach-O binaries report `sdk 26.5` and `minos 13.0`; no nonexistent 26.6.2 SDK is requested.

## Targets and Bundle Layout

`HeliosApp` is an agent application (`LSUIElement = true`) with an AppKit status item and a lazily created popover. Thermals & Cooling is first. `SMAppService.daemon(plistName:)` is used only to inspect registration status.

`HeliosDaemon` is a separate command-line executable target with an NSXPC listener. It rejects all connections until the versioned protocol, connection-bound client authentication, and lease handling are implemented. There are no exported methods or SMC access paths.

The app has an explicit build dependency on the daemon and embeds its signed product:

```text
Helios.app/
  Contents/
    Info.plist
    MacOS/Helios
    Library/
      HelperTools/HeliosDaemon
      LaunchDaemons/com.snejda.Helios.Daemon.plist
```

The launchd plist uses `BundleProgram = Contents/Library/HelperTools/HeliosDaemon`, the Mach service `com.snejda.Helios.Daemon`, and `UserName = root`. It is metadata for future SMAppService registration; copying it into the bundle does not install or start a service. The daemon embeds its own Info.plist in the Mach-O `__TEXT,__info_plist` section.

Both targets share `Config/Helios.entitlements`, an empty base entitlement dictionary. App Sandbox is disabled and hardened runtime is enabled. No app-group, library-validation exception, privileged entitlement, or legacy `SMJobBless` configuration is added. The daemon also disables automatic injection of development/debugging entitlements.

## Checks Completed

- `plutil -lint` passed for the Xcode project, entitlements, and all three plists.
- Xcode resolved both targets and the shared app scheme.
- Debug and Release builds both succeeded using the committed ad-hoc signing defaults.
- `codesign --verify --strict --verbose=2` passed for the app, standalone daemon product, and embedded daemon in both configurations.
- Release signature inspection confirmed `arm64`, `Signature=adhoc`, `TeamIdentifier=not set`, and the `runtime` flag for both binaries. The daemon's effective entitlement dictionary is empty.
- Bundle inspection confirmed `LSUIElement`, the `BundleProgram` executable, matching bundle/Mach service identities, executable permissions, and the daemon's embedded Info.plist in both configurations.
- Production Swift sources contain no subprocess spawning, SMC calls, registration calls, or polling timers.
- `git diff --check` passed.

For example, after a Release build:

```sh
codesign --verify --strict --verbose=2 \
  .build/DerivedData/Build/Products/Release/Helios.app
codesign --verify --strict --verbose=2 \
  .build/DerivedData/Build/Products/Release/Helios.app/Contents/Library/HelperTools/HeliosDaemon
```

Xcode emitted a non-fatal App Intents metadata warning because this app does not use App Intents. The sandbox also produced simulator-service diagnostics during this macOS-only build; both native builds completed successfully.

## Validation Boundary

No service was registered, installed into `/Applications` or system launchd directories, or run as root. No fan state was read or changed. Runtime UI interaction, privileged connection authorization, the 5-second lease, SMC restoration behavior, and performance targets are later-phase work.

An ad-hoc signature proves local code integrity, not a Personal Team identity or eligibility for daemon registration. The installed SDK's `ServiceManagement.framework/Headers/SMAppService.h` states that apps using SMAppService must be signed and that apps containing LaunchDaemons must be notarized. It also documents administrator approval and re-registration after helper changes. Registration on this Tahoe release must be validated separately; this scaffold makes no registration guarantee and includes no approval bypass.

The approved foundation is recorded in `SPEC.md`: System versus 100% Boost/Auto Max takeover, explicit Override, app-owned telemetry/curves, fresh-calculation leases enforced by the daemon, separate battery/system power labels, 1-second visible UI updates, and 60-second app-attribution sampling. These requirements are documented but intentionally not implemented in Phase 1.
