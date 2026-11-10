---
governs: specs/001-device-mirroring
supersedes: ~
status: Proposed
date: 2026-11-10
covers:
  - decision:001-device-mirroring:module-boundary
  - decision:001-device-mirroring:process-boundary
---

# ADR-0001: Wrap pymobiledevice3 via child processes, with pure logic in PMD3BarCore

## Status
Proposed. Inferred from code by `/at-bootstrap-from-code`. Confirm or amend.

## Context
PhoneDeck is a Swift app, and every iPhone capability comes from pymobiledevice3, a Python
project the team doesn't control and updates often. The app must survive upstream updates, stay
buildable with the Command Line Tools only, and still have testable logic even though the UI and
the device can't be tested automatically.

## Decision
- The app reaches pymobiledevice3 only by running `python -m pymobiledevice3 …` or
  `Resources/pmd3bar_helper.py` as child processes and parsing their JSON or text output. The
  target device is passed explicitly (`--udid` / `PYMOBILEDEVICE3_UDID`).
- `pmd3bar_helper.py` covers only what the CLI can't do (for example a device list that tolerates
  a single unresponsive Wi-Fi entry).
- `scripts/check.py` is the contract: it lists every command, option and internal function the app
  uses, and gates `make python`.
- Pure logic lives in `Sources/PMD3BarCore` (no UI frameworks) and is tested by `make test`.
  `PMD3Bar` depends on `PMD3BarCore`, never the reverse. Only `Sources/PMD3Bar/Device` spawns
  processes.

## Consequences
- Positive: an upstream crash can't take the app down. Updates can be rolled back. Logic is
  testable without a device or Xcode.
- Negative: there is process startup cost for every command, output parsing is brittle (mitigated
  by `check.py`), and the helper depends on upstream *internal* APIs.

## Alternatives Considered
| Option | Rejected Because |
|--------|-----------------|
| Embed Python (PythonKit / libpython) | Ties the app's address space to upstream; harder signing and notarization; crashes become app crashes |
| Reimplement the protocols in Swift | Very large surface (lockdown, tunnels, DDI, streaming) that upstream already maintains |
| Fork and patch pymobiledevice3 | Patches lost on every update (constitution Principle I) |
