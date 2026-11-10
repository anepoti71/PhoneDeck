# PhoneDeck: runbook

Procedures to build, run, update and troubleshoot PhoneDeck.

PhoneDeck was called PMD3Bar: the name you see (app bundle, menus, notifications, docs) changed, while
the executable, the bundle ID `local.pmd3bar.PMD3Bar`, the Swift targets, the log and cache folders,
the saved settings and the notarytool profile keep the old name, so nothing has to be migrated.
`make install` removes `~/Applications/PMD3Bar.app` if it is still there. If "Launch at login" stops
starting the app, turn it off and on again in Settings.
For what the app does see the [README](README.md); for how it is built, [6.1](#61-how-its-built).

All commands run from the project folder:

```bash
cd path/to/PhoneDeck   # the cloned repository
```

- [1. First install](#1-first-install)
- [2. Running](#2-running)
- [3. Using the app](#3-using-the-app)
- [4. Updating pymobiledevice3](#4-updating-pymobiledevice3)
- [5. Updating the bundled Python](#5-updating-the-bundled-python)
- [6. Changing the code](#6-changing-the-code)
- [7. Logs and diagnostics](#7-logs-and-diagnostics)
- [8. Common problems](#8-common-problems)
- [9. Rules to follow](#9-rules-to-follow)
- [10. Changing the icon](#10-changing-the-icon)
- [11. Releasing to other Macs](#11-releasing-to-other-macs)

---

## 1. First install

**Prerequisites**
```bash
xcode-select -p        # must print a path; otherwise: xcode-select --install
swift --version        # Swift 6.x
uname -m               # arm64 (the bundled Python is Apple Silicon only)
```

**Prepare the iPhone (once)**
1. Connect it with the cable and tap **Trust** on the iPhone.
2. Enable Developer Mode: Settings ▸ Privacy & Security ▸ Developer Mode, then restart the
   iPhone and confirm.
3. To use it over Wi-Fi too: Finder ▸ iPhone ▸ "Show this iPhone when on Wi-Fi".

**Build and install**
```bash
make python     # downloads CPython 3.12 (sha256 verified) + pymobiledevice3 into build/python
make install    # builds, creates build/PhoneDeck.app and copies it to ~/Applications
```

`make python` downloads about 25 MB and installs about a hundred packages: you need it once,
and then only to update pymobiledevice3.

## 2. Running

| Command | What it does |
|---|---|
| `open ~/Applications/PhoneDeck.app` | Starts the installed app |
| `make run` | Rebuilds `build/PhoneDeck.app` and starts it (quits the running one first) |
| `make dev` | Runs from source with `swift run`, using the conda env's Python |
| `make check` | Checks the bundled pymobiledevice3 (see [4.3](#43-checking-after-the-update)) |
| `open build/PhoneDeck.app --args --open <UDID>` | Starts and immediately opens that iPhone's window |
| `build/PhoneDeck.app/Contents/MacOS/PMD3Bar --ipa-check <file.ipa> <UDID>` | Checks an `.ipa` for that iPhone without the UI (see [7](#7-logs-and-diagnostics)) |

To find the iPhones' UDIDs:
```bash
build/python/bin/python3 -I Resources/pmd3bar_helper.py list
```

**Launch at login**: menu ▸ Settings ▸ "Launch at login". Turn it on from the copy in
`~/Applications`: macOS records the path of the app you turn it on from.

**Quitting**: menu ▸ **Quit**. This also stops all mirroring, location and log processes.

## 3. Using the app

1. Click the iPhone icon in the menu bar.
2. Select an iPhone: the **Developer Disk Image** section refers to the selected iPhone.
   With "Mount the Developer Disk Image as soon as an iPhone connects" on (the default), the app
   mounts it by itself, once per connection. If that fails, press **Mount** after fixing the
   cause (usually Developer Mode turned off).
3. Press ▶ next to the iPhone (or ⌥⌘M for the selected iPhone): its window opens and mirroring
   starts. For iPhones on iOS earlier than 27 the button is 🔧 and opens Tools only.
4. The window shows **only the iPhone**, like the Simulator: it is transparent around the bezel,
   the title is hidden and the toolbar floats above the device; drag the bezel to move it. It is
   as wide as the iPhone needs: resizing keeps the proportions, and it adapts by itself when the
   iPhone rotates. With the controls or Tools open it goes back to a regular black window. In the
   window toolbar:
   - 🎚 **Show controls**: the viewer's zoom, rotation, bezel, Home/Siri/Swipe, clipboard and
     accessibility. The same button ("iPhone only") hides them again. The choice is remembered
     **per iPhone**;
   - ⏺ records the screen with the iPhone's audio (MP4: H.264 + AAC) to `~/Downloads`;
   - 🧭 opens the same viewer in the browser;
   - ■ stops mirroring;
   - ▯ opens the **Tools** panel: Apps, Files, Location, Developer (Conditions, Processes,
     Crashes, Log). The window widens to make room and narrows again when you close it.
     - **Conditions** (slow network, thermal state, GPU): one at a time; stays active while the
       window is open, then the iPhone goes back to normal. Needs the DDI.
     - **Processes**: one sample takes about 10 s; "Every 15 s" repeats it. Right-click to kill
       a process. Needs the DDI.
     - **Crashes**: double-click to read a report, right-click to download or delete it.
5. **Grid**: with at least two iPhones on iOS 27 or later, menu ▸ **All in grid** shows them side
   by side in a single window (it starts mirroring where needed and stops it on close, except for
   iPhones with their own window open). From the terminal: `open ~/Applications/PhoneDeck.app --args --grid`.
6. Closing the window stops that iPhone's mirroring (unless it's in the grid), the active
   condition and the simulated location.

Ports: the first iPhone uses the "Starting port" set in the menu (8080 unless you change it), the
others the next free ones.

**Settings** (menu ▸ Settings):

| Option | Default | Notes |
|---|---|---|
| Mount the DDI as soon as an iPhone connects | on | One attempt per connection; retries after a disconnection longer than 20 s |
| Notifications | on | macOS asks for permission the first time. Connections and disconnections are notified only after 20 s, so Wi-Fi standby doesn't trigger alerts every time |
| Shortcut ⌥⌘M | on | If another app already uses it, the app says so below the options |
| Launch at login | off | Only from the built app (`.app`), not with `make dev` |
| Starting port | 8080 | |

## 4. Updating pymobiledevice3

The app contains **its own copy** of pymobiledevice3, pinned in `scripts/fetch-python.sh`
(`PMD3_VERSION`, currently `11.50.3`). Published updates change nothing until you update, and
the `pymobiledevice` conda env is separate.

### 4.1 Checking for a new version
```bash
build/python/bin/python3 -I -m pip index versions pymobiledevice3 | head -1
```
What's new and release notes: https://github.com/doronz88/pymobiledevice3/releases

When a new version is out, the app flags it in the menu ("… available") and with a notification.
The **Copy command** button copies the update command, to run in the project folder.

### 4.2 Updating
```bash
PMD3_VERSION=11.51.0 make python     # replace with the version you want
make install
```

`make python` is **safe**:
1. it installs the new version into `build/python.new`;
2. it runs the static check (`check.py --no-device`). With `CHECK_DEVICE=1` it also runs the
   device check, if an iPhone is connected;
3. only if that passes, it moves the current version to `build/python.prev` and puts the new one in use.

If the check fails, `build/python` (and so the app) stays as it was. The rejected version stays
in `build/python.new` for investigation, and `FORCE=1` installs it anyway.

To try a fix that isn't released yet, use GitHub's `master`:
```bash
PMD3_SPEC="git+https://github.com/doronz88/pymobiledevice3.git@master" make python && make install
```

To make the new version permanent, update `PMD3_VERSION` in `scripts/fetch-python.sh`.

### 4.3 Checking after the update

```bash
make check                          # static checks + connected iPhone
make check-static                   # static checks only, no iPhone
make check CHECK_ARGS="--location"  # also simulated location (sets Rome and restores)
make check CHECK_ARGS="--udid <UDID>"   # on a specific iPhone
```

`scripts/check.py` checks:
- **without an iPhone**: commands and options used by the app, Python functions used by
  `pmd3bar_helper.py`, the viewer canvas, the "Ctrl+C" text expected from simulated location;
- **with an iPhone**: device list, DDI state, files, apps, system log, `serve-web` viewer
  (iOS 27 and later only; skipped on others).

It exits with code 0 if everything passes and, for each failed check, says what to fix. It picks
a reachable iPhone by itself, preferring those on iOS 27 or later and those on USB.

If a check fails, this table says where to look. The same tests can be done by hand from the app:

| # | Test | If it fails, look at… |
|---|---|---|
| 1 | The menu shows the iPhone with name and iOS version | `pmd3bar_helper.py list` (internal functions `usbmux.list_devices`, `create_using_usbmux`) |
| 2 | The DDI state is correct, **Mount** works | JSON from `mounter list`, option `mounter auto-mount --udid` |
| 3 | ▶ opens the window and the screen shows | `developer core-device display serve-web --http-port` |
| 4 | ⏺ records and saves a video | canvas id `c` in the viewer (`WebView.swift`, `bridgeJS`) |
| 5 | Tools ▸ Apps shows the list | `pmd3bar_helper.py apps` (`InstallationProxyService.get_apps`) |
| 6 | Tools ▸ Files shows the folders | `pmd3bar_helper.py afc-ls` (`AfcService.listdir/stat`) |
| 7 | Tools ▸ Location: "Active" within a few seconds | "Ctrl+C" text printed by `simulate-location set` (`DeviceTools.setLocation`) |
| 8 | Tools ▸ Developer ▸ Log shows lines | options `syslog live --format json --no-debug --no-info --process-name --match-insensitive` |
| 9 | Tools ▸ Apps ▸ launch an app | `developer core-device launch-application` |

Quick checks from the terminal:
```bash
PY="build/python/bin/python3 -I"
$PY -m pymobiledevice3 version
$PY Resources/pmd3bar_helper.py list
PYMOBILEDEVICE3_UDID=<UDID> $PY Resources/pmd3bar_helper.py afc-ls /
PYMOBILEDEVICE3_UDID=<UDID> $PY Resources/pmd3bar_helper.py apps | head -c 300
$PY -m pymobiledevice3 developer core-device display serve-web -h | grep -- --http-port
$PY -m pymobiledevice3 syslog live -h | grep -E -- '--format|--no-info|--process-name'
```

### 4.4 Rolling back to the previous version
```bash
make python-rollback && make install     # swaps build/python with build/python.prev
```
Running it again goes back to the new version. Alternatively: `PMD3_VERSION=11.50.3 make python && make install`.

## 5. Updating the bundled Python

Version, URL and sha256 are pinned in `scripts/fetch-python.sh` (`PBS_TAG`, `PBS_FILE`, `PBS_SHA256`).
To update them:

1. Pick a release from https://github.com/astral-sh/python-build-standalone/releases that is at
   least two weeks old.
2. Take the file `cpython-3.12.X+TAG-aarch64-apple-darwin-install_only.tar.gz` and its sha256:
   ```bash
   gh api repos/astral-sh/python-build-standalone/releases/tags/<TAG> \
     -q '.assets[] | select(.name|test("aarch64-apple-darwin-install_only.tar.gz$")) | .name+" "+.digest'
   ```
3. Update the three variables, then `make python && make install`.

If you change Python's minor version (for example from 3.12 to 3.13), also update the
`lib/python3.12` paths in `fetch-python.sh`.

## 6. Changing the code

| I want to… | Command |
|---|---|
| Try a Swift change quickly | `make dev` (uses the conda env, no `make python` needed) |
| Rebuild and start the app | `make run` |
| Only check that it compiles | `swift build -c release --arch arm64` |
| Run the logic tests | `make test` (no iPhone needed) |
| Save work to GitHub | `git push` (to the **private** `origin` repository) |
| Try `pmd3bar_helper.py` | `build/python/bin/python3 -I Resources/pmd3bar_helper.py list` |
| Clean up | `make clean` (keeps `build/python`) |

- UI-free logic (JSON parsing, versions, geometry, dates) lives in `Sources/PMD3BarCore` and is
  covered by `make test`. If you add logic of this kind, put it there with a test in
  `Tests/PMD3BarCoreTests/main.swift`. The tests are a small executable because XCTest and
  swift-testing only ship with Xcode; with Xcode installed they can be converted.
- SourceKit errors in the editor ("Cannot find type…") are false positives, because the editor
  doesn't see the Swift package. `swift build` is the source of truth.
- The web viewer (HTML/JS/CSS) lives inside pymobiledevice3: don't change it there, because the
  change is lost on the next update. Add features in the app (`WebView.swift`, `bridgeJS`) or
  propose them upstream.
- Long-running commands (mirroring, location, log) must always be stopped with SIGINT first, then,
  if still running after a few seconds, with SIGTERM. `syslog live` ignores SIGINT when it receives
  many lines. Two exceptions: `apps webdav --mount` hangs after unmounting on SIGINT, so the app
  unmounts the volume itself and then sends SIGTERM; `pmd3bar_helper.py pcap` stops on SIGTERM.

### 6.1 How it's built

```
PhoneDeck.app/Contents/
├── MacOS/PMD3Bar                SwiftUI interface (menu bar + windows)
└── Resources/
    ├── python/                  standalone CPython 3.12 + pymobiledevice3 (pinned version)
    └── pmd3bar_helper.py        Python functions the command line doesn't offer
```

```
┌────────────── PhoneDeck (Swift) ──────────────────────┐
│ Menu bar         Windows (WKWebView)                  │
│      │                 │ http://127.0.0.1:8080, 8081… │
└──────┼─────────────────┼──────────────────────────────┘
       │ child processes │
       ▼                 ▼
  python -m pymobiledevice3 …         ← one process per command,
  python pmd3bar_helper.py …            one serve-web per iPhone
       │
       ▼  usbmuxd (USB / Wi-Fi) + rootless iOS 17+ tunnel
    iPhone
```

- **The app doesn't import Python**: it runs `python -m pymobiledevice3 …` as a child process and
  reads the JSON output. The target iPhone is set by the `PYMOBILEDEVICE3_UDID` variable.
- **Mirroring**: each iPhone gets a `developer core-device display serve-web` process on its own
  port (from 8080 up). Each process has its own tunnel, so several iPhones can run in parallel.
  The window shows the pymobiledevice3 web viewer in a WKWebView.
- **`pmd3bar_helper.py`** does what the pymobiledevice3 command line can't:
  - lists iPhones even when a Wi-Fi connection doesn't answer (`usbmux list` fails entirely
    in that case);
  - lists folders with file type and size, in the Media folder or an app's container (falling back
    to its Documents folder when the whole container is refused);
  - reads device identity, storage and battery for the Info tab, keeping only the fields shown;
  - captures network traffic to a pcapng file, printing a summary twice a second instead of every
    packet;
  - lists apps with name, bundle ID and version only, without the full metadata, which can
    contain app keys;
  - fetches app icons over a single connection and caches them in `~/Library/Caches/PMD3Bar/icons`.
- **Which Python**, in order of priority:
  1. the one bundled in the app;
  2. the `PMD3_PYTHON` environment variable;
  3. `~/miniforge3/envs/pymobiledevice/bin/python` (handy with `make dev`).
- **Installing an `.ipa`**: it is first checked against the iPhone (signature, provisioning profile,
  UDID, bundle ID, certificate, entitlements). If the iPhone would refuse it, the window offers to
  resign it with a profile and Apple Development identity on this Mac, or lists what to create on
  the developer portal. Extensions need their own profiles and are left out with an explicit
  profile; capabilities the profile doesn't grant are dropped.
- **App files**: the whole container opens only for development-signed apps; for the others only
  the Documents folder, and only when the app shares its files. "Open in Finder" serves it over
  WebDAV on 127.0.0.1 and mounts it with `mount_webdav`.
- **App console**: launching with "Show its output" sets `NSUnbufferedIO=YES` and
  `OS_ACTIVITY_DT_MODE=YES`, as Xcode does, so `print` and `os_log`/`Logger` lines arrive live.

#### Sources

```
Sources/PMD3BarCore/        pure logic, no UI: tested by `make test`
  Models.swift              Device and parsing of the iPhone list, DDI and mirroring states
  RunResult.swift           command result and readable error message
  Versions.swift            version comparison (update notice)
  ViewerLayout.swift        viewer geometry and width of the "iPhone only" window
  Signing.swift             .ipa checks, provisioning profiles, resign plans, portal requirements
  DeviceInfo.swift          Info tab parsing, launch options, Files tab scope (Media or app container)
  LiveOutput.swift          console line buffer, capture totals, WebDAV mount output
  DeviceDates.swift         dates written by the helper (crash reports)
Sources/PMD3Bar/
  App/                      startup, menu bar menu, state, settings, notifications, menu bar icon
  Device/                   running pymobiledevice3, mirroring sessions, iPhone tools, .ipa resigning
  Viewer/WebView.swift      viewer WKWebView: layout, recording with audio, downloads
  Windows/                  per-iPhone window, grid, window sizing
  Tools/                    Tools panel, one tab per file
Tests/PMD3BarCoreTests/     tests for the pure logic (`make test`)
Resources/                  Info.plist, entitlements, pmd3bar_helper.py, icons
scripts/                    fetch-python.sh, build-app.sh, release.sh, check.py, make-icon.py
```

| File | Contents |
|---|---|
| `Resources/pmd3bar_helper.py` | Extra Python functions (robust device list, files, apps, icons, crashes, info, capture) |
| `scripts/fetch-python.sh` | Downloads CPython (sha256 verified), installs pymobiledevice3 into `build/python.new` and puts it in use only if it passes `check.py` |
| `scripts/build-app.sh` | Builds, creates `build/PhoneDeck.app`, build number, ad-hoc signature (Developer ID with `SIGN_IDENTITY`) |
| `scripts/release.sh` | Developer ID signature with hardened runtime, notarization, stapling, zip (`make release`) |
| `scripts/check.py` | Checks that pymobiledevice3 offers everything the app uses (`make check`) |
| `scripts/make-icon.py` | Cuts out the artwork and generates every icon size (`make icon`) |
| `Makefile` | `dev`, `python`, `python-rollback`, `app`, `release`, `run`, `install`, `test`, `check`, `check-static`, `icon`, `clean` |

#### Limits worth knowing when changing the code

- Recordings include audio only if the viewer is playing it (audio on).
- Simulated location and launching apps need the Developer Disk Image mounted.
- The iPhone's **real** location can't be read from the Mac: the developer services only allow
  setting or clearing the simulated one, and coordinates are redacted in `locationd` logs. That's
  why the map uses the Mac's location, which is close to the connected iPhone.
- The app depends on pymobiledevice3 commands and internal functions: update it following
  [4](#4-updating-pymobiledevice3).

## 7. Logs and diagnostics

- **App log**: `~/Library/Logs/PMD3Bar/pmd3bar.log` (menu ▸ **Log**). It contains every command
  run with its exit code and errors, the `serve-web` output and viewer errors (`[viewer] …`).
  ```bash
  tail -f ~/Library/Logs/PMD3Bar/pmd3bar.log
  ```
- **Viewer in the window**: Safari ▸ Develop ▸ *Mac name* ▸ PhoneDeck, to inspect the WKWebView.
- **Running processes**:
  ```bash
  pgrep -fl 'PMD3Bar|pymobiledevice3'
  ```
- **Who holds a port**: `lsof -nP -iTCP:8080 -sTCP:LISTEN`
- **Why an `.ipa` won't install**: the same check the app runs before installing, from the terminal.
  It prints the problems, the profiles on this Mac that could resign it (and why the others can't),
  and what to create on the developer portal. `--profile <file>` adds a profile that isn't
  installed; `--resign <out.ipa>` resigns it with the first plan.
  ```bash
  build/PhoneDeck.app/Contents/MacOS/PMD3Bar --ipa-check ~/Downloads/App.ipa <UDID>
  ```

## 8. Common problems

| Symptom | Cause | Fix |
|---|---|---|
| "No devices" | iPhone not paired, locked or on another network | Connect the cable and tap Trust. For Wi-Fi: unlock it and put it on the same network |
| iPhone in orange, "unreachable" | usbmuxd sees it over Wi-Fi but the iPhone doesn't answer (standby) | Unlock the iPhone; it refreshes by itself within 5 seconds |
| Mirroring: "The viewer is not responding" | DDI not mounted, or Developer Mode off | **Mount** the DDI, check Developer Mode, then Retry |
| Video freezes and restarts | The viewer restarts the stream by itself when no frames arrive (`no AU progress` in the log) | Normal now and then; if it happens often, use the cable |
| Mirroring stops when unplugging the cable | The USB tunnel drops | The app restarts it over Wi-Fi by itself; if not, press ▶ |
| Port 8081 instead of 8080 | 8080 is held by another process | `lsof -nP -iTCP:8080 -sTCP:LISTEN`; if it's a leftover `serve-web` see the next row |
| `serve-web` still running after quitting | The app was force-quit | `pkill -INT -f 'pymobiledevice3 developer core-device display serve-web'` |
| The iPhone stays at a simulated location | The app was force-quit with location active | Tools ▸ Location ▸ **Restore real**, or `PYMOBILEDEVICE3_UDID=<UDID> build/python/bin/python3 -I -m pymobiledevice3 developer dvt simulate-location clear` |
| `ModuleNotFoundError: No module named 'importlib'` in the log | The app was rebuilt while running | Already handled: `make run` and `make install` quit the app first. Restart it |
| Pip can't update (Permission denied) | Files created by root, after using `sudo` with pymobiledevice3 | `sudo rm -rf` the folder named in the error; then never use `sudo` again |
| "Python with pymobiledevice3 not found" | `build/python` is missing (with `make dev`, the conda env is missing) | `make python`, or set `PMD3_PYTHON=/path/to/python` |
| In iPhone-only mode the toolbar or panels come back, or the screen is small | A new viewer version changed ids or size calculation | `make check-static` flags it; update `layoutJS` in `WebView.swift` |
| Recording doesn't start | The viewer changed (canvas `c`), or the stream isn't active yet | Wait for the video; see item 4 of the [check](#43-checking-after-the-update) |
| "Screen streaming needs iOS 27.0 or later" | iPhone on iOS earlier than 27 | Normal: for that iPhone use Tools (🔧 button) |
| No notifications | Permission denied, or app started with `make dev` | System Settings ▸ Notifications ▸ PhoneDeck; use the built app |
| ⌥⌘M does nothing | Shortcut already used by another app, or turned off | Menu ▸ Settings: a red message shows if registration failed |
| Old or generic icon in Dock or Finder | macOS icon cache | `make install` re-registers the app with a new build number; if that's not enough: `killall Dock` |
| Generic icon only in **notifications** | Notification Center stores the icon **per bundle ID** the first time it sees the app, and never updates it (its database is protected: restarting processes or changing version doesn't clear it) | Only fix: change `CFBundleIdentifier` in `Resources/Info.plist`, migrating settings as `migrateLegacyDefaults()` in `PMD3BarApp.swift` does. Done once already (`local.experiments.PMD3Bar` → `local.pmd3bar.PMD3Bar`). To avoid it: change the icon *before* the first notification |
| The Location map doesn't show where the iPhone is | The iPhone's real location can't be read (see [6.1](#61-how-its-built)) | The map starts from the Mac ("This Mac") or from the last simulated location; the ◎ button centers on the Mac |
| "Mac location unavailable" | Location permission denied to PhoneDeck | System Settings ▸ Privacy & Security ▸ Location Services ▸ PhoneDeck |
| "The iPhone would refuse …" when installing an `.ipa` | Ad-hoc or unsigned app, iPhone not in the profile, expired profile, profile for another App ID, or capabilities the profile doesn't grant | Follow the window: **Resign and Install** with a profile on this Mac, or create what it lists on the developer portal and add the profile with **Choose Profile…** (it is copied to `~/Library/MobileDevice/Provisioning Profiles`) |
| Resigned app installs but App Groups, push or iCloud don't work | The profile used belongs to another App ID and doesn't grant them (the window warns) | Create an explicit App ID for the app's bundle ID with those capabilities and a profile for it |
| App icons missing | Empty cache or iPhone unreachable while loading | ↻ button in the Apps panel; cache in `~/Library/Caches/PMD3Bar/icons` (safe to delete) |

## 9. Rules to follow

1. **Never `sudo`** with pymobiledevice3 or pip: it creates root-owned files that then block
   updates. The only case that needs it is `remote tunneld`, which PhoneDeck doesn't use.
2. **Never modify** files inside `build/python` or `site-packages`: the next `make python`
   overwrites them. Changes go in the project sources or upstream.
3. **Pinned versions**: update pymobiledevice3 and Python deliberately, one at a time, and always
   run the [check](#43-checking-after-the-update) afterwards.
4. **Network exposure**: the viewers listen on `127.0.0.1` only. Anyone who can reach the port can
   see and **control** the iPhone: don't expose it on the network without a password and HTTPS.
5. **Private repository**: if you make it public, the GPL obligations apply (see below), and it's
   worth double-checking that the history contains no personal data.
6. **Distribution**: the app bundles GPL-3.0 software. If you give it to others, it must be
   distributed under the GPL together with the source code.

## 10. Changing the icon

> Notification Center keeps forever the first icon it sees for a bundle ID. Dock and Finder
> update with `make install`; for notifications see the dedicated row in
> [Common problems](#8-common-problems).

The app icon (Dock, Finder, Cmd-Tab, notifications, Spotlight) is generated from
`Resources/AppIcon-source.png`: a square image with the artwork on a plain dark background.

```bash
cp ~/Downloads/new-icon.png Resources/AppIcon-source.png
make icon       # generates Resources/AppIcon.icns (16…1024 px) and Resources/AppIcon.png
make install    # rebuilds the app and re-registers it, so macOS doesn't use the cached icon
```

`scripts/make-icon.py` removes the background starting from the corners: dark colors *inside*
the artwork are kept. The artwork is fitted to the macOS icon grid (824 px body on a 1024 canvas,
with a light shadow). If the background isn't uniform, make it transparent first.

The **menu bar** icon is different: it's a monochrome template drawn in code
(`Sources/PMD3Bar/App/MenuBarIcon.swift`), because macOS tints it by itself for light and dark
mode. It has three variants: normal, mirroring active (dot) and no iPhone (dimmed).

## 11. Releasing to other Macs

`make install` signs ad-hoc, which only this Mac trusts. For other Macs the app needs a Developer ID
signature with hardened runtime and Apple's notarization:

1. Once: a **Developer ID Application** certificate in the keychain (developer.apple.com ▸
   Certificates), and notarytool credentials with an app-specific password (appleid.apple.com ▸
   Sign-In and Security ▸ App-Specific Passwords):
   ```bash
   xcrun notarytool store-credentials PMD3Bar --apple-id <apple-id> --team-id <team-id>
   ```
2. Every release (bump `CFBundleShortVersionString` in `Resources/Info.plist` first):
   ```bash
   make release
   ```
   It builds with `SIGN_IDENTITY` set (`scripts/build-app.sh`), checks the signature, submits the
   zip to the notary service and waits, staples the ticket, and leaves
   `build/PhoneDeck-<version>.zip`, ready to send. If Apple rejects it, the script prints Apple's log.
3. `NOTARIZE=0 make release` signs without submitting, to test the hardened-runtime build.

Entitlements: `Resources/PMD3Bar.entitlements` (the app: Mac location for the map) and
`Resources/python.entitlements` (the bundled CPython: memory for ctypes/cffi callbacks). If a new
pymobiledevice3 dependency fails only in the release build, check this first.

Remember the GPL obligations in [9](#9-rules-to-follow) before giving the app to anyone.
