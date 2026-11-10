# Eval Plan: Device Discovery & Mirroring

Governing spec: `.specify/specs/001-device-mirroring/spec.md`

No AI is involved. This is a verification plan. It exists because mirroring lifecycle behavior is
only partly covered by automated tests.

## Metrics & Thresholds
| ID | Metric | Threshold | Command |
|----|--------|-----------|---------|
| M1 | PMD3BarCore unit checks | 100% pass, exit 0 | `make test` |
| M2 | Upstream contract (static) | exit 0 | `make check-static` |
| M3 | Device integration incl. serve-web | exit 0 | `make check` (iOS 27+ iPhone connected) |
| M4 | Manual scenarios S1–S6 | 6/6 pass | see below |

## Scenarios (manual, real iPhones)
| ID | Covers | Steps | Pass when |
|----|--------|-------|-----------|
| S1 | AC-007, NFR-001 | Start mirroring, then `lsof -nP -iTCP:<port> -sTCP:LISTEN` | Listener address is `127.0.0.1` only |
| S2 | AC-006, FR-021 | `python3 -m http.server 8080 --bind 127.0.0.1 &`, then ▶ | Viewer runs on 8081 |
| S3 | AC-008, FR-040/041 | Mirror, close the window, wait 10 s, `pgrep -f 'display serve-web'`. Repeat with Quit | No output both times |
| S4 | AC-009, FR-025 | Mirror over USB with Wi-Fi available, unplug the cable | Stream resumes. Log shows "restarting over Wi-Fi" |
| S5 | AC-010, FR-029 | Two iOS 27+ iPhones, open one window, then All in grid, close the grid | Windowed iPhone keeps mirroring, the other stops |
| S6 | FR-003, NFR-003 | Let a Wi-Fi-only iPhone doze while another is on USB | Both listed. Dozing one shows orange "unreachable" with reason. List refresh not stalled > 6 s |

## Datasets
JSON fixtures inline in `Tests/PMD3BarCoreTests/main.swift` (`Device.parseHelperList`,
`isDeveloperImageMounted`, `ViewerLayout.viewportWidth`).

## Results
| Date | M1 | M2 | M3 | M4 | Notes |
|------|----|----|----|----|-------|
| — | — | — | — | — | not yet run under governance |
