# Helios External-Beta Diagnostics Architecture

Status: authoritative pre-implementation contract for the public external beta

Contract version: 0.1

Applies to: Helios native app, the future `snejda.cz` diagnostics API and its owner dashboard

Public contact: `helios@snejda.cz`

## Normative language and decision labels

`MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, and `MAY` are normative.

- **FIXED DECISION** is an approved product or privacy boundary. Implementation may not change it without an explicit privacy/security review and an update to this document first.
- **RECOMMENDATION** is the preferred implementation. A different choice needs a recorded reason and must preserve every fixed boundary.
- **OPEN IMPLEMENTATION DETAIL** is intentionally unresolved and must be closed at the named checkpoint before shipping.

Schema changes are deny-by-default. Adding a field, enum case, report type, collection source, transmission trigger, retention purpose, or downstream processor requires: (1) updating this document and the JSON Schema, (2) privacy review, (3) preview and transport tests, (4) backend validation tests, and (5) user-facing disclosure review. A client property becoming `Codable` never authorizes transmission.

## 1. Purpose and non-goals

**FIXED DECISION — Purpose.** Helios may use privacy-preserving diagnostics only to improve Apple Silicon hardware compatibility, telemetry-provider reliability, helper/XPC reliability, crash/stability understanding, performance/resource regressions, and beta compatibility testing.

**FIXED DECISION — Non-goals.** The system is not advertising analytics, behavioral analytics, engagement tracking, user profiling, attribution, growth analytics, or a remote-control channel. It has no page-view, click, feature-use, or session-event stream. Local Helios telemetry remains primarily local.

Diagnostics are optional, OFF by default, minimal, versioned, allowlist-built, user-inspectable, and reversible for future automatic sends. Diagnostics failure must never block startup or affect telemetry, cooling, fan safety, helper lifecycle, or ordinary use.

The privileged `HeliosDaemon` remains fan-only. It neither creates nor transports diagnostics. No server response may configure Helios, issue commands, alter collection, or influence fan control.

## 2. Architecture overview

**FIXED DECISION.** The only data path is:

```text
existing unprivileged app state
        |
        v
explicit allowlist snapshot builder ----> exact UTF-8 JSON preview
        |                                      |
        | same immutable Data buffer           | user inspection / manual approval
        v                                      v
URLSession in HeliosApp -- HTTPS POST --> snejda.cz Vercel route
                                              |
                                      validate before write
                                              |
                                              v
                                      Neon PostgreSQL
                                              |
                                   authenticated server reads
                                              |
                                              v
                                  /helios/admin dashboard
