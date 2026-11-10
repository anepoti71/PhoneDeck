# Spec: Device Discovery & Mirroring

> Bootstrapped from code on 2026-11-10 (`/at-bootstrap-from-code`). Requirements below describe
> **observed** behavior of the current app, cross-checked with README.md and RUNBOOK.md. Items the
> code does not justify are listed under Open Questions, not as requirements.

## User Stories
- As an iOS developer, I want every iPhone connected to my Mac (cable or Wi-Fi) to show up in the
  menu bar with its name, iOS version and link, so that I can tell which ones I can work with.
- As an iOS developer, I want the Developer Disk Image mounted for me when an iPhone connects, so
  that mirroring and developer tools work without a terminal.
- As an iOS developer, I want to see and control an iPhone's screen in a Mac window, so that I can
  use it without picking it up.
- As a QA tester, I want several iPhones mirrored at once, side by side, so that I can compare
  them during a test run.
- As a user, I want closing a window or quitting the app to leave nothing running on the Mac or
  the iPhone, so that the phone behaves normally afterwards.

## Requirements

### Discovery
- FR-001: The system SHALL list every iPhone that usbmuxd advertises, over USB and Wi-Fi, and
  refresh the list every 5 seconds.
- FR-002: The system SHALL show one entry per iPhone even when it is reachable over more than one
  link, labeled with its links ("USB", "Wi-Fi", "Wi-Fi + USB").
- FR-003: An iPhone that is advertised but does not answer SHALL stay listed as "unreachable"
  with the reason for each failing link. One unresponsive iPhone SHALL NOT hide the others.
- FR-004: The list SHALL be ordered with reachable iPhones first, iPhones on USB before those on
  Wi-Fi only, and unreachable iPhones last.
- FR-005: When the selected iPhone disappears, the selection SHALL move to the first reachable
  iPhone, or to the first listed one if none is reachable.
- FR-006: When notifications are on, the system SHALL notify a connection, and a disconnection only
  after the iPhone has been absent for at least 20 seconds. No notifications are sent for the
  iPhones found at launch.

### Developer Disk Image (DDI)
- FR-010: The system SHALL show the DDI state (checking, mounted, not mounted, mounting, failed with
  reason) for the selected iPhone.
- FR-011: With "Mount the DDI as soon as an iPhone connects" on (the default), the system SHALL try
  to mount the DDI once per connection on each reachable iPhone where it is not mounted. It SHALL
  try again only after a disconnection longer than 20 seconds.
- FR-012: The user SHALL be able to mount the DDI by hand at any time. A failed mount SHALL be
  reported with its reason and as a notification.

### Mirroring
- FR-020: For an iPhone on iOS 27 or later, the system SHALL offer to open a window that shows its
  live screen and lets the user control it with touch, keyboard and hardware buttons. For an
  earlier iOS it SHALL offer Tools only.
- FR-021: Each mirrored iPhone SHALL get its own local viewer port. The first starts at the
  configured "Starting port" (default 8080, minimum 1024), and later ones take the next free
  port. Several iPhones SHALL be mirrorable at the same time.
- FR-022: The viewer SHALL only be reachable from this Mac. The app SHALL request the loopback
  address explicitly (`--bind 127.0.0.1`) rather than rely on an upstream default.
- FR-023: If the viewer does not answer within 90 seconds of starting, mirroring SHALL stop with
  "The viewer is not responding" and a notification.
- FR-024: If mirroring ends unexpectedly while the iPhone is still reachable, the system SHALL
  restart it automatically once. A further failure SHALL be reported to the user.
- FR-025: If the USB cable is pulled while an iPhone is mirrored over USB and the iPhone is still
  reachable over Wi-Fi, the system SHALL restart mirroring over Wi-Fi.
- FR-026: An iPhone being mirrored SHALL stay in the list while it is briefly not visible.
- FR-027: The window SHALL default to "iPhone only": transparent around the device, sized to the
  device's proportions, keeping them on resize and when the iPhone rotates. Showing the controls or
  the Tools panel switches it to a regular window. The choice is remembered per iPhone.
