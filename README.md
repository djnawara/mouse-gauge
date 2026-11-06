# WLMouse Menu Bar

Native macOS menu bar item for WLMouse battery status.

## What It Does

WLMouse Menu Bar reads battery status from WLMouse wireless mice and displays it in the macOS menu bar as a compact WLMouse mark with battery fill.

![WLMouse menu bar mark showing a full battery](docs/images/full-battery.png)

The app talks directly to WLMouse HID devices through IOKit. It supports the wireless dongle path and the direct USB mouse path when macOS exposes both. For the Beast X 8K setup tested here, unplugged wireless mode reads battery through the `0xA883` receiver.

Battery status refreshes automatically every five seconds, including while the dropdown is open. Opening the menu also requests an immediate refresh. Queries run in the background without overlapping, and the last status stays visible until the next reading arrives.

WLMouse USB device connections and disconnections also request an immediate refresh. If a connection changes during a query, another read runs as soon as it finishes. Charging changes that do not add or remove a USB device (such as charging from a wall charger while the receiver stays connected) are picked up by polling.

The menu bar dropdown shows:

- Current status
- Charging state, with the WLMouse mark turning blue while charging
- Matched device and PID
- Last query detail
- Manual refresh
- Quit

## Requirements

- macOS 13 or newer
- Apple Command Line Tools with Swift
- Nix with flakes
- direnv
- A supported WLMouse device or receiver

## Setup

Allow the repo's direnv environment once:

```sh
direnv allow
```

The direnv shell loads the flake, which provides `just` and sets SwiftPM cache paths inside `.build/`.

## Build

Build the Swift executable:

```sh
just build
```

Build a dockless `.app` bundle:

```sh
just app
```

The bundle is written to:

```text
.build/WLMouseMenuBar.app
```

## Launch

Launch the local `.build` app bundle:

```sh
just launch
```

Install it into your user Applications folder:

```sh
just install
```

Installation quits any running copy before replacing it and relaunches it afterward. When an updated ad hoc build changes the app's signing requirement, installation also resets only this app's Input Monitoring decision and launches the new build to request access. Reinstalling the same build preserves its existing permission. You still approve access in macOS; installation cannot grant it for you.

Then launch:

```sh
just open
```

The app is configured as an accessory app, so it appears in the menu bar without a Dock icon.

For development, you can also run directly with SwiftPM:

```sh
just run
```

## Diagnostics

For a one-shot HID read:

```sh
just once
```

To list WLMouse HID collections visible to macOS:

```sh
just devices
```

To print raw feature-report probe results for each visible collection:

```sh
just probe
```

If `just devices` shows no `0x36A7` collections after changing macOS privacy or device-access settings, restart macOS with the wireless dongle connected, then try again.

If `just once` reads the battery but the launched app does not, macOS is likely authorizing Terminal but not the app bundle. See the privacy notes below.

## macOS Privacy During Development

WLMouse Menu Bar needs Input Monitoring permission because it reads reports from mouse-class HID devices. macOS grants that permission to a specific app identity and location. During development, launching different copies of the app can confuse the permission state.

Use one stable launch location while testing:

```sh
just install
open ~/Applications/WLMouseMenuBar.app
```

If the app shows `Status: Input Monitoring required`, or its enabled permission entry has stopped working after an update, run:

```sh
just repair-permissions
```

This quits the app, clears its Input Monitoring decision with `tccutil reset ListenEvent local.wlmouse-menu-bar`, and relaunches the installed copy so macOS can request access again. Enable it in System Settings > Privacy & Security > Input Monitoring, then quit and reopen the app if macOS asks. Other apps' permissions are unaffected. If a stale entry persists, remove it manually and relaunch the installed app.

The default build uses ad hoc signing, whose signing requirement changes with the executable. To use a stable signing certificate from your Keychain instead:

```sh
WLMOUSE_SIGN_IDENTITY='Your code signing identity' just install
```

Use `security find-identity -v -p codesigning` to list available identities. Signing subsequent versions with the same certificate and bundle identifier can preserve permissions across updates. The installer does not automatically reset permissions for certificate-signed builds; `just repair-permissions` remains available if needed.

## Recipes

```sh
just build
just app
just install
just repair-permissions
just launch
just open
just run
just once
just devices
just probe
just clean
```

`just app` writes a dockless bundle at `.build/WLMouseMenuBar.app`.
`just install` copies it to `~/Applications/WLMouseMenuBar.app`.
`just launch` opens the local `.build` app bundle.
`just open` opens the installed app from `~/Applications`.

## Supported Devices

The implementation follows the reverse-engineered WLMouse protocol documented by:

- https://github.com/mee7ya/wlmouse-cli
- https://github.com/minerva32/wlmouse-battery-tray
- https://github.com/snems/WLPower

Known feature-report devices use VID `0x36A7`, a 65-byte feature report, command `0x83` at offset 6, and read battery at offset 8. Known older Beast X devices use the interrupt-style request with command `0x1A` at offset 3.

On macOS, some feature-report collections use a 64-byte payload-only report shape. The app tries both the hidapi-style 65-byte buffer and the macOS payload-only buffer.

Known PIDs:

| PID | Device | Protocol |
| --- | --- | --- |
| `0xA860` | WLMouse Receiver | Feature |
| `0xA866` | Miao 8K Receiver | Feature |
| `0xA867` | Miao | Feature |
| `0xA868` | Beast X Mini Pro | Feature |
| `0xA870` | Beast X Pro 8K Receiver | Feature |
| `0xA878` | Sword X 8K Receiver | Feature |
| `0xA880` | Beast MAX 8K Receiver | Feature |
| `0xA883` | Beast X 8K Receiver | Feature |
| `0xA884` | Beast X 8K | Feature |
| `0xA885` | Beast X Mini Receiver | Feature |
| `0xA887` | Beast X Receiver | Interrupt |
| `0xA888` | Beast X | Interrupt |

## License

Copyright (C) 2026 David Nawara.

WLMouse Menu Bar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version (`GPL-3.0-or-later`).

This program is distributed without any warranty, including the implied warranties of merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for the full terms.