```

There is no diagnostics path through XPC or `HeliosDaemon`; no device/user account; no stable identifier; no database access from the native app; and no dependency on whether Cloudflare is DNS-only or proxied.

**FIXED DECISION — Apple Silicon beta scope.** The public external beta is
intended for Apple Silicon `arm64` Macs across M1, M2, M3, M4, M5 and future
families, including base, Pro, Max and Ultra variants, fanless Macs, laptops,
desktops, single-fan systems and multi-fan systems. Read-only telemetry and
diagnostics are capability-driven and MUST NOT use an allowlist of already
known Mac models as a prerequisite for reporting.

An otherwise valid future or previously unseen `machine_model` is useful
compatibility evidence and must not be rejected merely because Helios has not
seen that model before. Read-only telemetry support, diagnostics support and
compatibility evidence are separate from fan-write authorization. Fan writes
remain restricted to independently and physically validated exact
hardware/build profiles under the existing fan-safety contract.


Repository inspection found the intended native integration points:

- `HeliosOnboardingView` is the existing first-run SwiftUI window.
- `HeliosSettingsView` already has a Privacy route; it should become **Privacy & Diagnostics**.
- `HeliosPreferences` wraps `UserDefaults.standard` and versioned local preference migration. Diagnostics consent and schedule metadata should use a separate, narrowly scoped preferences type backed by the same local mechanism, not be mixed into UI preset resets.
- app version/build already come from `CFBundleShortVersionString` and `CFBundleVersion`;
- `SystemProvider` exposes model, OS and physical memory; OS build needs a deliberate safe accessor;
- telemetry uses typed `MetricResult`/`TelemetryError`, while helper registration and connection already have separate enums. Diagnostics must map these into the closed categories below rather than serialize descriptions;
- no Vercel, web, or database project exists in this repository. Future server file paths below therefore describe components in the separate `snejda.cz` project and are not assumptions about its framework.

## 3. Trust and privacy boundaries

### 3.1 Absolute prohibited-data boundary

**FIXED DECISION.** Neither automatic nor manual report payloads may contain, derive, hash, pseudonymize, or encode:

- real/full name, username/account name, email address, or Apple ID;
- hostname/computer name, serial number, hardware UUID, installation UUID, device UUID, stable random client ID, or any persistent per-device identifier;
- MAC address, local or public IP in application JSON, SSID, BSSID, router/gateway identity, or DNS-server identities;
- paths, filenames, file contents, documents, clipboard, browser history/URLs, shell or command history, or environment variables;
- process names, application names, installed/user application bundle identifiers, or window titles;
- mounted-volume names or external-device serial numbers;
- a persistent fingerprint assembled from otherwise permitted fields.

Forbidden workarounds include `hash(serial_number)`, `hash(hostname)`, `hash(MAC)`, `hash(machineModel + RAM + OS + serial)`, and `installationUUID`.

### 3.2 Permitted sources

**FIXED DECISION.** Automatic payload construction may read only the already-held, unprivileged, safe summary values explicitly listed in section 6. It may not trigger heavy inventories, enumerate applications/processes/devices, read raw SMC inventory, or collect more precise data merely to prepare a report.

Manual compatibility construction may run the specifically disclosed read-only probes in section 7 only after the user chooses **Create compatibility report**. It may never cause SMC writes or privileged-helper work.

### 3.3 Transport-level IP reality

**FIXED DECISION.** The Helios JSON body never contains an IP address. Cloudflare, Vercel, network infrastructure, and their security systems may technically observe source IP information during ordinary HTTP transport. The application route must not copy forwarding headers or source IP into diagnostic records, application logs, errors, metrics, or downstream analytics; must not log entire request objects; and must not dump headers.

The product phrase is **privacy-preserving diagnostics**. Helios must not claim “100% anonymous,” “fully anonymous,” or “the server never sees your IP.” Actual infrastructure behavior and retention must be verified and disclosed before beta.

### 3.4 Boundary ownership

| Boundary | Trusted responsibility | Explicit exclusion |
|---|---|---|
| HeliosApp | consent, allowlist build, preview, local cadence, HTTPS send | identity, remote commands, privileged transport |
| HeliosDaemon | existing fan-only safety contract | all diagnostics collection and networking |
| Public API | size/content/schema validation, report-only acknowledgement, insert | accepting extensions, identity persistence, command/config response |
| PostgreSQL | validated reports, bounded retention, safe aggregates | IP/header/user/device columns |
| Owner dashboard | authenticated report review and aggregates | public access, “unique user” inference |
| Cloudflare/Vercel | ordinary transport/hosting and abuse controls | application diagnostic fields; undocumented privacy claims |

## 4. Consent UX

### 4.1 First launch

**FIXED DECISION.** Add a distinct page to the existing onboarding flow after interface-preset selection and before completion:

> **Help improve Helios Beta**
>
> Helios is being tested across different Apple Silicon Macs. You can optionally share privacy-preserving technical diagnostics to help improve hardware compatibility and stability. No diagnostic information is sent unless you enable this option.

Controls:

- unchecked checkbox: **Share beta diagnostics**;
- link/button: **View exactly what is shared**;
- **Continue**, enabled regardless of checkbox state.

The checkbox is never pre-checked. There is no donation message, urgency, visual penalty, feature gating, or repeated prompt. Continue first commits the local choice, then completes onboarding. No automatic-diagnostics networking object may be created or scheduled while consent is `notDecided`, and no automatic request may start until the persisted automatic-consent state has been read for the current launch and is `enabled`.

Persisted automatic consent is not required for `manual_health` or `manual_compatibility`. A manual network request may exist only after the user explicitly initiates that manual action, Helios builds and freezes the exact payload, the user sees the exact payload preview, and the user separately confirms **Send**. Preview generation performs zero network requests. The one-shot approval applies only to those frozen bytes, does not enable automatic diagnostics or persist as general consent, and is invalidated if the payload is regenerated.

### 4.2 Local consent state

**RECOMMENDATION.** Create `DiagnosticsPreferences`, backed by `UserDefaults.standard`, with explicit keys under a new versioned namespace such as `betaDiagnostics.v1.*`. Use a three-state internal consent enum (`notDecided`, `disabled`, `enabled`) rather than treating a missing key as enabled. Store no server-side consent account.

Local scheduling metadata may include only: consent state, consent revision, last successful send time, last status/category, last successfully reported Helios version/build and macOS build, the start time of the most recent automatic attempt chain (`lastAutomaticChainStartedAt` or an equivalent key), pending retry count and next eligible time. It must not include a generated client ID. These local fields are never uploaded merely because they exist; the automatic-chain timestamp is local scheduling state, not a device identifier.

Consent remains independent from interface-preset reset and “show welcome setup again.” A deliberate erase-all-local-data flow may remove it, returning the next clean launch to `notDecided`/OFF.

### 4.3 Opt-out

**FIXED DECISION.** Switching OFF synchronously persists `disabled`, cancels queued delays/retries and any not-yet-started task, and prevents future automatic sends. If an HTTP request has already begun, cancellation is best effort; the UI must not claim it recalled or deleted an already received report. Turning OFF does not remove unrelated preferences/history and does not promise server deletion.

## 5. Settings UX

**FIXED DECISION.** Rename the current Settings Privacy route to **Privacy & Diagnostics** and include:

| Control | Behavior |
|---|---|
| Share beta diagnostics — ON/OFF | Explicit automatic-consent state; OFF by default |
| Last successful report — date/Never | Local record only; display in the user's locale, never upload locale/time zone |
| Last report status — Success/Failed/Not sent | A user-readable mapping from closed local status categories |
| View exactly what is shared | Builds and displays the current automatic payload without sending |
| Send diagnostic report now | Builds, previews, and sends `manual_health` after explicit confirmation |
| Create compatibility report | Starts the separate two-stage flow in section 7 |
| Privacy information | Opens the future public privacy document in the external browser |

**FIXED DECISION.** “Send diagnostic report now” is manual and uses the safe automatic field set; it does not bypass schema validation. Manual actions are available while automatic diagnostics is OFF and do not silently enable it.

Every manual send follows the one-shot contract in section 4.1: explicit initiation, one exact frozen payload, exact preview, and separate Send confirmation. No request is created by preview generation, and regenerating the payload invalidates the prior approval.

The existing statement “Background network: None” must be changed before diagnostics ships so the UI accurately reflects enabled diagnostics. This document does not authorize that source edit now.

## 6. Exact automatic JSON schema

### 6.1 Encoding rules

**FIXED DECISION.** Schema version is integer `1`. JSON is UTF-8, one top-level object, no duplicate keys, no comments, no NaN/infinity, maximum nesting depth 6, and no unknown properties at any level. Dates are UTC RFC 3339 strings. `generated_at` is truncated to the minute to avoid needless precision. Optional unavailable fields are omitted; `null` is rejected. Strings are length-bounded and, where stated, enum- or pattern-constrained. Numeric buckets are serialized as enum strings, never precise values.

The three report types are exactly `automatic_health`, `manual_health`, and `manual_compatibility`. There are no generic event envelopes.

### 6.2 Automatic/manual-health shape

This is the complete version-1 payload for `automatic_health` and `manual_health`:

```json
{
  "schema_version": 1,
  "report_type": "automatic_health",
  "generated_at": "2026-09-10T12:34:00Z",
  "report_reason": "daily",
  "helios": {
    "version": "0.1.0",
    "build": "1"
  },
  "system": {
    "macos_version": "26.6.2",
    "macos_build": "25G83",
    "machine_model": "Mac16,1",
    "architecture": "arm64",
    "apple_silicon_family": "M4",
    "memory_bucket_gib": "9-16",
    "fan_count": 1,
    "battery_present": true
  },
  "capabilities": {
    "cpu": "available",
    "memory": "available",
    "gpu": "available",
    "thermal": "available",
    "fan_telemetry": "available",
    "battery": "available",
    "storage": "available",
    "nvme_smart": "available",
    "network": "available",
    "wifi": "partial",
    "bluetooth": "available",
    "energy_process": "unknown"
  },
  "providers": {
    "cpu": { "state": "available", "failure_count": "0" },
    "memory": { "state": "available", "failure_count": "0" },
    "gpu": { "state": "available", "failure_count": "0" },
    "thermal": { "state": "available", "failure_count": "0" },
    "fan_telemetry": { "state": "available", "failure_count": "0" },
    "battery": { "state": "available", "failure_count": "0" },
    "storage": { "state": "available", "failure_count": "0" },
    "nvme_smart": { "state": "available", "failure_count": "0" },
    "network": { "state": "available", "failure_count": "0" },
    "wifi": {
      "state": "partial",
      "failure_category": "permission_denied",
      "failure_count": "1"
    },
    "bluetooth": { "state": "available", "failure_count": "0" },
    "energy_process": { "state": "not_observed", "failure_count": "0" }
  },
  "helper": {
    "installation_state": "installed",
    "connection_state": "connected",
    "protocol_compatibility": "compatible"
  },
  "runtime": {
    "memory_footprint_mib": "17-32",
    "cpu_percent": "0.2-1",
    "session_duration": "15m-1h",
    "provider_failure_total": "1",
    "diagnostics_error_category": "none"
  },
  "stability": {
    "previous_session_ended_uncleanly": false,
    "previous_session_duration": "1-6h",
    "lifecycle_category": "normal_launch"
  }
}
```

For `manual_health`, only `report_type` and `report_reason` differ: they must be `manual_health` and `user_initiated`.

This example includes `machine_model`, `fan_count`, and `battery_present` because they are safely known in the illustrated snapshot. A valid automatic or manual-health payload omits any of those OPTIONAL fields that is not safely known; it never encodes `null` or a fabricated substitute.

### 6.3 Field allowlist

Requirement meanings: **REQUIRED** must be present. **OPTIONAL** may be omitted only when not safely/non-ambiguously available. **REJECTED** must not appear.

| Path | Requirement and allowed value | Purpose |
|---|---|---|
| `schema_version` | REQUIRED integer `1` | Select exact validator |
| `report_type` | REQUIRED `automatic_health` or `manual_health` | Separate scheduled and explicit safe reports |
| `generated_at` | REQUIRED minute-truncated UTC timestamp | Diagnose delay/staleness without fine timing |
| `report_reason` | REQUIRED; automatic: `initial_opt_in`, `daily`, `helios_version_changed`, `macos_build_changed`; manual: `user_initiated` | Explain bounded trigger |
| `helios` | REQUIRED closed object | App compatibility context |
| `helios.version` | REQUIRED 1–32 chars, semantic-version-shaped | Release grouping |
| `helios.build` | REQUIRED 1–32 ASCII alphanumeric/`.`/`-` chars | Build regression grouping |
| `system` | REQUIRED closed object | Hardware/OS compatibility context |
| `system.macos_version` | REQUIRED 1–32 numeric/dot chars | OS compatibility grouping |
| `system.macos_build` | REQUIRED 1–32 ASCII alphanumeric chars | Exact OS-build regressions |
| `system.machine_model` | OPTIONAL only when not safely available; otherwise REQUIRED; 4–32 ASCII chars matching `^[A-Za-z][A-Za-z0-9]*[0-9],[0-9]{1,3}$` | Exact hardware product-class identifier from the existing safe `hw.model` source; never a serial/device identifier or matched against a known-model allowlist |
| `system.architecture` | REQUIRED enum `arm64` | Reject unintended platforms |
| `system.apple_silicon_family` | OPTIONAL enum `M1`, `M2`, `M3`, `M4`, `M5`, `future`, `unknown` | Coarse family grouping only when safe derivation is reviewed |
| `system.memory_bucket_gib` | REQUIRED enum `<=8`, `9-16`, `17-32`, `33-64`, `65-128`, `>128`, `unknown` | Coarse resource compatibility |
| `system.fan_count` | OPTIONAL integer 0–8; include only when safely known from already available unprivileged state | Fanless/one-/multi-fan compatibility; `0` means positively known fanless, never unknown |
| `system.battery_present` | OPTIONAL boolean; include only when safely known from already available unprivileged state | Battery capability split; `false` means positively known no battery, never unknown |
| `capabilities` | REQUIRED closed object with every listed child | Snapshot of feature availability without provider contents |
| `capabilities.{cpu,memory,gpu,thermal,fan_telemetry,battery,storage,nvme_smart,network,wifi,bluetooth,energy_process}` | each REQUIRED enum `available`, `partial`, `unavailable`, `failed`, `unknown` | Stable compatibility matrix. `unknown` means capability cannot be safely determined from already available unprivileged state and conveys no reason |
| `providers` | REQUIRED closed object with the same 12 named children | Operational health, distinct from capability |
| `providers.<name>.state` | REQUIRED enum `available`, `partial`, `unavailable`, `failed`, `not_observed` | Current-launch provider state. `not_observed` means Helios has no safe operational observation in this launch and conveys no reason |
| `providers.<name>.failure_category` | OPTIONAL; required for `partial` or `failed`; permitted for `unavailable` only when an actual observation produced the category; prohibited for `available` and `not_observed`; enum `permission_denied`, `unsupported`, `no_data`, `invalid_data`, `io_error`, `timed_out`, `other` | Safe coarse debugging of observed conditions only; never raw error text, startup/warming state, an inferred cause, or the user's module preferences |
| `providers.<name>.failure_count` | REQUIRED enum `0`, `1`, `2-5`, `6-20`, `21+` | Failures observed during the current app launch only, bucketed before encoding |
| `helper` | REQUIRED closed object | Helper/XPC compatibility, not commands |
| `helper.installation_state` | REQUIRED enum `missing`, `requires_approval`, `installed`, `unavailable` | Map existing registration state |
| `helper.connection_state` | REQUIRED enum `disconnected`, `connecting`, `connected`, `signing_required`, `version_mismatch`, `failed` | Map existing XPC connection state |
| `helper.protocol_compatibility` | REQUIRED enum `compatible`, `mismatch`, `not_checked` | Version compatibility only |
| `helper.failure_category` | OPTIONAL enum `signing`, `approval`, `protocol`, `timeout`, `connection`, `registration`, `other` | Coarse failure grouping; no messages, PIDs, UIDs, nonces, or sequences |
| `runtime` | REQUIRED closed object | Coarse Helios-only resource health |
| `runtime.memory_footprint_mib` | REQUIRED enum `<=16`, `17-32`, `33-64`, `65-128`, `129-256`, `>256`, `unknown` | Memory regression grouping |
| `runtime.cpu_percent` | REQUIRED enum `<0.2`, `0.2-1`, `1-5`, `5-20`, `>20`, `unknown` | Helios-only CPU regression grouping |
| `runtime.session_duration` | REQUIRED enum `<5m`, `5-15m`, `15m-1h`, `1-6h`, `6-24h`, `>24h`, `unknown` | Duration of the current Helios launch only; not engagement analytics or reconstructed history |
| `runtime.provider_failure_total` | REQUIRED enum `0`, `1`, `2-5`, `6-20`, `21+` | Total provider failures observed during the current app launch only, bucketed before encoding |
| `runtime.diagnostics_error_category` | REQUIRED enum `none`, `build`, `encode`, `schedule`, `transport`, `server_rejected`, `other` | Current-launch diagnostics-subsystem errors only, without error text |
| `stability` | REQUIRED closed object | Minimal previous-session health |
| `stability.previous_session_ended_uncleanly` | REQUIRED boolean | Initial crash/stability signal |
| `stability.previous_session_duration` | OPTIONAL duration bucket using runtime enum | Adds coarse context if a reliable local marker exists |
| `stability.lifecycle_category` | REQUIRED enum `first_launch`, `normal_launch`, `after_update`, `after_macos_update`, `after_unclean_exit`, `unknown` | Safe lifecycle grouping, not an event stream |

A confidently recognized family may use `M1` through `M5`. A newer family not yet represented by the schema uses `future`; an ambiguous derivation uses `unknown` or omits this OPTIONAL field. An unfamiliar Apple Silicon family or machine model must never make an otherwise valid diagnostic report unsupported.

`system.machine_model` is the hardware product-class identifier obtained from the existing safe `hw.model` source when available. The bounded ASCII grammar accepts legacy-style Apple Silicon identifiers such as `MacBookAir10,1`, `MacBookPro17,1`, `Macmini9,1`, and `iMac21,1`, current-style identifiers such as `Mac14,2` and `Mac16,1`, and previously unseen identifiers using the same product-class grammar. It is not matched against a known-model allowlist, normalized, or treated as a serial/device identifier. If it is not safely available, it is omitted rather than fabricated.

`system.fan_count` and `system.battery_present` are likewise omitted when not safely known from already available unprivileged state. The automatic builder must not inspect a known-model table, infer laptop/desktop or fanless status, trigger a new SMC/battery probe merely to populate them, substitute `0` for an unknown fan count, or substitute `false` for unknown battery presence. JSON `null` remains rejected; absence represents not safely known for this report.

**FIXED DECISION — Observation, capability, and runtime windows.** A provider that has no safe operational observation in the current launch is `not_observed`. This covers startup timing, collection gating, user configuration, and any other non-failure cause without distinguishing or transmitting the cause. The diagnostics builder must not inspect module/UI preferences merely to classify why a provider was not observed.

Capabilities remain conceptually independent from selected UI/module configuration and may report a safely known capability even when the current provider state is `not_observed`. Capability `unknown` means Helios cannot safely determine support from already available unprivileged state for this report. It conveys no cause. The builder must not inspect module/UI preferences or trigger a new probe merely to avoid `unknown`; equivalent lack of safe observation caused by configuration, startup timing, or collection gating must produce the same cause-free capability state. Provider `not_observed` and capability `unknown` are separate: the former describes current-launch operational observation, while the latter describes whether support is safely known.

Every `providers.<name>.failure_count` and `runtime.provider_failure_total` counts only failures actually observed during the current Helios app launch. Counters reset on the next launch, are bucketed before encoding, are not persisted cumulatively across launches, and must never be joined or interpreted as cross-report identity/history. A `not_observed` provider has `failure_count: "0"` and no `failure_category`; no failure or reason is inferred.

`runtime.diagnostics_error_category` also resets to `none` on every Helios launch. It describes only diagnostics-subsystem errors observed during the current launch, is never derived from the persisted Settings-visible Last report status or any previous-launch diagnostics history, and is not cumulatively persisted. The local Last report status remains available for UX but is never automatically copied into a payload. `runtime.session_duration` is the duration of the current Helios launch only and must not be reconstructed from persisted usage or session history.

### 6.4 Explicitly rejected automatic fields

**FIXED DECISION.** In addition to section 3, the automatic schema rejects raw provider samples, temperatures, RPM, fan limits/modes/commands, SMC keys/values/writes, battery capacities/cycles/charge, storage names/capacity/SMART values, network rates/addresses/interface names, Wi-Fi radio details, Bluetooth/device inventories, display/audio/USB inventories, processes/PIDs/names/bundle IDs, exact CPU/memory/resource counters, local history, cross-launch/cumulative failure counts, module preference state or inferred disablement, logs, stack traces, crash dumps, error descriptions, file data, helper command/history/PID/UID/session/nonce/sequence, consent history, donation data, and arbitrary metadata/tags.

## 7. Exact manual compatibility JSON schema

### 7.1 Consent flow

**FIXED DECISION.** Automatic consent never authorizes raw compatibility upload. The flow is:

1. User chooses **Create compatibility report**.
2. Helios explains that it will run a bounded read-only hardware probe and lists the categories.
3. User chooses **Generate preview**; generation alone performs no network request.
4. Helios displays the exact frozen JSON bytes.
5. Only a separate explicit **Send report** action sends those bytes.

Persisted automatic consent is not required. Closing, canceling, editing state, or regenerating invalidates prior send approval. Approval applies only to the displayed frozen bytes, does not enable automatic diagnostics or persist as general consent, and the flow works when automatic diagnostics is OFF. There is no automatic retry for this one-shot report; a failure leaves the same frozen preview visible and lets the user explicitly retry it.

### 7.2 Shape

`manual_compatibility` reuses the exact `helios`, `system`, `capabilities`, `providers`, `helper`, `runtime`, and `stability` objects from section 6 and adds only `raw_hardware` and `helios_classification`:

```json
{
  "schema_version": 1,
  "report_type": "manual_compatibility",
  "generated_at": "2026-09-10T12:34:00Z",
  "report_reason": "user_initiated_compatibility",
  "helios": { "version": "0.1.0", "build": "1" },
  "system": {
    "macos_version": "26.6.2",
    "macos_build": "25G83",
    "machine_model": "Mac16,1",
    "architecture": "arm64",
    "apple_silicon_family": "M4",
    "memory_bucket_gib": "9-16",
    "fan_count": 1,
    "battery_present": true
  },
  "capabilities": { "cpu": "available", "memory": "available", "gpu": "available", "thermal": "available", "fan_telemetry": "available", "battery": "available", "storage": "available", "nvme_smart": "available", "network": "available", "wifi": "available", "bluetooth": "available", "energy_process": "available" },
  "providers": {
    "cpu": { "state": "available", "failure_count": "0" },
    "memory": { "state": "available", "failure_count": "0" },
    "gpu": { "state": "available", "failure_count": "0" },
    "thermal": { "state": "available", "failure_count": "0" },
    "fan_telemetry": { "state": "available", "failure_count": "0" },
    "battery": { "state": "available", "failure_count": "0" },
    "storage": { "state": "available", "failure_count": "0" },
    "nvme_smart": { "state": "available", "failure_count": "0" },
    "network": { "state": "available", "failure_count": "0" },
    "wifi": { "state": "available", "failure_count": "0" },
    "bluetooth": { "state": "available", "failure_count": "0" },
    "energy_process": { "state": "available", "failure_count": "0" }
  },
  "helper": { "installation_state": "installed", "connection_state": "connected", "protocol_compatibility": "compatible" },
  "runtime": { "memory_footprint_mib": "17-32", "cpu_percent": "0.2-1", "session_duration": "15m-1h", "provider_failure_total": "0", "diagnostics_error_category": "none" },
  "stability": { "previous_session_ended_uncleanly": false, "previous_session_duration": "1-6h", "lifecycle_category": "normal_launch" },
  "raw_hardware": {
    "smc_thermal_discovery": [
      { "key": "Tp01", "data_type": "sp78", "data_size": 2, "read_state": "readable", "decoded_celsius": 47.5 },
      { "key": "Te06", "data_type": "flt ", "data_size": 4, "read_state": "readable", "decoded_celsius": 48.75 }
    ],
    "fan_topology": [
      { "index": 0, "range_state": "partial", "minimum_rpm": 2317, "actual_rpm": 2488 }
    ],
    "provider_diagnostics": [
      { "provider": "thermal", "stage": "decode", "category": "invalid_data", "occurrences": "1" }
    ]
  },
  "helios_classification": {
    "thermal_channels": [
      { "key": "Tp01", "semantic_group": "performance_core", "classification_source": "helios_rule_v1" },
      { "key": "Te06", "semantic_group": "validated_hotspot", "classification_source": "helios_rule_v1" }
    ],
    "fan_topology_class": "single_fan",
    "compatibility_state": "needs_review"
  }
}
```

### 7.3 Additional field allowlist

All reused section-6 fields retain their requirements and constraints, except `report_type` is REQUIRED `manual_compatibility` and `report_reason` is REQUIRED `user_initiated_compatibility`.

| Path | Requirement and allowed value | Purpose |
|---|---|---|
| `raw_hardware` | REQUIRED closed object | Clearly labels measured/read-only facts |
| `raw_hardware.smc_thermal_discovery` | REQUIRED array, 0–512 entries | Bounded thermal key discovery |
| `...[].key` | REQUIRED exactly 4 printable ASCII characters (0x20–0x7E), preserving case, spaces, and punctuation; control characters prohibited; no normalization | Exact raw discovered SMC key name |
| `...[].data_type` | OPTIONAL exactly 4 printable ASCII characters (0x20–0x7E), preserving case, spaces, and punctuation; control characters prohibited; no normalization | Exact SMC data-type code when safely available from discovery metadata; future types are preserved rather than collapsed |
| `...[].data_size` | OPTIONAL integer 1–32 | Bounded SMC value size when safely available from discovery metadata |
| `...[].read_state` | REQUIRED enum `readable`, `unreadable`, `decode_failed` | Distinguish discovery/read/decode |
| `...[].decoded_celsius` | OPTIONAL finite number from -100 through 250, max 3 decimal places; allowed with `read_state: readable` whenever the existing read-only thermal decoder safely produced the value | Smallest useful raw temperature value; no friendly physical identity is required |
| `...[].failure_category` | OPTIONAL closed provider-failure enum; required unless readable | No free-form error leakage |
| `raw_hardware.fan_topology` | REQUIRED array, 0–8 entries | Fanless, single-, and dual-/multi-fan support |
| `...[].index` | REQUIRED integer 0–7 | Ephemeral topology position, not identity |
| `...[].range_state` | REQUIRED enum `available`, `partial`, `unavailable`, `read_failed` | Exact disposition of safe read-only range discovery; missing limits are never inferred |
| `...[].minimum_rpm` | OPTIONAL integer 0–100000; required with maximum when `range_state` is `available` | Safely observed read-only minimum; never inferred |
| `...[].maximum_rpm` | OPTIONAL integer 0–100000 and >= minimum when both exist; required with minimum when `range_state` is `available` | Safely observed read-only maximum; never inferred |
| `...[].actual_rpm` | OPTIONAL integer 0–100000 | One preview-time read-only observation |
| `raw_hardware.provider_diagnostics` | REQUIRED array, 0–64 entries | Bounded capability failure evidence |
| `...[].provider` | REQUIRED one of the 12 provider names | Identify affected provider |
| `...[].stage` | REQUIRED enum `discover`, `open`, `read`, `decode`, `validate`, `sample` | Safe failure location |
| `...[].category` | REQUIRED provider-failure enum | Coarse failure class |
| `...[].code_domain` | OPTIONAL enum `mach`, `iokit`, `smc`, `posix`, `osstatus` | Interpret numeric code without text |
| `...[].numeric_code` | OPTIONAL signed 32-bit integer; permitted only with `code_domain` | Reproducible API/driver result |
| `...[].occurrences` | REQUIRED enum `1`, `2-5`, `6-20`, `21+` | Bounded frequency |
| `helios_classification` | REQUIRED closed object | Explicitly separates Helios interpretation from facts |
| `helios_classification.thermal_channels` | REQUIRED array matching zero or more unique raw keys | Review semantic mapping |
| `...[].key` | REQUIRED key present in raw thermal array | Provenance join within this report only |
| `...[].semantic_group` | REQUIRED enum `performance_core`, `efficiency_core`, `gpu`, `validated_hotspot`, `unclassified` | Current Helios classification. `validated_hotspot` is independently validated for conservative thermal monitoring on an exact supported hardware/build profile without claiming a physical component or CPU-cluster identity |
| `...[].classification_source` | REQUIRED enum/version string currently `helios_rule_v1` | Classification provenance |
| `helios_classification.fan_topology_class` | REQUIRED enum `fanless`, `single_fan`, `dual_fan`, `multi_fan`, `unknown` | Product interpretation |
| `helios_classification.compatibility_state` | REQUIRED enum `supported_read_only`, `partial`, `unsupported`, `needs_review` | Triage state; never write authorization |

**FIXED DECISION.** `validated_hotspot` must not be remapped to `efficiency_core`, `performance_core`, or `gpu`; its provenance-safe meaning is intentionally non-physical. `validated_hotspot` is a generic classification concept, not an M4-, Mac16,1-, Te06-, or Te0T-specific category. Future exact hardware/build profiles may independently validate different thermal channels as `validated_hotspot` only after separate evidence and review. A safely decoded thermal value may remain `unclassified`.

For fan ranges, `available` means both safe minimum and maximum were successfully observed and requires both fields. `partial` means exactly one safe limit was successfully observed and requires exactly one of the two fields. `unavailable` means the platform or current safe read-only interface exposes no usable range and makes no claim that a read failed; both limits are omitted. `read_failed` means an approved read-only attempt for range metadata was made and returned an actual read failure; both limits are omitted. `actual_rpm` is independent and remains optional. No missing value is inferred.

**FIXED DECISION — Fan-topology cross-field invariants.** Every `fan_topology[].index` is an integer from 0 through 7 and is unique within the report. When `fan_topology_class` claims an established complete topology, all of the following are required:

- `fanless`: `system.fan_count` is REQUIRED and is 0, and `fan_topology` is empty;
- `single_fan`: `system.fan_count` is REQUIRED and is 1, there is exactly one topology entry, and its index is 0;
- `dual_fan`: `system.fan_count` is REQUIRED and is 2, there are exactly two topology entries, and their unique indexes are 0 and 1;
- `multi_fan`: `system.fan_count` is REQUIRED and is from 3 through 8, topology count equals `system.fan_count`, and indexes are unique and contiguous from 0 through `fan_count - 1`.

`unknown` may be used only when Helios has safe evidence that topology cannot be fully established or reconciled. For `unknown`, `system.fan_count` may be omitted when the complete count is not safely known. If present, it must be an independently safely known count and must not be inferred from incomplete topology entries. `unknown` must not fabricate missing fans, indexes, or ranges merely to make counts match and must not bypass validation of an otherwise complete known topology. The complete-topology count/class invariants do not apply to an honestly incomplete `unknown` topology, but all represented indexes and fields retain their individual bounds and validation rules.

Manual compatibility rejects raw SMC bytes, uncharacterized non-thermal SMC inventory, SMC write capability/results, ownership/control keys, fan commands/history, free-form error/debug strings, hardware serials/UUIDs, and every prohibited field in section 3. Raw key/type metadata and read-only fan topology do not authorize those keys or ranges as trusted thermals or write targets. Missing fan minimum/maximum values are omitted, never invented. Compatibility evidence can never bypass the daemon's independently pinned production-write gate.

## 8. Report types, cadence, and retry

### 8.1 Minimum report model

| Type | Trigger | Consent |
|---|---|---|
| `automatic_health` | bounded scheduler | automatic diagnostics must be ON |
| `manual_health` | user selects Send diagnostic report now and confirms preview | one-shot explicit send; automatic may be OFF |
| `manual_compatibility` | two-stage generate/preview/send flow | separate one-shot explicit send |

No other report or analytics event type is permitted in v1.

### 8.2 Automatic cadence

**FIXED DECISION.** After persisted opt-in is confirmed, the first automatic report becomes eligible after five minutes of normal app operation and sends no later than the next practical eligible foreground/runtime opportunity, subject to any still-active failed-chain cooldown. After a successful automatic send, normal daily eligibility remains 24 hours after that success.

A new `(Helios version, Helios build)` tuple or macOS build may permit one earlier `automatic_health` report, but never less than one hour after the last successful automatic report and never by bypassing the cooldown of a recently exhausted failed chain. An update/build-triggered automatic send never creates or sends `manual_compatibility` and never runs raw compatibility probes. Only the most recent pending reason is retained and sent; update/build changes do not queue multiple reports. Failed attempts do not advance `lastSuccessfulReport`.

This gate is entirely client-side. With no stable device identifier, the backend does not enforce one report per device/day. “Approximately daily” means opportunity-based and at-most bounded, not guaranteed delivery. There is no heartbeat, minute/hour engagement reporting, background daemon, or wake-for-diagnostics behavior.

### 8.3 Retry and resource bounds

**FIXED DECISION.** One automatic attempt chain consists of one base attempt and at most two retries: about 15 minutes and two hours after the initial failure, each with ephemeral ±20% jitter. Jitter is generated per delay and never persisted or uploaded. `lastAutomaticChainStartedAt` records the base-attempt time locally and is never uploaded or used as identity. Retries within that chain are exempt from the 24-hour base-chain rule.

A chain ends on success, opt-out, app termination, schema rejection, non-retryable 4xx response, or its second retry. If the chain fails or terminates without success, a new automatic base-attempt chain must not begin until at least 24 hours after the base attempt of the previous chain. Version/build transitions do not bypass this failed-chain cooldown. At the next eligible base window, Helios may build a new payload using only the single most recent pending reason.

Retry only connection failures, timeouts, HTTP 408, 429 (respect bounded `Retry-After` up to six hours), and 5xx. Do not retry other 4xx. Use an eight-second request timeout, one in-flight diagnostics request, no launch blocking, no background session, and utility/background priority. Report building and encoding should target under 50 ms CPU on supported hardware and the request body cap is 128 KiB.

Manual reports do not retry invisibly. The user may explicitly retry the same still-visible frozen bytes.

## 9. Exact payload viewer contract

**FIXED DECISION.** A single allowlist builder creates a typed report value from copied safe inputs. A single encoder converts it once to immutable `Data`. The preview displays the UTF-8 decoding of that exact `Data`; transport sends that same instance/byte sequence. It is forbidden to re-encode, append metadata, wrap the body, or use a second transport model after preview.

The viewer is available before opt-in and later in Settings. A pre-opt-in preview is local only. It explains optional omissions and rejected categories. For automatic/manual-health previews, refreshing may replace the frozen buffer. For manual compatibility, any regeneration requires a new explicit Send action. A payload older than 15 minutes must be regenerated and previewed again before manual send.

Transport headers (for example content type/length) are not part of the body and need not appear in JSON preview. There is no secondary body, query-string diagnostics, cookies, or tracking header.

## 10. Client identity policy

**FIXED DECISION.** There is no `user_id`, `device_id`, `installation_id`, `anonymous_id`, `analytics_id`, stable random token, or fingerprint. A server-generated UUID `report_id` identifies one accepted database record. It is never supplied by the client, never reused, never a device/client identifier, not returned to the Helios client in v0.1, and not persisted locally by Helios. Reports from one Mac are intentionally not reliably linkable. V0.1 exposes no report-specific lookup or deletion token to the user; any future change requires document, schema, and privacy review first.

Dashboard and public language must use **reports received**, not “users,” “devices,” “installs,” “active users,” or “unique users.” Model/build combinations are diagnostic dimensions, not identity keys, and must not be used to reconstruct a client profile.

## 11. HTTP transport contract

**FIXED DECISION.** Use one endpoint:

`POST https://snejda.cz/api/helios/diagnostics`