- FR-028: ⌥⌘M SHALL show the selected iPhone's window, or close it if it is already in front. If
  the shortcut cannot be registered, Settings SHALL say so.
- FR-029: With at least two reachable iPhones on iOS 27 or later, "All in grid" SHALL show all of
  them side by side in one window. It starts mirroring where needed, and on close stops only the
  sessions it started that have no window of their own.
- FR-030: Launch arguments `--open <UDID>` and `--grid` SHALL open that iPhone's window, or the
  grid, at launch.
- FR-031: Launch argument `--test-notification` SHALL post a test notification listing the
  reachable iPhones (diagnostic for notification permission).

### Lifecycle
- FR-040: Closing an iPhone's window SHALL stop its mirroring (unless the grid is showing it), its
  active condition, and its simulated location.
- FR-041: Quitting the app, or the app receiving SIGINT/SIGTERM, SHALL stop every mirroring
  process and every tool it started.
- FR-042: Restarting or shutting down an iPhone from the menu SHALL ask for confirmation, and stop
  its mirroring first so it isn't reported as a failure.

## Non-Functional Requirements
- NFR-001 (security): Viewer servers SHALL bind to loopback only and SHALL require a secret that
  is new for each session and is never visible to other processes or accounts. The window SHALL
  only send it to a viewer verified to be the app's own. Anyone who can reach a viewer port and
  has the secret can see and control the iPhone.
- NFR-002 (security): No step SHALL require administrator rights or `sudo`.
- NFR-003 (reliability): A single unresponsive iPhone SHALL delay the device list by no more than
  the per-device lockdown timeout of 6 s. The whole listing gives up after 30 s.
- NFR-004 (reliability): Stopping a long-running viewer process SHALL send SIGINT first and SIGTERM
  if it is still running 5 s later (3 s at quit).
- NFR-005 (diagnosability): Every viewer start, exit (with exit code) and automatic restart SHALL
  be written to `~/Library/Logs/PMD3Bar/pmd3bar.log`.
- NFR-006 (platform): macOS 14+ on Apple silicon; iOS 17+ with Developer Mode for discovery and
  the DDI; iOS 27+ for mirroring.

## Acceptance Criteria
- [ ] AC-001: The same iPhone seen over USB and Wi-Fi appears once, labeled "Wi-Fi + USB".
  Covered by `make test`, suite `Device.parseHelperList`.
- [ ] AC-002: Given one reachable and one timing-out iPhone, both are listed, the reachable one
  first, and the other shows "Wi-Fi: timeout". Covered by `make test`.
- [ ] AC-003: An iPhone on iOS 26.x shows 🔧 (Tools only); one on iOS 27.x shows ▶. Covered by
  `make test` (`supportsMirroring`) plus a manual check.
- [ ] AC-004: A personalized/cryptex or legacy DDI listing is detected as mounted, and an unmounted
  or invalid listing is not. Covered by `make test`, suite `isDeveloperImageMounted`.
- [ ] AC-005: With an iOS 27+ iPhone connected, `make check` passes the serve-web item: the viewer
  answers HTTP 200 on its port with the viewer canvas.
- [ ] AC-006: With 8080 taken by another process, the first mirrored iPhone uses 8081 (manual:
  `lsof -nP -iTCP:8081 -sTCP:LISTEN`).
- [ ] AC-007: While mirroring, `lsof -nP -iTCP:<port> -sTCP:LISTEN` shows the listener bound to
  `127.0.0.1` only.
- [ ] AC-008: Within 10 s of closing the window or quitting the app,
  `pgrep -f 'display serve-web'` returns nothing.
- [ ] AC-009: Unplugging the cable from an iPhone mirrored over USB that is on the same Wi-Fi
  restarts the stream over Wi-Fi without user action (log line "restarting over Wi-Fi").
- [ ] AC-010: "All in grid" is offered only with two or more reachable iOS 27+ iPhones. Closing the
  grid leaves running any iPhone that also has its own window.
- [ ] AC-011: Viewer width for a given height and screen ratio matches
  `ViewerLayout.viewportWidth` (`make test`, suite `ViewerLayout.viewportWidth`).

