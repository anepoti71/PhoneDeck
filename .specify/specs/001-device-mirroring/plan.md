# Plan: Device Discovery & Mirroring

> Bootstrapped from code on 2026-11-10. This describes the system **as built**. Tasks below are
> gaps found while bootstrapping, not a rebuild.

## Governing Spec
`.specify/specs/001-device-mirroring/spec.md`

## Technical Decisions
| Decision | Rationale | ADR |
|----------|-----------|-----|
| Talk to the iPhone only through `python -m pymobiledevice3 …` and `pmd3bar_helper.py` child processes | No Python embedding; upstream updates can't break the app's address space; `check.py` is the contract | ADR-0001 |
| Device list from `pmd3bar_helper.py list` instead of `usbmux list` | `usbmux list` aborts entirely when one Wi-Fi entry doesn't answer; the helper queries each entry with a 6 s timeout | ADR-0001 |
| Pure parsing and geometry in `PMD3BarCore` | Testable without UI or device via `make test` | ADR-0001 |
| One `serve-web` process per iPhone, each on its own port from the Starting port up | Each process opens its own tunnel, so iPhones run in parallel and fail independently | ADR-0003 |
| Viewer reachable on loopback only | Viewer gives full control of the iPhone | ADR-0002 |
| Poll every 5 s instead of usbmuxd events | Simple, and copes with Wi-Fi standby. The 20 s debounce hides doze flapping | — |
| SIGINT then SIGTERM after 5 s (3 s at quit) | serve-web shuts the stream down cleanly on SIGINT | constitution III |

## Vocabulary Decisions
| Domain Term | Code Construct | Module | Deviation Justification |
|-------------|---------------|--------|------------------------|
| Device | `Device` | `Sources/PMD3BarCore/Models.swift` | none — exact match |
| Connection | `Device.connections: Set<String>` ("USB"/"Network") | `PMD3BarCore` | String set rather than a type. Values come straight from usbmuxd |
| Reachable | `Device.reachable` | `PMD3BarCore` | none |
| Developer Disk Image | `MountState`, `isDeveloperImageMounted` | `PMD3BarCore` | "Mount" names the state of the DDI, not a separate concept |
| Mirror Session | `MirrorSession` | `Sources/PMD3Bar/Device/MirrorSession.swift` | none — exact match |
| Mirror Window | `MirrorWindows` (registry), `MirrorWindowView` | `Sources/PMD3Bar/Windows/` | none |
| iPhone only mode | `bare` | `Windows/` | none: the `deviceOnly` toggle was removed, the viewer is always laid out this way |
| Viewer | `ViewerWebView`, `ViewerController`, `ViewerLayout` | `Viewer/`, `PMD3BarCore` | none |
| Grid | `GridView`, `showGrid()` | `Windows/` | none |
| Starting port | `AppModel.httpPort` (defaults key `httpPort`) | `App/` | Key name kept for settings compatibility (constitution: identity stability) |

New terms introduced during planning:
- none

## Architecture
```
Menu bar (MenuView) ─┐                    ┌─ MirrorWindows ── MirrorWindowView ── ViewerWebView (WKWebView)
                     ├── AppModel ────────┤                      GridView ─────────┘        │ http://127.0.0.1:<port>
PMD3BarApp (args) ───┘   │ poll 5 s       └─ MirrorSession (per UDID) ── serve-web process ─┘
                         ▼
                 PMD3.runHelper(["list"]) ── pmd3bar_helper.py ── usbmuxd / lockdown ── iPhone
                 PMD3.run(["mounter", …])  ── pymobiledevice3 CLI ───────────────────────┘
                         │
                 PMD3BarCore: Device.parseHelperList, isDeveloperImageMounted, ViewerLayout
```

## Module Boundaries
| Module / Component | Responsibility | Depends On | Interface / Adapter |
|--------------------|----------------|------------|---------------------|
| `Sources/PMD3BarCore` | Pure parsing (device list, DDI state), states, viewer geometry | Foundation, CoreGraphics only | Public Swift types and functions |
| `Sources/PMD3Bar/Device` | Running pymobiledevice3 and the helper (`PMD3`), Mirror Session process lifecycle | `PMD3BarCore`, Foundation, Darwin | `PMD3.run`, `PMD3.runHelper`, `PMD3.makeProcess`; `MirrorSession` |
| `Sources/PMD3Bar/App` | App state (`AppModel`), polling, selection, DDI auto-mount, presence notifications, settings, menu UI, launch args | `PMD3BarCore`, `Device`, `Windows` | `AppModel` observed by SwiftUI |
| `Sources/PMD3Bar/Windows` | Per-Device windows, Grid, window sizing and activation policy | `PMD3BarCore`, `App` (model), `Viewer` | `MirrorWindows.shared` |
| `Sources/PMD3Bar/Viewer` | WKWebView hosting the Viewer, injected layout/bridge JS | `PMD3BarCore` (`ViewerLayout`), WebKit | `ViewerWebView`, `ViewerController` |
| `Resources/pmd3bar_helper.py` | Device listing tolerant of per-entry failure | pymobiledevice3 internals (`usbmux`, `create_using_usbmux`) | CLI: `list` → JSON on stdout |
| pymobiledevice3 (bundled, upstream) | usbmux, lockdown, DDI mount, `serve-web`, Viewer HTML/JS | — | CLI contract verified by `scripts/check.py` |

