---
governs: specs/001-device-mirroring
supersedes: ~
status: Accepted
date: 2026-11-10
covers:
  - decision:001-device-mirroring:viewer-exposure
---

# ADR-0002: Viewer exposure is loopback-only

## Status
Accepted 2026-11-10 (owner decision during bootstrap). Implemented 2026-11-10 (security review
fixes), and extended with a per-session password after the review showed loopback alone doesn't
stop other local accounts or processes.

## Context
Each mirrored iPhone is served by `pymobiledevice3 developer core-device display serve-web` with
no authentication. Anyone who can reach the port can watch **and control** the iPhone. RUNBOOK §9.4
and constitution Principle IV require loopback only.

As built, the app passes only `--http-port` (`Sources/PMD3Bar/Device/MirrorSession.swift`). It
relies on serve-web's **default** `--bind`, which is loopback in the bundled version 11.50.3.
`scripts/check.py` verifies `--http-port` but doesn't assert the default bind address. A future
upstream default change would silently expose the iPhone on the network.

## Decision
- Viewers bind to `127.0.0.1` only. The WKWebView loads `http://127.0.0.1:<port>/`.
- The bind address is pinned explicitly with `--bind 127.0.0.1`, and `--bind` is added to the
  serve-web options checked by `check.py`, so an upstream change fails the update gate instead of
  reaching users (TASK-001).
- Every session also gets a random `--password` (HTTP Basic), handed to serve-web on stdin so it
  never appears in `ps`, which other accounts can read. The window answers the challenge only
  after `processListens(pid:port:)` confirms the port is held by the session's own process, so a
  program that grabbed the port first gets neither the password nor a page in the window.
- The window follows only `http://127.0.0.1:<port>`. Clicked web or mail links open in the browser;
  `file:`, apps and custom schemes never do.
- Exposing a viewer to other hosts requires HTTPS (`--https`) and a new ADR.

## Consequences
- Positive: the full device-control surface stays on this Mac.
- Negative: no remote viewing. The browser button only works on this Mac.

## Alternatives Considered
| Option | Rejected Because |
|--------|-----------------|
| Rely on the upstream default only (status quo) | A silent upstream change would expose the device; nothing in the update gate would notice |
| Bind to the LAN with `--https` | Needs authentication, which serve-web doesn't provide; no current requirement |