- HTTPS only; no downgrade or alternate cleartext endpoint.
- `Content-Type: application/json; charset=utf-8`; `Accept: application/json`.
- Maximum client and route body: 128 KiB before parsing (well below the platform ceiling).
- Client timeout: eight seconds.
- No cookies, credentials, referrer, advertising/analytics headers, persistent ID, or identity-bearing query parameters.
- One endpoint discriminated by `report_type`; every type has its own exact validator.
- Background/non-blocking app task, never helper traffic.
- Response is acknowledgement only. The client accepts only status plus a small fixed result (`accepted` or generic failure); it ignores unknown content and never executes configuration.
- All HTTP redirects are rejected and must not be followed automatically. The diagnostics client sends only to the exact configured HTTPS endpoint above. Cross-origin browser CORS support is unnecessary for the native client and should not be broadly enabled.
- DNS-only versus proxied Cloudflare must not alter schema, consent, application storage, or claims.

## 12. Vercel endpoint contract

**RECOMMENDATION.** Implement a short-lived Node.js Vercel Function/API route in the separate existing `snejda.cz` project because it needs straightforward PostgreSQL access. Neon is available as a Vercel Marketplace integration, and Vercel Functions impose a larger platform payload maximum; Helios still enforces its stricter 128 KiB product cap. Relevant current platform references: [Vercel Functions limits](https://vercel.com/docs/functions/limitations), [Vercel runtime logs](https://vercel.com/docs/logs/runtime), and [Neon on Vercel Marketplace](https://vercel.com/marketplace/neon).

**FIXED DECISION.** Future route behavior:

1. Allow `POST`; return 405 with `Allow: POST` otherwise.
2. Reject absent/unsupported content type with 415.
3. Enforce 128 KiB on raw bytes before JSON parsing; return 413.
4. Strictly parse one JSON object; reject duplicate/unknown keys, invalid encodings, excess depth/count, nulls, and unsupported schema versions with 400/422.
5. Select a report-type-specific compiled schema. Validate types, enums, patterns, ranges, conditional requirements, and cross-field invariants.
6. Run a defense-in-depth prohibited-key/name scanner recursively. This does not replace allowlisting.
7. Derive normalized columns only from the validated in-memory value.
8. Generate a fresh random UUID `report_id`, database-side `received_at`, and `expires_at = received_at + 30 days`.
9. Insert normalized fields and the validated semantic JSON value in one transaction.
10. Return a generic bounded acknowledgement such as `202 {"status":"accepted"}`. Do not return `report_id`, commands, configuration, identifiers, stack traces, or database details.

No request object, full body, full headers, forwarded/client IP, or database query parameters may be logged. Operational logs may contain only a server-generated request correlation token that is not stored with the report, route outcome enum, schema/report type, status code, duration bucket, and body-size bucket. Never log accepted or rejected payload excerpts. Vercel's plan-dependent runtime-log retention must be confirmed immediately before beta; current documentation describes plan-based retention rather than a universal value.

**RECOMMENDATION.** Apply Vercel Firewall rate limiting to the exact POST path, plus a coarse application-level global/region budget if needed. Infrastructure may temporarily use transport source information to enforce abuse controls, but the application must not receive/copy it into report storage or logs. Return 429 generically. Rate limiting protects availability and cost; it must not become a client identity system. [Vercel rate-limiting documentation](https://vercel.com/docs/vercel-firewall/vercel-waf/rate-limiting).

## 13. Database proposal

**RECOMMENDATION.** Use Neon PostgreSQL provisioned for the `snejda.cz` Vercel project, with a server-only pooled connection and separate least-privilege roles for ingestion, retention/aggregation, and dashboard reads. Do not create it from the Helios repository.

Store both selected normalized columns and `validated_payload JSONB`. This is worthwhile: normalized columns make constrained aggregates/indexes cheap, while the JSONB preserves the validated semantic JSON value for support and schema audits. JSONB does not preserve original whitespace, object-key order, textual number representation, or byte-encoding layout. V1 does not store a duplicate raw body/text column merely for formatting fidelity. Consistency is maintained by accepting only a typed validated object, deriving columns from that object in the same transaction, and adding check constraints. No caller supplies normalized values separately. Normalized `machine_model`, `fan_count`, and `battery_present` columns are nullable because an accepted JSON payload may omit those fields; this database nullability does not authorize JSON `null`.

Conceptual table:

```sql
diagnostic_reports (
  report_id uuid primary key,              -- server generated, per report only
  received_at timestamptz not null,         -- server generated
  expires_at timestamptz not null,
  schema_version smallint not null,
  report_type text not null,
  helios_version text not null,
  helios_build text not null,
  macos_version text not null,
  macos_build text not null,
  machine_model text,
  architecture text not null,
  memory_bucket text not null,
  fan_count smallint,
  battery_present boolean,
  helper_status jsonb not null,
  provider_statuses jsonb not null,
  failure_counts jsonb not null,
  runtime_summary jsonb not null,
  stability jsonb not null,
  validated_payload jsonb not null
)
```

For `manual_compatibility`, raw/classification content remains inside the validated JSONB in v1; only add normalized compatibility columns after demonstrated dashboard need and a schema/privacy update. Index `received_at`, `expires_at`, `report_type`, and carefully selected single diagnostic dimensions. Avoid a broad composite index that makes rare combinations convenient to fingerprint.

**FIXED DECISION.** There are no columns for IP/forwarded IP, request headers, user/device/installation identity, email, hostname, serial, cookies, user agent, referrer, geolocation, consent history, or donation identity. Database statement/error logs must not capture payload values.

## 14. Retention

**FIXED DECISION.** Raw validated reports expire after 30 days. A future scheduled server job deletes `diagnostic_reports WHERE expires_at <= now()` in bounded batches, records only aggregate deletion counts/status, and is tested for eventual completion and idempotency. Backups/provider recovery windows and their effect on deletion must be verified and disclosed before beta; this document does not promise deletion from unconfigured backups.

Application database source IP is never intentionally stored. Application logs minimize retention and never contain request bodies/headers. Actual Vercel, Cloudflare, firewall, log-drain, Neon, backup, and observability settings/retention must be inventoried before launch and reflected in `PRIVACY.md`.

Long-term statistics may contain report counts only, without persistent client IDs. **RECOMMENDATION:** aggregate by UTC day and a single approved dimension, suppress or merge cells with fewer than five reports, avoid cross-dimensional rare combinations, and delete source report IDs after aggregation. Aggregates are non-identifying only after review; they never imply unique users or devices.

## 15. Owner dashboard

**FIXED DECISION.** `https://snejda.cz/helios/admin` is private, owner-only infrastructure with server-side authentication and authorization on every page load, data query, route handler, and server action. A hidden URL, client-side redirect, JavaScript-embedded credential, or committed secret is not access control. Responses should use `Cache-Control: private, no-store`; dashboard pages and report routes must not be indexed.

**RECOMMENDATION.** For a single owner, use a maintained Vercel-compatible authentication provider (preferred initial choice: Clerk) with one exact allowlisted owner account, MFA/passkey enabled, short sessions, and server-side authorization. Store secret keys only in Vercel environment configuration. The public ingestion endpoint remains unauthenticated and isolated from admin APIs. If the existing site already has a supported auth system, reuse it only after equivalent server-side/MFA review. Clerk's current guidance requires protecting server routes, not merely hiding UI: [Clerk server-side protection](https://clerk.com/docs/guides/secure/protect-content).

Dashboard contents:

- reports received today, 7 days, and 30 days;
- report-type and Helios version/build distribution;
- macOS version/build, architecture and RAM-bucket distributions, plus Mac-model, fan-count and battery-present distributions computed only from reports where those fields exist; each optional dimension may separately show a **Not reported** count without inferring a value;
- provider availability/failure rates and failure categories;
- helper registration/connection/protocol categories;
- telemetry compatibility and diagnostics-subsystem failures;
- unsupported/new machine identifiers and unclean-session report rate;
- recent reports with `report_id`, received time and safe normalized columns;
- validated payload for a selected report, clearly marked automatic/manual and rendered from the stored semantic JSON value without claiming byte identity with the original preview.

It never shows or estimates unique users/devices, identity, IP, location, donation status, or cross-report “same machine” links. Viewing data does not add tracking fields or change report privacy. Admin access itself may be security-audited separately from diagnostic records.

The dashboard must not provide arbitrary interactive cross-dimensional filtering designed to reconstruct rare machine profiles. Default aggregate views should prefer approved single dimensions or privacy-reviewed aggregates. An owner may still inspect an individual validated report during its retention period for debugging. Aggregates must not be described as anonymous without the review required by section 14.

## 16. Buy Me a Coffee and support integration

**FIXED DECISION.** Buy Me a Coffee and diagnostics are unrelated systems. No donation UI appears in consent; functionality is never conditioned on support; donation identity/status is never uploaded or joined; and the native app embeds no Buy Me a Coffee SDK, JavaScript, or WebView.

Future native location: **Settings / About → Support Helios**, using a normal native external-link button that opens `https://buymeacoffee.com/snejda` in the default browser.

Suggested copy:

> **Support Helios**
>
> Helios is independently developed and free to use. If you find it useful and want to support continued development, you can buy me a coffee.

Future README section should use the same separation and external link. README is not changed by this architecture task.

## 17. Public contact

**FIXED DECISION.** Use `helios@snejda.cz` for v0.1 beta support, beta feedback, and diagnostics/privacy questions. Separate addresses may be proposed later if volume or legal process warrants it, but changing the published contact requires coordinated app/site/document updates.

## 18. Future privacy disclosure contract

Before any diagnostics-enabled beta ships, `docs/PRIVACY.md` and the public web policy must accurately disclose:

- Helios telemetry is primarily local;
- automatic diagnostics are OFF by default and require explicit opt-in;
- every collected category and every never-collected category;
- model, fan-count, and battery-presence fields are omitted rather than inferred or newly probed when not safely known;
- automatic cadence, local gate, bounded retries, and update/build exception;
- the distinct, one-shot manual compatibility flow and its optional raw hardware data;
- exact payload preview and absence of a hidden secondary body;
- no persistent device/client identifier, user account requirement, or advertising analytics;
- server-generated per-record `report_id` is not returned to or stored by Helios, and v0.1 exposes no report-specific lookup/deletion token;
- endpoint, Vercel hosting, Neon database, and Cloudflare's actual deployed role;
- transport IP may be visible to infrastructure, while the application/database do not intentionally store it;
- actual infrastructure/runtime/firewall/log-drain/database backup behavior and retention;
- 30-day raw-report target and the reviewed aggregate-retention policy;
- how disabling stops future automatic sends but does not automatically delete received reports;
- `helios@snejda.cz` and all actual third-party processors.

It must not overclaim anonymity or deletion capability. Legal roles, lawful basis, jurisdiction and data-subject handling are **OPEN IMPLEMENTATION DETAILS** for qualified privacy/legal review because this technical contract is not legal advice.

## 19. Future security disclosure contract

Future `SECURITY.md` must cover strict endpoint/schema validation, request/body limits, abuse controls, database least privilege, environment-only secrets, owner-dashboard server authorization/MFA, dependency and migration review, retention-job controls, and responsible reporting through `helios@snejda.cz` until a dedicated address exists.

It must state: diagnostics never pass through the privileged helper; there are no remote commands; responses are acknowledgement-only; transport failures are isolated; and no server or remote configuration can alter telemetry, fan control, helper lifecycle, safety gates, or SMC writes.

## 20. Threat and failure model

| Threat/failure | Required safeguards |
|---|---|
| 1. New `Codable` property silently uploads | Dedicated transport DTOs with explicit coding keys; generated strict JSON Schema; unknown-field rejection; schema snapshot and forbidden-field tests; document-first review |
| 2. Debug model contains username/path/process data | Never encode debug/domain models; copy only typed allowlist values; closed enums instead of descriptions; static forbidden-token audit and adversarial fixtures |
| 3. Server accepts undocumented fields | `additionalProperties: false` recursively; strict parser/validator; reject rather than strip; negative tests at every object level |
| 4. Viewer differs from actual body | Encode once; preview and send the same immutable `Data`; byte-equality interception test; invalidate approval on regeneration; treat database JSONB as semantic storage rather than original bytes |
| 5. Stable fingerprint emerges | No IDs/hashes; no `report_id` returned to the client; coarse buckets; minute timestamps; launch-scoped non-persistent failure counts; prohibit derived fingerprints and cross-report linking; review rare dimension combinations and aggregates |
| 6. Excess retry creates tracking-like traffic | One base attempt + two bounded retries, one in flight, persisted local chain-start anchor, 24-hour exhausted-chain cooldown, 24-hour success gate, bounded `Retry-After`, cancellation on opt-out |
| 7. Automatic request occurs before opt-in or manual preview sends early | Three-state automatic consent, missing means OFF; persisted-state readback gate for automatic requests; manual one-shot request only after exact preview and Send confirmation; zero-network preview tests |
| 8. Opt-out fails to stop schedule | Synchronous preference write; cancel scheduler/delay/request best-effort; generation token checked immediately before task/resume/send; race tests |
| 9. Vercel logs full body | No request/body/object logging; logger wrapper accepts only closed safe metadata; production log inspection/canary test; review platform settings |
| 10. IP metadata is persisted | No relevant DB fields; never read forwarding headers; log/header dump ban; database and log schema audit; verify Cloudflare/Vercel configuration |
| 11. Malicious clients spam endpoint | 128 KiB pre-parse cap; WAF rate limit; strict complexity limits; short execution timeout; generic 429/4xx; DB constraints and cost alarms |
| 12. Schema versions drift | Version-dispatched validators; shared fixtures/artifact; reject unsupported versions; client/server compatibility CI; staged deployment order |
| 13. Diagnostics resource cost is measurable | Reuse snapshots; no new automatic probes; low-priority bounded build/send; CPU/network benchmarks; one-in-flight and size limits |
| 14. Manual raw data becomes automatic | Separate type and builder; automatic type cannot represent `raw_hardware`; compile/module boundary; negative schema tests; explicit two-stage consent |
| 15. Dashboard leaks publicly | Server-side authentication + owner allowlist + MFA; authorization on data routes/actions; no-store; unauthenticated/alternate-path tests; secret scanning |
| 16. Server response influences fan control | Fixed acknowledgement decoder; no config/command fields; diagnostics module has no fan/helper dependency; fault-injection tests |
| 17. Production code logs payload locally | No payload interpolation in `OSLog`; safe closed error categories; source scan; release log capture with seeded canary values |
| 18. Provider/capability state reveals a disabled module | Builder classifies absent provider observations as `not_observed` and safely indeterminate capabilities as `unknown` without reading module preferences or probing; no inferred reason; identical-output tests across absence causes |
| 19. Future SMC key/type is normalized or discarded | Preserve exact four-character printable ASCII key/type metadata; reject controls and wrong lengths; case/space/punctuation fixtures; raw bytes remain unrepresentable |
| 20. Missing fan range or incomplete topology blocks or fabricates compatibility data | Closed `range_state`; optional independently read limits; exact count/index/class invariants for complete topology; honest `unknown` topology; fanless/single/dual/multi/incomplete fixtures; no inferred values |
| 21. Broad-hardware summary fields force fabrication or extra probes | Bounded product-class model grammar without a known-model allowlist; omit unknown model/fan/battery fields; never substitute zero/false or probe automatically; nullable normalized columns; omission and no-extra-probe fixtures |

Additional failures to test include clock rollback (use monotonic scheduling plus wall-clock persistence sanity checks), corrupt local preferences (fall back OFF), app termination during a send (never block termination), database partial failure (transactional insert), deletion-job failure (alert without extending claims), and auth-provider outage (fail dashboard closed without affecting ingestion).

## 21. Mandatory future test contract

No diagnostics implementation is beta-ready until automated tests and release evidence cover:

### Native client and consent

- clean first launch defaults OFF and causes zero diagnostics requests before explicit consent;
- consent OFF/ON each survive relaunch; decline is not nagged on later launches;
- onboarding reset does not reset diagnostics consent; erase-all returns it to undecided/OFF;
- opt-out immediately prevents/cancels future automatic work, including scheduling races;
- automatic success cadence never exceeds the section-8 rate; Helios/macOS transitions are bounded to one reason and one-hour floor;
- bounded retry/backoff, timeout, `Retry-After`, one-in-flight, termination, sleep/wake and clock-rollback behavior;
- failures do not affect startup, normal telemetry, helper registration/connection, cooling, lease, fan mode, or fan control;
- automatic and manual-health schema snapshots; manual-compatibility schema snapshot;
- model fixtures accept `MacBookAir10,1`, `MacBookPro17,1`, `Macmini9,1`, `iMac21,1`, `Mac16,1`, and a previously unseen but syntactically valid product-class identifier such as `MacFuture42,7`, all without a known-model allowlist; reject control characters, free-form text, wrong delimiters, and out-of-bound lengths;
- family fixtures cover each known `M1` through `M5` value, `future`, `unknown`, and omission of the OPTIONAL family field; unfamiliar family/model values do not invalidate an otherwise valid report;
- automatic-report fixtures cover safely known and omitted `machine_model`, safely known and omitted `fan_count`, safely true/false and omitted `battery_present`, and prove every omission triggers no additional probe, model-table lookup, or fabricated substitute;
- `not_observed` is emitted without a failure category for equivalent no-observation cases caused by startup timing, collection gating, or configuration, without the builder reading/transmitting module preferences;
- capability `unknown` requires no extra probe, conveys no cause, remains separate from provider `not_observed`, and produces equivalent output across configuration, startup-timing, and collection-gating cases without reading/transmitting module preferences;
- provider and total failure counters include only current-launch observed failures, reset on relaunch, are bucketed before encoding, and never persist cumulatively;
- `runtime.diagnostics_error_category` resets to `none`, reports only current-launch errors, and never derives from persisted Last report status or previous-launch history;
- `runtime.session_duration` measures only the current launch and is never reconstructed from persisted usage/session history;
- manual compatibility preserves exact case, spaces, and punctuation in four-character printable ASCII SMC keys/types, accepts reviewed future type codes, bounds optional `data_size`, rejects controls/raw bytes, and permits safely decoded temperatures with `unclassified` semantics;
- manual compatibility accepts `validated_hotspot` without translating it to a physical component/cluster and preserves its exact-profile provenance meaning;
- fan-range fixtures cover `available`, one-sided `partial`, `unavailable`, and `read_failed`; missing limits remain omitted and never block report construction;
- topology fixtures prove complete fanless requires `fan_count: 0`, complete single/dual/multi topologies require matching `fan_count`, and honestly incomplete `unknown` topology may omit `fan_count` or include it only from an independently safe count observation; reject duplicate indexes and every complete-topology count/index/class mismatch;
- recursive forbidden-field audit and proof of no stable identifier/fingerprint builder;
- preview bytes exactly equal intercepted HTTP body bytes;
- manual health works while automatic OFF and requires confirmation;
- manual health and manual compatibility require explicit initiation, exact frozen preview, and separate one-shot Send confirmation; regenerating invalidates approval and automatic consent remains unchanged;
- manual compatibility requires Create → Generate preview → explicit Send and works while automatic OFF; Generate Preview causes exactly zero network requests;
- automatic reports cannot encode raw compatibility fields; manual raw collection never runs from automatic code;
- app/Helios-build and macOS-build automatic triggers always encode `automatic_health`, never `manual_compatibility`, and never invoke raw compatibility probes;
- an exhausted or terminated unsuccessful automatic chain cannot start another base attempt until 24 hours after the prior base attempt, including across relaunch and version/build transitions;
- body size, arrays, ranges, strings, finite numbers and stale-preview limits;
- server response cannot issue fan/helper/telemetry commands;
- production source/log scan proves payloads are not logged;
- a frozen baseline proves no `Sources/HeliosDaemon/*` or existing privileged contract changed.

### API/database/retention

- method/content-type/HTTPS policy, rejection without following of every redirect, exact endpoint enforcement, and safe generic errors;
- malformed JSON, duplicates, nulls, unknown fields, prohibited names, excess depth/count, bad enums/ranges, unsupported versions/types, and >128 KiB bodies are rejected before insertion;
- all accepted schema fixtures insert once with server-generated `report_id`, `received_at`, correct `expires_at`, normalized/JSONB semantic consistency, nullable normalized model/fan/battery columns for omitted JSON fields, and no `report_id` in the acknowledgement;
- IP, forwarded headers, cookies, user agent, referrer and geolocation are absent from schema, rows, application logs and query logs;
- application logs never contain valid/invalid bodies or headers;
- rate bounds and abuse behavior under concurrency;
- transaction rollback leaves no partial record;
- raw expiration job is idempotent, bounded and removes expired rows; aggregate tests prevent IDs and suppress small cells;
- ingestion DB role cannot read/administer beyond need; dashboard role cannot mutate reports; retention role is scoped;
- dashboard requires authentication and exact owner authorization on page/data/action paths, fails closed, emits no public cache, and never labels counts as unique users;
- deployment-level test confirms Cloudflare DNS-only and proxied modes do not change the application contract;
- clean production-like log/config inspection records actual processor and retention behavior.

### Release gates

Privacy copy, schema, preview, captured body, stored JSONB, normalized columns, dashboard rendering, and retention behavior must be compared end-to-end using the same fixtures. Preview versus captured HTTP body is compared byte-for-byte; database JSONB, normalized columns, and dashboard rendering are compared for validated semantic equality without claiming original formatting or byte preservation. Passing unit tests alone is insufficient. No public beta claim is allowed while infrastructure logging/retention, owner authentication, deletion scheduling, or exact-body validation is unverified.

## 22. Incremental implementation phases

“Codex Sol” levels below are task-complexity recommendations, not authorization to skip review. Every phase starts from a clean diff, keeps privileged files frozen, and ends with its checkpoint before the next begins.

| Phase | Likely files/components | Production risk | Privacy risk | Codex Sol | Required checkpoint |
|---|---|---:|---:|---|---|
| A. Shared diagnostics schema/models | new unprivileged app diagnostics DTOs; version-1 JSON Schema/fixtures | Medium | High | High | approve every field/enum and prove domain models are not encoded |
| B. Consent/preferences | dedicated diagnostics preferences/scheduler state using `UserDefaults`; migration tests | Medium | High | High | clean-launch OFF, automatic-chain anchor, relaunch and corrupt-state tests pass |
| C. Explicit whitelist builder | unprivileged snapshot mapper; launch-scoped bucket/error mappings | Medium | High | High | forbidden-field audit, preference-independent `not_observed`/`unknown` behavior, counter-reset tests and schema snapshots approved |
| D. Exact payload viewer | reusable native JSON viewer and frozen-byte container | Low | High | Medium | preview/body byte-equality test passes |
| E. Automatic diagnostics client | `URLSession` transport, cadence, cancellation, retry | High | High | High | timing/fault isolation and no-pre-consent network evidence |
| F. Onboarding integration | extend existing onboarding window with optional page | Medium | High | Medium | UX review confirms OFF, no dark pattern, no nagging |
| G. Settings integration | Privacy & Diagnostics route, status/manual controls | Medium | High | Medium | opt-out race and manual-while-OFF tests pass |
| H. Manual compatibility | bounded read-only builder, provenance classification, preview/send | High | High | High | exact allowlist, read-only proof and second-stage consent review |
| I. Vercel API route | separate `snejda.cz` route, schemas, safe logging/rate hooks | High | High | High | adversarial validation and production-like log inspection pass |
| J. Neon schema/retention | migrations, roles, insert transaction, aggregate/delete jobs | High | High | High | least privilege, consistency, expiry and backup review pass |
| K. Owner dashboard/auth | separate site admin pages/data routes, auth/MFA/owner allowlist | High | High | High | unauthenticated and wrong-account tests fail closed |
| L. BMC About/README | native external link and README copy only | Low | Low | Low | verify external browser and no diagnostics/SDK coupling |
| M. `PRIVACY.md` | repo and deployed public privacy text | Medium | High | High | processor/log/retention facts verified; legal/privacy review |
| N. `SECURITY.md` | endpoint/admin/helper boundaries and reporting | Medium | High | High | security review and disclosure accuracy check |
| O. `BETA_TESTING.md` | consent, network capture, compatibility and support procedure | Low | Medium | Medium | independent tester can reproduce all gates |
| P. Privacy/security regression audit | source/schema/log/dependency/config audit | High | High | High | no unresolved blocker; frozen helper diff verified |
| Q. Clean-machine external-beta validation | notarized candidate + deployed staging/production-like backend | High | High | High | end-to-end consent→preview→body→row→dashboard→expiry evidence and explicit GO/NO-GO |

Server phases I–K must occur in the actual `snejda.cz` repository. Changes across native and web repositories should be reviewed as separate commits/PRs with shared versioned fixtures, not as an opaque bulk implementation. Deployment order should make the server accept the version before a client can send it; removal order should stop clients before removing server support.

## 23. Unresolved implementation decisions

The following are not silently fixed by this document:

1. **OPEN IMPLEMENTATION DETAIL:** locate and inspect the actual `snejda.cz` repository, framework, deployment plan, Cloudflare proxy mode, Vercel plan, log drains/observability, and existing authentication before server work.
2. **OPEN IMPLEMENTATION DETAIL:** confirm Clerk versus an already-deployed equivalent owner-auth system. Whatever is chosen must meet section 15; this is separate from report submission.
3. **OPEN IMPLEMENTATION DETAIL:** choose the schema-validation library and strict duplicate-key parsing approach supported by the real web stack.
4. **OPEN IMPLEMENTATION DETAIL:** define the exact map from every current `TelemetryError` and helper error into closed categories; unexpected text maps to `other` and is never transmitted.
5. **OPEN IMPLEMENTATION DETAIL:** define and validate the unclean-session marker so force quit, crash, reboot and normal shutdown are not overstated. Full crash reports remain out of scope.
6. **OPEN IMPLEMENTATION DETAIL:** validate safe Apple Silicon family derivation. If ambiguous, omit the optional field or use `unknown`; never combine hidden identifiers.
7. **OPEN IMPLEMENTATION DETAIL:** choose the scheduled deletion mechanism supported by the site plan and verify backup/PITR deletion semantics before privacy copy is finalized.
8. **OPEN IMPLEMENTATION DETAIL:** tune WAF/global abuse thresholds from staging without writing IP or creating durable client tokens in application storage.
9. **OPEN IMPLEMENTATION DETAIL:** establish measured CPU/network budgets on supported hardware. The section-8 limits are acceptance targets pending comparable evidence.
10. **OPEN IMPLEMENTATION DETAIL:** have qualified privacy/legal review settle controller/processor roles, lawful basis, jurisdiction, and contact procedures. V0.1 exposes no report-specific lookup/deletion token, so report-specific deletion requests generally cannot be authenticated or located; the privacy disclosure must not imply otherwise.
11. **OPEN IMPLEMENTATION DETAIL:** determine whether long-term aggregates are necessary at all. Until small-cell and combination review passes, retain only expiring raw reports.

None of these open details permits expanding payload fields, identity, cadence, helper scope, remote control, retention, or disclosure claims.