## Dependency Rules
- `PMD3BarCore` MUST NOT import SwiftUI, AppKit, WebKit or `PMD3Bar`. Direction is
  `PMD3Bar → PMD3BarCore` only (enforced by `Package.swift` target dependencies).
- Only `Sources/PMD3Bar/Device` may spawn pymobiledevice3 or helper processes. `App`, `Windows`
  and `Viewer` go through `PMD3` / `MirrorSession` / `DeviceTools`.
- No module imports Python or links libpython. pymobiledevice3 is reached only as a child process.
- Every pymobiledevice3 command, option or internal function used here MUST be listed in
  `scripts/check.py` (today: `serve-web --http-port`, `mounter list/auto-mount --udid`, helper
  `list` via `usbmux.list_devices` / `create_using_usbmux`).
- The Viewer's HTML/JS is not modified. Behavior is added via injected JS in `Viewer/WebView.swift`.

## Testability By Boundary
| Boundary | Test Type | Isolation Strategy |
|----------|-----------|--------------------|
| `PMD3BarCore` (parsing, DDI detection, layout) | Unit (`make test`) | JSON fixtures inline in `Tests/PMD3BarCoreTests/main.swift` |
| pymobiledevice3 contract | Contract (`make check-static`) | Inspects CLI help and Python symbols of the bundled runtime, no device |
| Helper `list`, DDI, serve-web | Integration (`make check`) | Real iPhone. Picks a reachable one, preferring iOS 27+ on USB |
| Mirror Session lifecycle, port choice, windows, Grid | Manual (eval-plan scenarios) | Real iPhones. **Gap**: no automated coverage (see TASK-002/003) |

## Harness Strategy
N/A — single LLM call sufficient. No agent loop, tool execution, or session state required.
(No LLM at all. The bootstrap "agentic" signal was a keyword false positive.)

## Observability Strategy
N/A — feature makes no LLM calls and produces no AI-driven output. Standard logging is sufficient.
(`~/Library/Logs/PMD3Bar/pmd3bar.log`, see NFR-005.)

## Tasks
- [x] TASK-001 (done 2026-11-10, security fixes): Pass `--bind 127.0.0.1` to serve-web in `MirrorSession.start` and add `--bind`
  to the serve-web options in `scripts/check.py` (ADR-0002). Add the failing check first.
- [ ] TASK-002: Extract port selection (`AppModel.session(for:)`: first free port ≥ max(1024,
  Starting port), skipping ports used by other sessions) into a pure `PMD3BarCore` function with a
  test.
- [ ] TASK-003: Extract the presence debounce (20 s absence before "disconnected", re-arming
  auto-mount) and the auto-restart decision (`MirrorSession.exited`) into pure, tested
  `PMD3BarCore` logic.
- [ ] TASK-004: Document the `--test-notification` launch argument in RUNBOOK §2 (kept as a
  diagnostic, FR-031).
- [x] TASK-005: Unify the "iPhone only mode" code names (`deviceOnly` / `bare`): `deviceOnly` removed with the "Show controls" mode.
- [ ] TASK-006: Translate the remaining Italian strings in `scripts/check.py` serve-web messages
  (lines ~349–379), the `make test` summary line ("controlli superati, … falliti") and the
  `AppModel` "Impostazioni" comment.

## Evaluation Strategy
| Dimension | Metric / Check | Threshold | Framework | Evidence |
|-----------|----------------|-----------|-----------|----------|
| Parsing & layout correctness | `make test` suites for device list, DDI, layout | 100% pass | custom Swift harness | `make test` output |
| Upstream contract | `make check-static` | exit 0 | `scripts/check.py` | command output |
| Device integration | `make check` on an iOS 27+ iPhone | exit 0, serve-web item passes | `scripts/check.py` | command output |
| Lifecycle & exposure | eval-plan scenarios S1–S6 | all pass | manual + shell checks | eval-plan results table |

Evaluation plan:
`.specify/evals/001-device-mirroring/eval-plan.md`

## Security
- No authentication on the Viewer. Exposure is bounded by loopback binding (ADR-0002).
- The device is selected explicitly per process (`--udid` / `PYMOBILEDEVICE3_UDID`).
- No `sudo`. DDI mount and serve-web use pymobiledevice3's userspace tunnel (no root).
- Launch argument `--open <UDID>` takes an arbitrary string and only uses it as a lookup key and
  window identifier.

## Risks
| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Upstream changes serve-web's default bind or flags | Low | TASK-001 pins `--bind`; `check.py` verifies `--http-port` and `--bind` |
| Upstream changes the helper's internal API (`usbmux`, `create_using_usbmux`) | Med | `check.py` static checks; rollback via `make python-rollback` |
| Leftover serve-web after a force-quit holds the port | Med | Next session skips busy ports. RUNBOOK §8 documents cleanup |
| Lifecycle regressions go unnoticed (no automated tests) | Med | TASK-002/003; eval-plan manual scenarios |

## ADRs Created During Planning
- ADR-0001: Wrap pymobiledevice3 via child processes, with pure logic in PMD3BarCore (Proposed)
- ADR-0002: Viewer exposure is loopback-only (Proposed)
- ADR-0003: One serve-web process and one port per mirrored iPhone (Proposed)
