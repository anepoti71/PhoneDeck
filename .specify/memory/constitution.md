<!--
Sync Impact Report
- Version change: template → 1.0.0 (initial ratification)
- Principles defined:
  I. Wrap pymobiledevice3, never fork it
  II. Pure logic in PMD3BarCore, tested
  III. Disciplined child processes
  IV. Local-only exposure, least privilege
  V. Pinned, verified, reversible dependencies
- Added sections: Platform & Distribution Constraints, Development Workflow & Quality Gates, Governance
- Removed sections: none
- Templates:
  ✅ .specify/templates/plan-template.md — "Constitution Check" gate is derived from this file; no edit needed
  ✅ .specify/templates/spec-template.md — no mandatory section added or removed
  ✅ .specify/templates/tasks-template.md — test tasks map to `make test`; no edit needed
  ✅ README.md / RUNBOOK.md — principles restate RUNBOOK §6 and §9; no conflict
- Deferred TODOs: none
-->

# PhoneDeck Constitution

PhoneDeck (code name PMD3Bar) is a macOS menu bar app that mirrors and controls iPhones by
driving a bundled copy of pymobiledevice3.

## Core Principles

### I. Wrap pymobiledevice3, never fork it

- The app MUST talk to the iPhone only by running `python -m pymobiledevice3 …` or
  `Resources/pmd3bar_helper.py` as child processes and reading their output. The Swift app MUST
  NOT import or embed Python.
- Files inside `build/python` or `site-packages`, including the pymobiledevice3 web viewer,
  MUST NOT be edited. Viewer behavior is added from the app (`WebView.swift`, `bridgeJS`,
  `layoutJS`) or proposed upstream.
- `pmd3bar_helper.py` MUST only cover what the pymobiledevice3 CLI cannot do, and MUST return
  only the fields the UI shows. App keys and full metadata are never passed through.

Rationale: every pymobiledevice3 update would overwrite local patches; one process boundary keeps
upgrades safe.

### II. Pure logic in PMD3BarCore, tested

- Logic that needs no UI (parsing, versions, geometry, dates, signing plans, output buffers)
  MUST live in `Sources/PMD3BarCore` with no SwiftUI/AppKit imports.
- Every new or changed PMD3BarCore behavior MUST have a test in `Tests/PMD3BarCoreTests`. The
  test MUST fail before the change and pass after.
- `make test` MUST pass before merge. `swift build` is the source of truth over editor
  diagnostics.

Rationale: the UI and the device can't be tested without hardware, so correctness has to be
concentrated where it can be tested.

### III. Disciplined child processes

- Long-running commands (mirroring, location, log, capture) MUST be stopped with SIGINT first and
  escalated to SIGTERM after a few seconds. Known exceptions (`apps webdav --mount`, `pcap`) MUST
  be documented in the RUNBOOK.
- Closing a window or quitting the app MUST stop every process, condition and simulated location
  it started.
- Every command run MUST be logged with its exit code to `~/Library/Logs/PMD3Bar/pmd3bar.log`.
- The target device MUST be selected via `PYMOBILEDEVICE3_UDID`. The app never acts on an
  implicit device.

Rationale: a leftover process can keep the iPhone at a simulated location or hold a viewer port
open.

### IV. Local-only exposure, least privilege

- Viewer and WebDAV servers MUST bind to `127.0.0.1` only. Exposing them on the network requires
  authentication, HTTPS and an ADR.
- Nothing MUST run with `sudo`. Features that would require root (for example `remote tunneld`)
  are out of scope unless an ADR says otherwise.
- Entitlements MUST stay minimal. Each one is justified in the RUNBOOK.
- An `.ipa` MUST be checked against the target iPhone before install. Re-signing MUST be explicit
  and MUST report which capabilities or extensions get dropped.

Rationale: anyone who can reach a viewer port can see and control the iPhone.

### V. Pinned, verified, reversible dependencies

- The pymobiledevice3 version and the CPython build (tag, file, sha256) MUST be pinned in
  `scripts/fetch-python.sh`.
- An update MUST pass `scripts/check.py`, which must stay current with every command, option and
  internal function the app uses, before it replaces `build/python`. The previous runtime MUST
  stay available to roll back (`build/python.prev`).
- Update one dependency at a time. A CPython release MUST be at least two weeks old.
- A new pymobiledevice3 command, option or internal function used by the app MUST be added to
  `scripts/check.py` in the same change.

Rationale: the app depends on an upstream it doesn't control. `check.py` is the contract.

## Platform & Distribution Constraints

- Targets: macOS 14+ on Apple silicon (arm64 only); iOS 17+ with Developer Mode; mirroring iOS 27+.
- Toolchain: Swift Package Manager with the Command Line Tools. Xcode MUST NOT be required.
- Identity stability: the executable name, bundle ID `local.pmd3bar.PMD3Bar`, log/cache paths and
  the defaults domain MUST NOT change without a migration (see `migrateLegacyDefaults()`) and an
  ADR.
- Licensing: the app bundles GPL-3.0-or-later software. Any distribution MUST be under the GPL
  with source. Releases outside this Mac MUST be Developer ID signed and notarized
  (`make release`).

## Development Workflow & Quality Gates

- Specs live in `.specify/specs/NNN-kebab-name/`. `spec.md` holds product intent, and `plan.md`
  holds implementation, module boundaries (`PMD3BarCore` ← `PMD3Bar`) and dependency rules.
- Gates before merge: `swift build -c release --arch arm64`, `make test`, and `make check-static`
  when pymobiledevice3 usage changed. `make check` with an iPhone is required for changes to
  device commands.
- User-visible behavior changes MUST update README.md. Procedures, limits and troubleshooting
  MUST update RUNBOOK.md.
- Consequential decisions (process model, exposure, identity, dependencies) are recorded as ADRs
  in `.specify/adr/`. Drift found by `/at-audit` is resolved by refining the spec or ratifying it
  with an ADR.

## Governance

- This constitution supersedes conflicting practice. RUNBOOK §9 is the operator-facing summary of
  Principles III–V and MUST stay consistent with them.
- Amendments: edit this file via `/speckit-constitution`, record the Sync Impact Report, and add
  an ADR when a principle is removed or redefined.
- Versioning: MAJOR when a principle is removed or redefined, MINOR when one is added or materially
  expanded, PATCH for clarifications.
- Compliance: every plan's Constitution Check and every `/at-audit` run verifies these principles.
  A violation must be justified in the plan's Complexity Tracking or by an ADR.

**Version**: 1.0.0 | **Ratified**: 2026-11-10 | **Last Amended**: 2026-11-10
