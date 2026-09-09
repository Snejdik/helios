#!/bin/bash
# Shipping-contract guard for Apple Silicon-only builds. No hardware writes.
set -euo pipefail
cd "$(dirname "$0")/.."

base="Config/Base.xcconfig"
agents="AGENTS.md"

for needle in 'ARCHS = arm64' 'MACOSX_DEPLOYMENT_TARGET = 13.0' 'SUPPORTED_PLATFORMS = macosx'; do
  grep -Fq "$needle" "$base" || { echo "FAIL Apple-Silicon release config missing: $needle" >&2; exit 1; }
done

grep -Fq 'Production fan writes remain pinned to the exact validated Mac16,1/25G83 profile' "$agents" || {
  echo 'FAIL compatibility contract no longer keeps unvalidated Macs read-only' >&2; exit 1;
}

# The read-only telemetry layer must not be globally gated to the M4 validation model.
for file in Sources/HeliosApp/Telemetry/CPUProvider.swift Sources/HeliosApp/Telemetry/MemoryProvider.swift Sources/HeliosApp/Telemetry/GPUProvider.swift Sources/HeliosApp/Telemetry/NetworkProvider.swift Sources/HeliosApp/Telemetry/StorageProvider.swift Sources/HeliosApp/Telemetry/SystemProvider.swift; do
  if grep -Eq 'Mac16,1|25G83' "$file"; then
    echo "FAIL read-only provider is hard-gated to validation hardware: $file" >&2
    exit 1
  fi
done

# Thermal grouping may remain generation-specific, but unknown generations must degrade to unclassified instead of failing construction.
grep -Fq 'else { return .unclassified }' Sources/HeliosApp/Telemetry/ThermalProvider.swift || {
  echo 'FAIL unknown Apple Silicon thermal keys do not degrade to advisory/unclassified' >&2; exit 1;
}

printf '%s\n' 'PASS Apple Silicon release contract: arm64/macOS13+, capability-based read-only providers, unknown thermals degrade safely, and fan writes remain exact-profile gated'
