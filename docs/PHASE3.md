# Phase 3 — Privileged LaunchDaemon & XPC Handshake

The original Phase 3 record below is historical. The signed production LaunchDaemon was subsequently repaired and verified on this Mac; see **Live production repair — 2026-09-06** at the end. Phase 4's hardware-control validation gate remains closed.

## Scope and behavior

The app now registers and unregisters its embedded LaunchDaemon through `SMAppService.daemon(plistName:)`. The Helper Service card distinguishes Missing, Requires Approval, and Installed from the XPC connection state. Reinstall waits for asynchronous unregistration to finish before registering the replacement. Nothing installs automatically at app launch, and approval is performed by the user in System Settings.

The versioned shared interface exposes only handshake and ping, with reverse-direction challenge and disarm callbacks. A handshake exchanges protocol version, session UUID, and nonce. Each subsequent heartbeat carries the next sequence number and a new nonce; it succeeds only after the app answers the daemon's challenge. A successful response always reports control disarmed.

The app sends heartbeats every second and times out requests after two seconds. Callback work explicitly hops to the main actor; Foundation transport/error closures are explicitly `@Sendable` to avoid Swift 6 actor-isolation traps on XPC callback queues. Connection generations prevent late callbacks from an earlier session from updating a new one. Disconnect, sleep, rejection, and timeout invalidate the connection; a later eligible connection starts a fresh handshake. Protocol mismatch reports that helper reinstallation is required.

The daemon admits one non-root app session at a time. Its independent serial queue checks a five-second `ContinuousClock` diagnostic lease every 250 ms, with 25 ms scheduling leeway. Only completed bidirectional exchanges renew that diagnostic lease. Disconnect, invalid requests, or expiry disarm and close the session. An unanswered callback cannot block the timer. Transport cleanup has a bounded fallback after disarm.

This is a **diagnostic liveness lease**, not the future hardware-control lease. Control is always disarmed and no method can arm it. There are no daemon IOKit/SMC calls, fan writes, RPM overrides, or curve calculations. Returning physical fan state to System is a later implementation and hardware-validation gate; this phase never takes ownership of fans.

## Peer authentication and signing

Both endpoints install native Foundation code-signing requirements before activation. The listener filters callers before the delegate, and each connection checks incoming messages. Requirements specify an Apple signing anchor, the same Team ID as the local signed binary, the exact app/helper signing identifier, and absence of these exception entitlements:

- `com.apple.security.get-task-allow`
- `com.apple.security.cs.disable-library-validation`
- `com.apple.security.cs.allow-dyld-environment-variables`

Security validates the local signature against that policy and compiles each requirement before it is handed to Foundation. No authentication relies on a caller-supplied identifier, process name, PID lookup, or private audit-token API.

The shared entitlement file remains empty, with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. Team-signed builds therefore do not permit normal debugger attachment; launch directly or disable Debug executable in the Xcode scheme. Both targets retain the hardened-runtime build setting, although Xcode explicitly disables hardened runtime for the current ad-hoc signature.

At the original Phase 3 verification, no valid development signing identity was configured locally. Ad-hoc builds supported telemetry, build checks, and registration reporting, but the app reported Signing Required before connecting to the production Mach service. An ad-hoc daemon installs a deny-all requirement. There is no shipping unsigned fallback or command-line trust override. Unit checks inject an exact test-binary CDHash into an isolated anonymous listener; this does not change production trust defaults.

