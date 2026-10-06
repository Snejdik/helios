#!/bin/bash
# Parent-only offline validation. Compiles a standalone value-check entry point;
# excludes HeliosApp, DaemonService, DaemonClient and every daemon entry point.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TMPDIR:?Set TMPDIR to the approved parent validation scratch directory}"
case "$TMPDIR" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*)
    echo "Use profile scratch or the system per-user TMPDIR, not /tmp." >&2
    exit 1 ;;
esac
fixture_workdir="$(mktemp -d "${TMPDIR%/}/helios-ui-fixtures.XXXXXX")"
trap 'rm -rf "$fixture_workdir"' EXIT
mkdir -p "$fixture_workdir/ModuleCache"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$fixture_workdir/ModuleCache" \
  -framework AppKit -framework IOKit -framework Security -framework SystemConfiguration \
  -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth -framework CoreAudio \
  -framework UserNotifications -lproc \
  Sources/Shared/*.swift Sources/HeliosApp/Telemetry/*.swift \
  Sources/HeliosApp/HeliosUpdateChecker.swift \
  Sources/HeliosApp/Diagnostics/DiagnosticsModels.swift Sources/HeliosApp/Diagnostics/DiagnosticsFanLayer.swift \
  Sources/HeliosApp/PresentationValues.swift \
  Sources/HeliosApp/V2/HeliosVocabulary.swift Sources/HeliosApp/V2/HeliosAssessment.swift \
  Sources/HeliosApp/V2/HeliosActivity.swift \
  Tests/Fixtures/UIFixtureCatalog.swift Tests/UIFixtureChecks.swift Tests/HeliosAssessmentChecks.swift \
  -o "$fixture_workdir/UIFixtureChecks"
"$fixture_workdir/UIFixtureChecks"
