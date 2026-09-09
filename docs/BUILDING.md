# Building Helios from source

Helios is an Apple-Silicon-only macOS project written in Swift 6 with AppKit, SwiftUI and native system frameworks.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 13.0+
- current Xcode / macOS SDK capable of compiling Swift 6
- Apple Development signing identity for authenticated helper/XPC operation

No third-party package manager or runtime dependency is required.

## Local signing configuration

The repository keeps machine/developer-specific signing configuration outside source control.

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit the new ignored file:

```text
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_IDENTITY = Apple Development
```

Both `Helios.app` and the embedded `HeliosDaemon` must be signed by the same valid Team identity. Helios validates its XPC peer and intentionally does not accept ad-hoc/debugger-injectable peers for normal helper operation.

## Xcode

Open:

```text
Helios.xcodeproj
```

Use the shared `HeliosApp` scheme. Building the app also builds and embeds the helper.

The helper trust model rejects debugger/injection exception entitlements. For a normal signed helper-connected run, launch the built application directly or disable **Debug executable** in the scheme when appropriate.

## Command-line build

Debug:

```sh
xcodebuild \
  -project Helios.xcodeproj \
  -scheme HeliosApp \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  build
```

Release:

```sh
xcodebuild \
  -project Helios.xcodeproj \
  -scheme HeliosApp \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  build
```

Artifacts are produced under:

```text
.build/DerivedData/Build/Products/<configuration>/Helios.app
```

## Regression gate

Before treating a change as valid, run:

```sh
./scripts/check-all.sh
```

A complete pass ends with:

```text
PASS full Helios regression gate and Xcode build
```

The suite includes read-only/simulated checks around telemetry, persistence, presentation, XPC authentication, fan ownership/lifecycle and safety invariants. Generic regression runs must not be used as an excuse to broaden or physically exercise fan writes on unvalidated hardware.

## Release/performance validation

The repository also contains dedicated Release/performance tooling, including:

```sh
./scripts/perf-prepare-release.sh
./scripts/perf-final-core-suite.sh 90
./scripts/perf-ui-memory-check.sh 3
```

Performance numbers are meaningful only when the exact executable, machine, power state, preset, UI state and methodology are comparable.

## Public distribution

A local Apple Development build is not the final public distribution format. A user-friendly release needs Developer ID Application signing, hardened-runtime validation, Apple notarization, stapling and clean-machine installation/helper testing.

Helios should never instruct users to disable Gatekeeper as a distribution workaround.
