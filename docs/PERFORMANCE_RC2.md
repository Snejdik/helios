# RC2 memory-recovery revision

RC1 materially reduced Recommended CPU and wakeups, but a real-Mac UI stress run exposed a separate presentation-memory issue. After two Full Monitor / Energy Inspector / dashboard / metric-popover cycles and 60 seconds with all UI closed, RSS rose from 75.20 MiB to 147.20 MiB. `vmmap` showed a 71.3 MiB physical footprint (147.9 MiB peak), with the growth dominated by `MALLOC_SMALL` rather than CoreAnimation/IOSurface alone.

RC2 keeps all RC1 collector/performance changes and changes only presentation teardown plus the diagnostic script:

- Window close now explicitly detaches the `NSHostingController` tree from the closing `NSWindow`, removes the responder/delegate links, replaces the content view with an empty AppKit view, and severs the `NSWindowController.window` reference.
- Full Monitor route state and Energy Inspector lightweight selection/range state remain outside the discarded hosting tree.
- Menu-bar popovers continue to discard their content controllers on close.
- The UI memory test is locale-independent and records both RSS and `vmmap` Physical footprint before/after the same two-cycle stress sequence.

No telemetry provider, collection cadence, persistent history format, helper/XPC/SMC path, battery policy, fan authorization, or safety behavior is changed by this revision.

> RC3 follow-up: the real-Mac RC2 test still retained +36.70 MiB physical footprint after UI close. RC3 therefore targets eager construction of collapsed diagnostic trees and unbounded full-resolution application-icon retention while preserving RC1 collector performance and RC2 window teardown.
