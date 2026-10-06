# Building Helios from source

Helios is an Apple-Silicon-only macOS project written in Swift 6 with AppKit, SwiftUI and native system frameworks.

For a supplied test app, use [Installation](INSTALLATION.md). This page is for
developers compiling the source; a local build is not a distributable beta.

## Get the source

```sh
git clone https://github.com/Snejdik/helios.git
cd helios
```

Open Xcode once to finish installing its components. In Xcode → Settings →
Locations, select the intended Command Line Tools installation. Verify the tools
and shared schemes before building:

```sh
xcodebuild -version
xcrun swift --version
xcodebuild -list -project Helios.xcodeproj
```

The app scheme is **HeliosApp** (not `Helios`).

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 13.0+
- current Xcode / macOS SDK capable of compiling Swift 6
- Apple Development signing identity for authenticated helper/XPC operation (a paid Developer ID is not needed to build and run locally)

No third-party package manager or runtime dependency is required.

## Local signing configuration

The repository keeps machine/developer-specific signing configuration outside source control.

```sh
test -f Config/Local.xcconfig || cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Keep an existing local override; do not overwrite another developer’s configuration.
Edit the ignored file locally (never commit your team or signing details):

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

## Run locally

After a successful Debug build, open
`.build/DerivedData/Build/Products/Debug/Helios.app` in Finder, or:

```sh
open .build/DerivedData/Build/Products/Debug/Helios.app
```

Quit other copies first. The app lives in the menu bar; since 0.2 it shows a
Dock icon only while one of its windows is open. Start in System cooling mode. Helper registration and an
authenticated connection are separate from successful compilation; use the
[installation guide](INSTALLATION.md#6-understand-permissions-and-helper-approval)
for the actual UI flow. Do not modify entitlements, trust requirements or frozen
backend hashes to make a local helper connect.

If Xcode reports a signing-team/certificate error, check the ignored local
configuration and your Xcode account. If the command uses the wrong toolchain,
check Xcode’s Command Line Tools selection. A Debug build launched under a
debugger is not evidence of production helper connectivity.

## Run the signed build

`scripts/run-helios.sh` builds a signed Release (`--build`), quits a running Helios
gracefully so the fans return to macOS (`--replace`), opens the app and can watch
its CPU and memory use (`--watch`). `scripts/watch-helios.sh` and
`scripts/watch-fan-layer.sh` measure the app and the fans without writing anything.

## Version identity

The version is `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`Config/Base.xcconfig`, and the release tag shown in About is `HeliosReleaseTag` in
`Resources/HeliosApp-Info.plist`. The tag must be a `v`-prefixed SemVer whose core
matches `MARKETING_VERSION` (for Beta 1, `v0.2.0-beta.1`). Update checks compare tags,
not build numbers.

## Regression gate

Before treating a change as valid, run:

```sh
./scripts/check-all.sh
```

A complete pass ends with:

```text
PASS full Helios regression gate and Xcode build
```

Keep the complete output and exit status. The boundary check compares protected
files against frozen hashes; do not regenerate those hashes to accept a change.
A regression pass does not prove notarization, clean-machine installation or
physical fan recovery.

The suite includes read-only/simulated checks around telemetry, persistence, presentation, XPC authentication, fan ownership/lifecycle and safety invariants. Generic regression runs must not be used as an excuse to broaden or physically exercise fan writes on unvalidated hardware.

## Offline UI fixture renders

The Helios (0.2) interface can be rendered from deterministic fixtures without
launching Helios or touching the helper:

```sh
TMPDIR="$(getconf DARWIN_USER_TEMP_DIR)" ./scripts/render-ui-fixtures.sh
```

## Release/performance validation

The repository also contains dedicated Release/performance tooling, including:

```sh
./scripts/perf-prepare-release.sh
./scripts/perf-final-core-suite.sh 90
./scripts/perf-ui-memory-check.sh 3
```

Performance numbers are meaningful only when the exact executable, machine, power state, preset, UI state and methodology are comparable.

## Distribution

Beta releases are an Apple Development signed `Helios.app`, packaged as a DMG and ZIP
and published on GitHub Releases. They are **not notarized**, so users confirm the first
launch with *Open Anyway* ([installation guide](INSTALLATION.md#4-first-launch-and-gatekeeper)).
A smoother public release needs Developer ID Application signing, hardened-runtime
validation, Apple notarization, stapling and clean-machine installation and helper testing.

Helios should never instruct users to disable Gatekeeper as a distribution workaround.