The installed macOS SDK headers are the API reference used for implementation. Apple documents [SMAppService registration](https://developer.apple.com/documentation/servicemanagement/smappservice), [per-connection signing requirements](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)), [listener signing requirements](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:)), and the [requirement language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html). `SMAppService.h` also documents notarization for apps containing LaunchDaemons and recommends `/Applications` for availability before user login. A development certificate alone is not proof that macOS will authorize registration or launch.

## Local registration observation

On 2026-09-06, the actual Debug app bundle was invoked as the ordinary logged-in user, outside the development-tool sandbox, with its explicit debug-only `--verify-service-lifecycle` option. This probe uses the native API, preserves an existing Installed/Requires Approval registration, and unregisters only an entry it creates. It does not approve the service or change System Settings.

Observed output:

```text
Before: Missing (3)
register(): SMAppServiceErrorDomain (1): The operation couldn’t be completed. Operation not permitted
After registration: Requires Approval (2)
unregister(): succeeded
Final: Missing (0)
```

Status 3 is `.notFound`; status 0 is `.notRegistered`. Registration can throw while still creating an approval-pending entry. Consequently the UI rereads status after errors and presents approval guidance instead of assuming nothing happened. The probe removed its pending entry successfully. No approved, authenticated root-daemon session was established in this environment.

To repeat the bounded lifecycle check from the repository after a Debug build:

```sh
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --verify-service-lifecycle
```

For normal use, launch Helios, scroll to Helper Service, and select Install Helper. Use Open System Settings if approval is pending. Signing Required requires configuring the Personal Team identity and rebuilding both binaries; it is separate from OS approval. Use Reinstall after replacing an already registered helper. Uninstall unregisters the service through SMAppService; the executable remains embedded in the app bundle until the app is removed.

## Verification

- Debug and Release builds succeeded for both targets on the M4/Tahoe host, using the installed macOS 26.5 SDK, arm64, Swift 6, and the macOS 13 deployment floor. Both app bundles and embedded helpers passed strict ad-hoc signature verification; inspected Debug entitlements were empty. Xcode emitted simulator-service environment diagnostics and its usual skipped AppIntents-metadata warning, with no Swift compiler warnings or errors.
- Native tests cover exact lease boundaries, late and replayed heartbeats, disconnect disarm, one-shot handshake, and the invariant that heartbeat traffic cannot arm control.
- Real anonymous NSXPC checks exercise the production session/delegate, typed replies, reverse challenges, protocol mismatch, incorrect nonce, replay rejection, both directions of peer rejection, and expiry during an unanswered callback. The app client's own heartbeat loop, disconnect/reconnect, additional-client rejection, daemon shutdown, and error handlers also run against that listener.
- Registration fixtures cover pending approval, Installed versus Signing Required, async uninstall/reinstall ordering, concurrent action suppression, and failure reporting without losing actual service state.
- Existing telemetry and fixed 80-point presentation checks pass. Native fixtures include Missing, Requires Approval, and Installed/Signing Required in light and dark appearances under `.build/Presentation`; the 380-point popover remains scrollable.
- All scripts compile in Swift 6 mode with complete strict concurrency and warnings treated as errors. Generated logs, checks, and renders stay under ignored `.build`; no new scratch files are placed in `/tmp`.

Build and check logs are in `.build/Verification/phase3-{debug,release,ipc,ipc-build,presentation,telemetry,registration}.log`.

Run `scripts/check-ipc.sh` from an ordinary user terminal. The tool sandbox blocks anonymous XPC even though compilation succeeds there; use `--build-only` to compile in that sandbox. Tests never register a daemon, run as root, or access hardware. These transport tests use an anonymous listener within one process and therefore do not establish privileged cross-process authentication. That remaining verification requires a real signing identity and administrator approval on this Mac. Other OS/hardware versions, sleep/wake integration, root-daemon restart behavior, and future physical fan restoration are not claimed as verified.

## Live production repair — 2026-09-06

Verified on the M4 MacBook Pro, macOS Tahoe 26.6.2 (25G83), using Apple Development signing and Personal Team `3J76KPDS9C`. The user had already approved the background item. All operations used the real system Mach service and SMAppService registration; System Settings approval was preserved.

### Root cause and evidence

There were two stale-installation failures and a reproducible replacement race:

1. **An old ad-hoc daemon remained alive after the on-disk binaries were signed.** PID `17959` started at 19:14:26 and logged `Secure IPC unavailable: Apple Development signing with a Team ID is required for secure helper communication.`, then installed the exact listener requirement **`never`**. The newly signed app subsequently reached this old process, which dropped its check-in messages with Security status `-67050`. This was the mismatching requirement; the new Team/identifier/entitlement expressions themselves were correct. Re-signing an executable does not update a running daemon's initialized listener policy.
2. **The replacement job had stale launch metadata.** At diagnosis, launchd referenced BTM UUID `179CBD10-D26E-4FAD-9A7B-7DA1835BB733`, while `sfltool dumpbtm` identified the currently signed helper as `5DB1B5C4-3CE7-41B0-9511-E74983947A03`. The signed helper's 19:35:55 crash report recorded UID 0, Team `3J76KPDS9C`, and `CODESIGNING / Launch Constraint Violation`; it was killed before Swift startup. Subsequent attempts reported `EX_CONFIG` (78), `spawn failed`, and `Could not find and/or execute program ... No such process`. There was no running listener. This is an OS launch-constraint rejection, distinct from an NSXPC requirement rejection. The OS did not expose its failing internal constraint expression; the stale UUID is directly observed, and its causal role is supported by the successful removal/re-registration repair.
3. **Immediate re-registration raced Background Task Management.** The first live single-step replacement test reproduced this at 19:48:05: asynchronous unregister returned error 0 at `.901`, app status became Missing, but BTM still reported `[enabled, allowed, notified]` at `.912`. Registration then returned `SMAppServiceErrorDomain (1)` and left the service Missing. Merely awaiting unregister and checking Missing once was insufficient on this host.

Apple's installed `SMAppService.h` specifies the asynchronous completion as the point after process termination at which re-registration is safe. The additional disposition race above was observed locally despite that completion. [Apple's SMAppService walkthrough](https://developer.apple.com/forums/thread/802443) explains bundle-relative service registration and approval; [Apple's launch-constraint documentation](https://developer.apple.com/documentation/security/applying-launch-environment-and-library-constraints) distinguishes launchd spawn constraints from embedded constraints. No constraints were removed or overridden to repair this installation.

### Fix

`NativeServiceRegistration` now obtains fresh SMAppService handles for operations and status reads. Reinstall disconnects the app client, awaits asynchronous unregister, and requires `.notRegistered` to remain stable for one second before registering the replacement. A five-second deadline fails the operation if removal does not settle. The existing busy guard covers the whole sequence. Success and failure both refresh actual registration/approval status. No retry overrides Requires Approval, and no global BTM reset, launchctl bootstrap, legacy plist installation, or approval bypass is used.

Debug-only `--unregister-helper` and `--reinstall-helper` invoke this same lifecycle without starting a throwaway XPC connection. `--verify-installed-xpc` uses the shipping `DaemonClient`, unchanged production trust provider, privileged system Mach connection, versioned handshake, and normal one-second heartbeat loop. It verifies a root peer in another process and at least ten successful replies over twelve seconds. It sends no calculation or fan-control request. Startup/handshake logs identify both process IDs; heartbeat success is logged at debug level for bounded live capture.

The actual stale service was unregistered, absence was confirmed in launchd, and the signed Debug bundle was re-registered. After the settling fix, the single-step Reinstall operation successfully replaced root daemon PID `20733` with PID `20739`, retaining the correct BTM UUID and returning Installed.

### Verified identities and installed result

| Item | Verified value |
| --- | --- |
| Registered app | `/Users/snejda/Documents/Codes/Helios/.build/DerivedData/Build/Products/Debug/Helios.app` |
| App signing identifier | `com.snejda.Helios` |
| Helper signing identifier / Mach service / launchd label | `com.snejda.Helios.Daemon` |
| Plist | `Contents/Library/LaunchDaemons/com.snejda.Helios.Daemon.plist` |
| BundleProgram | `Contents/Library/HelperTools/HeliosDaemon` |
| Both Team identifiers | `3J76KPDS9C` |
| Signing authority | `Apple Development: jakub.snejda@icloud.com (9249C7D2K3)` |
| Final daemon | PID `20739`, PPID `1`, UID `0` |
| Active daemon CDHash | `91928438255bbc886b1a645583319984b1486634` |
| BTM UUID | `5DB1B5C4-3CE7-41B0-9511-E74983947A03` |

A read-only Security API audit compared the running process's executable URL and CDHash to the embedded helper, and validated both running and static code against the production requirement. That PID-based audit is verification only; production peer authentication remains Foundation's signing requirement, never a PID lookup. Both directions still require `anchor apple generic`, matching certificate leaf `subject.OU`, the exact peer identifier, and absence of all three debugger/injection exception entitlements listed above. The plist, bundle IDs, Team, protocol v2 and requirement expressions match; no authentication source was weakened.

Final real probe (app PID `20762`, UID `501`):

```text
Helper status: Installed
PASS: Connected; handshake v2; authenticated daemon PID 20739, UID 0
PASS: heartbeat 1, elapsed 1.052290125 seconds
PASS: heartbeat 10, elapsed 10.488376040999999 seconds
PASS: heartbeat 11, elapsed 11.527517791000001 seconds
PASS: Installed, authenticated cross-process handshake and 11 heartbeats over 12 seconds
```

The normal menu-bar app was then relaunched as PID `20774`. Live logs show its v2 handshake at **19:51:17.822**, and matching client/daemon heartbeat completions through **heartbeat 34 at 19:51:53.210**, with the same root daemon. No code-signing/authentication rejection, launch-constraint failure, or heartbeat timeout occurred in this final captured window. The app was left running and connected. UI automation timed out, so the Installed value was verified through the same native SMAppService status used by the card, rather than a screenshot.

Debug and Release builds pass Swift 6 complete concurrency checking; registration/IPC regression checks, including delayed removal status, peer rejection and independent watchdog behavior, pass. Both configurations retain hardened runtime, empty entitlements and strict signature validity. No physical SMC writes were performed, and no production fan profile was enabled.

Evidence is retained in ignored `.build/Verification/production-xpc-*` files: `before.log`, `btm-before.log`, `reinstall-failure.log`, `before-reinstall.log`, `after-reinstall.log`, `running-signature-final.log`, `live-final.log`, `live-stream.log`, `live-summary.log`, `regression.log`, and the Debug/Release build logs. Crash evidence remains in `/Library/Logs/DiagnosticReports/HeliosDaemon-2026-09-06-193555.ips`.

### Repeat without changing trust

Quit the normal Helios app before the standalone probe (the daemon intentionally admits one client). From the repository, run:

```sh
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --verify-installed-xpc
```

For a rebuild of the registered bundle: quit Helios, run its `--unregister-helper` operation **before** overwriting the executables, build/sign, then run `--reinstall-helper` and launch the app. The Reinstall UI uses the same awaited removal/settling sequence. These are native in-app operations; development shell commands are not spawned by Helios. A twelve-second successful check establishes this installed IPC path, not future fan restoration, other OS versions, or notarized distribution.
