# WLMouse Menu Bar

Native macOS menu bar item for WLMouse battery status.

## What It Does

WLMouse Menu Bar reads battery status from WLMouse wireless mice and displays it in the macOS menu bar as a compact side-profile mouse battery symbol.

![Full battery menu bar icon](docs/images/full-battery.png)

The app talks directly to WLMouse HID devices through IOKit. It supports the wireless dongle path and the direct USB mouse path when macOS exposes both. For the Beast X 8K setup tested here, unplugged wireless mode reads battery through the `0xA883` receiver.

The menu bar dropdown shows:

- Current status
- Charging state, with a plug marker in the side-profile mouse symbol
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

If the menu bar app shows `auth` or `--` while `just once` works:

1. Quit WLMouse Menu Bar.
2. Open System Settings > Privacy & Security > Input Monitoring.
3. Remove old `WLMouse Menu Bar` entries, especially entries pointing at `.build` or previous install locations.
4. Add or enable `~/Applications/WLMouseMenuBar.app`.
5. Restart macOS with the wireless dongle connected.
6. Launch only `~/Applications/WLMouseMenuBar.app`.

The clean restart matters when macOS keeps stale TCC state for a previous development build. After the installed app is authorized from the stable location, it should enumerate the same receiver that `just once` sees from Terminal.

When the launched app lacks Input Monitoring permission it displays `auth` in the menu bar and requests access on startup. After granting access, quit and reopen the app.

## Recipes

```sh
just build
just app
just install
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
