# PhoneDeck

<img src="Resources/AppIcon.png" width="128" alt="PhoneDeck icon">

Your iPhones, right in the Mac menu bar. See and control their screen, install apps, move files
and debug, over cable or Wi-Fi. No Xcode, no terminal, no admin password.

Built on [pymobiledevice3](https://github.com/doronz88/pymobiledevice3), which ships inside the app.

## What you can do

### See and use the iPhone

- Mirror the screen in a window, with sound, touch, keyboard and buttons. Several iPhones at once,
  or all of them side by side in a grid.
- Record the screen with audio, take screenshots.
- Show or hide the window with **⌥⌘M**.

### Apps and files

- Install an `.ipa` by dropping it on the window. If the iPhone would refuse it, PhoneDeck tells
  you why and can re-sign it for you.
- Launch, uninstall, and launch with custom arguments, watching the app's output live.
- Browse photos and app files, copy them back and forth, or open an app's files straight in Finder.

### Testing and debugging

- Fake the GPS location by picking a spot on a map.
- Simulate a slow network, a hot device or a slow GPU.
- Watch processes, crash reports and the system log.
- Record the iPhone's network traffic for Wireshark.

### The device

- Battery health, storage, serial number and other details.
- Restart or shut down the iPhone from the menu.
- Get notified when an iPhone connects, disconnects or finishes an install.

## Requirements

- A Mac with Apple silicon and macOS 14 or later.
- An iPhone with iOS 17 or later and **Developer Mode** on
  (Settings ▸ Privacy & Security ▸ Developer Mode). Screen mirroring needs iOS 27 or later.
- Connect the iPhone with a cable the first time; after that Wi-Fi works too.

## Install

You need the Xcode command line tools (`xcode-select --install`), not Xcode itself.

```bash
cd path/to/PhoneDeck
make python    # first time only: downloads the bundled Python (about 260 MB)
make install   # builds PhoneDeck and puts it in ~/Applications
open ~/Applications/PhoneDeck.app
```

Click the iPhone icon in the menu bar, then ▶ next to your iPhone.

For updates, troubleshooting and how the app is built, see the **[RUNBOOK](RUNBOOK.md)**.

## Good to know

- Over Wi-Fi the iPhone must be awake and on the same network as the Mac.
- PhoneDeck can't read the iPhone's real location, so the map starts from where your Mac is.
- Re-signing an `.ipa` covers the app itself, not its extensions.
- The app doesn't update itself. To share it with other Macs, see
  [Releasing to other Macs](RUNBOOK.md#11-releasing-to-other-macs).

## License

PhoneDeck bundles pymobiledevice3, which is licensed under GPL-3.0-or-later. If you give the app to
others, you must do so under the GPL and share the source code.
