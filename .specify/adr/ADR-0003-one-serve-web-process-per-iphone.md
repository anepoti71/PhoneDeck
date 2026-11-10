---
governs: specs/001-device-mirroring
supersedes: ~
status: Proposed
date: 2026-11-10
covers:
  - decision:001-device-mirroring:mirror-session-model
  - decision:001-device-mirroring:port-allocation
---

# ADR-0003: One serve-web process and one port per mirrored iPhone

## Status
Proposed. Inferred from code by `/at-bootstrap-from-code`. Confirm or amend.

## Context
Several iPhones must be mirrored at once (windows and the Grid). Each `serve-web` process opens its
own userspace tunnel to one device. Links change under a running stream (cable pulled, Wi-Fi
doze), and leftover processes from a force-quit can hold ports.

## Decision
- One `MirrorSession` per UDID owns one `serve-web` process on its own port.
- Ports: the first free port ≥ max(1024, Starting port), default 8080, skipping ports held by other
  sessions or by any other listener. Re-checked before each start.
- Readiness: poll `http://127.0.0.1:<port>/` once per second for up to 90 s, then fail with a
  notification.
- Recovery: one automatic restart after an unexpected exit if the device is still reachable. An
  explicit restart over Wi-Fi when USB disappears from a device mirrored over USB.
- Shutdown: SIGINT, then SIGTERM after 5 s (blocking 3 s at quit). The Grid stops only the
  sessions it started that have no window of their own.

## Consequences
- Positive: iPhones fail and recover independently. Mirroring works over both USB and Wi-Fi.
  Port conflicts resolve themselves.
- Negative: one Python process and one tunnel per iPhone (memory). Port numbers aren't stable
  across runs. A leftover process after a force-quit still needs manual cleanup (RUNBOOK §8). The
  single auto-restart was confirmed as the intended policy on 2026-11-10.

## Alternatives Considered
| Option | Rejected Because |
|--------|-----------------|
| One shared serve-web for all devices | serve-web serves one device per process |
| Fixed port per device (hash of UDID) | Collisions with other software; still needs fallback logic |
| Unlimited auto-restarts with backoff | Can loop forever on a device that keeps failing; one retry plus a user notification was chosen |