## Out of Scope
- Tools panel features (Apps, Files, Location, Conditions, Processes, Crashes, Log, network
  capture). Candidate specs of their own.
- `.ipa` checking, installing and re-signing (`--ipa-check`). Candidate spec 002.
- Bundled Python / pymobiledevice3 runtime management and the update notice. Candidate spec.
- Recording and screenshots inside the viewer.
- The viewer's own HTML/JS (owned upstream by pymobiledevice3, see constitution Principle I).
- Exposing the viewer to other hosts (would need authentication, HTTPS and an ADR).
- iPhones on iOS earlier than 17; Intel Macs.

## Domain Vocabulary

**Bounded Context**: Device Connectivity & Mirroring

| Term | Definition | Forbidden Synonyms |
|------|-----------|-------------------|
| Device | One physical iPhone, identified by its UDID, merged across all its links | Phone entry, Target |
| Connection | One usbmuxd link to a Device: "USB" or "Network" (shown as "Wi-Fi") | Transport, Channel |
| Reachable | At least one Connection answered lockdown | Online, Connected (when meaning reachable) |
| Developer Disk Image (DDI) | The developer image that must be mounted on the Device for developer services | Dev image, Mount |
| Mirror Session | One viewer process streaming one Device on one local port | Stream, Viewer process, Server |
| Viewer | The pymobiledevice3 web page showing the Device screen, hosted in a window | Player, Canvas |
| Mirror Window | The per-Device Mac window hosting the Viewer and the Tools panel | Device window, Screen |
| iPhone only mode | Mirror Window state that shows just the device, transparent around the bezel | Bare mode, Device-only mode (in UI text) |
| Grid | The single window showing every mirrorable Device side by side | Dashboard, Wall |
| Starting port | First local port tried for Mirror Sessions | Base port, HTTP port (in UI text) |

**Disambiguation Notes**:
- Connection ≠ Reachable: a Device can have advertised Connections and still be unreachable when
  none answers.
- Mirror Session ≠ Mirror Window: a session can run without its own window (Grid), and a window can
  exist without a session (iOS < 27, Tools only).

> Agents must treat this vocabulary as a primary architectural constraint. Prefer declared terms over generic alternatives (Manager, Handler, Processor, DataObject). Naming consistency is more important than technical cleverness.

## AI-Nativeness Assessment

**AIN Target Level**: 1 (no AI)

**Agent-Callable Operations**: N/A

**Human-in-the-Loop Gates**: N/A (destructive device actions, restart and shut down, already
require user confirmation, FR-042)

**Feedback Channels**: App log `~/Library/Logs/PMD3Bar/pmd3bar.log`; user notifications.

**Evaluation Required**: NO (no AI). A verification plan exists at
`.specify/evals/001-device-mirroring/eval-plan.md` because mirroring behavior is only partly
covered by automated tests.

> The bootstrap assessor flagged "agentic" behavior with medium confidence. That was a false
> positive: the keyword matched the word "prompt" in a notification-permission comment
> (`Sources/PMD3Bar/App/Integrations.swift:19`). The app contains no LLM or agent code.

## Open Questions
- ~~OQ-1~~ Resolved 2026-11-10: pin `--bind 127.0.0.1` explicitly (FR-022, ADR-0002, TASK-001).
  Implemented 2026-11-10, together with a per-session viewer password (see ADR-0002).
- OQ-2: Should the Starting port be validated against an upper bound? Today any value ≥ 1024 is
  accepted and later sessions increment without limit.
- ~~OQ-3~~ Resolved 2026-11-10: kept on purpose as a diagnostic (FR-031). It must be documented in
  RUNBOOK §2 (TASK-004).
- ~~OQ-4~~ Resolved 2026-11-10: one automatic restart is the intended policy (FR-024).

## Related ADRs
- ADR-0001: Wrap pymobiledevice3 via child processes, with pure logic in PMD3BarCore. Governs the
  module boundaries used to implement this spec.
- ADR-0002: Viewer exposure is loopback-only. Governs FR-022 and NFR-001.
- ADR-0003: One serve-web process and one port per mirrored iPhone. Governs FR-021, FR-023–FR-026
  and FR-029.
