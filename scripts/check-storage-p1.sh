#!/bin/bash
# Static architecture guard for Performance P1b storage caching. No hardware writes.
set -euo pipefail
cd "$(dirname "$0")/.."
file="Sources/HeliosApp/Telemetry/StorageProvider.swift"
monitor="Sources/HeliosApp/Telemetry/TelemetryMonitor.swift"

required=(
  'struct StorageInventoryRefreshPolicy'
  'topologySeconds: 5'
  'metadataSeconds: 300'
  'func topologySnapshot()'
  'func discoverInventory()'
  'fileprivate final class StorageCounterSource'
  'IOObjectRetain(entry)'
  'IOObjectRelease(entry)'
  'private var counterSources: [UInt64: StorageCounterSource] = [:]'
  'try refreshInventoryIfNeeded(reader: reader, ticks: ticks)'
  'try readCounters(for: device)'
  'counterFailureNeedsRediscovery'
)
for needle in "${required[@]}"; do
  if ! grep -Fq "$needle" "$file"; then
    echo "FAIL P1b storage optimization guard missing: $needle" >&2
    exit 1
  fi
done

# The rejected P1 implementation resolved each cached registry ID through a new
# matching lookup every sample. P1b must retain the discovered service handle
# instead; otherwise the supposed fast path can cost more than enumeration.
if grep -Fq 'IORegistryEntryIDMatching(counterRegistryID)' "$file"; then
  echo "FAIL P1b reintroduced per-sample IORegistryEntryIDMatching lookup" >&2
  exit 1
fi
# P1b must preserve the established two-second live storage sampling contract.
if ! grep -Fq 'interval: .seconds(2), prepare: { [storage] in await storage.reset() }' "$monitor"; then
  echo "FAIL P1b changed the established 2s live storage sampler cadence" >&2
  exit 1
fi

# Full IOMedia enumeration/ancestor walking belongs only to slow discovery.
sample_body="$(sed -n '/    func sample() -> MetricSample<StorageMetrics> {/,/^    private func refreshInventoryIfNeeded/p' "$file")"
if grep -Fq 'IOServiceGetMatchingServices' <<<"$sample_body" || grep -Fq 'ancestors(from:' <<<"$sample_body"; then
  echo "FAIL P1b reintroduced full IOMedia discovery into the 2s provider hot path" >&2
  exit 1
fi

printf '%s\n' "PASS Performance P1b storage architecture: 2s counters read retained IOKit sources; topology/static metadata are slow-cadence with bounded rediscovery"
