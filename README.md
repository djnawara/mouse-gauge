# WLMouse Menu Bar

See your WLMouse battery and charging status at a glance in the macOS menu bar.

A small native Swift app for checking your mouse without opening a configuration tool. A solid mouse silhouette with a simple wheel gap fills from bottom to top with the battery level and turns blue while charging. Built and maintained by [David Nawara](https://github.com/djnawara).

![Solid mouse silhouette showing a full battery](docs/images/full-battery.png)

[Install](#install-from-source) · [Local signing](#local-signing-without-a-paid-developer-account) · [Troubleshooting](#permissions-and-troubleshooting) · [Roadmap](#roadmap)

## What works today

- Battery percentage and charging state in a compact menu bar icon and dropdown.
- Automatic refresh every five seconds, including while the menu is open.
- Immediate refresh requests when the menu opens or a WLMouse USB device connects or disconnects.
- Background queries that do not overlap, with the previous status visible until the next reading arrives.
- Device identification, query details, and manual refresh for troubleshooting.
- A dockless app installed in your user Applications folder.

The app reads HID reports directly through IOKit. It can query the wireless receiver and the mouse's direct USB connection when macOS exposes them. A charging change without a USB connection event, such as plugging into a wall charger, is picked up by polling.

**Current scope:** macOS and WLMouse battery reporting. Mouse settings, battery history, other platforms, and other brands are planned below.

## Install from source

You need:

- macOS 13 or newer and a compatible WLMouse mouse or receiver.
- Apple Command Line Tools with Swift 6 or newer. Install the tools with `xcode-select --install` if needed.
- [`just`](https://github.com/casey/just), which runs the build and install recipes.

Nix and direnv are optional. If you use them, the included flake supplies `just`; run `direnv allow` in the checkout. Alternatively, enter the development shell with `nix develop`.

```sh
git clone https://github.com/djnawara/wlmouse-menu-bar.git
cd wlmouse-menu-bar
```

For now, the project uses local builds and local signing. We recommend creating your own free signing certificate using the next section before installing. No paid Apple Developer membership is required for that setup.

With a certificate named `WLMouse Local Signing` in your Keychain:

```sh
WLMOUSE_SIGN_IDENTITY='WLMouse Local Signing' just install
just open
```

The app installs at `~/Applications/WLMouseMenuBar.app`. Approve **WLMouse Menu Bar** in **System Settings → Privacy & Security → Input Monitoring** when requested. Quit and reopen the app if macOS asks you to do so.

For a quick build without creating a certificate, use `just install` followed by `just open`. This defaults to ad hoc signing, which can require approving Input Monitoring again after the executable changes.

Installation quits running copies before replacing the app and relaunches it if it was running. When a changed ad hoc signing requirement is detected, installation also resets this app's old Input Monitoring decision and launches the new build to request access. Reinstalling the same build preserves its permission. You still approve access yourself in macOS.

## Local signing without a paid developer account

For now, our signing approach is a certificate you create and keep on your own Mac. This gives your local builds a consistent signing identity without paying for Developer ID. It does not provide Apple notarization or a publicly trusted download. Apple's [code signing guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) documents self-signed certificates for local development.

### Create your certificate once

1. Open **Keychain Access** (the certificate utility, rather than the Passwords app).
2. Choose **Keychain Access → Certificate Assistant → Create a Certificate**.
3. Name it **WLMouse Local Signing**.
4. Set **Identity Type** to **Self Signed Root** and **Certificate Type** to **Code Signing**.
5. Select **Let me override defaults** to choose a validity period, then complete the remaining certificate details and create it in your login keychain.

Check that your identity is available:

```sh
security find-identity -v -p codesigning
```

If your certificate is not listed as valid, open it in Keychain Access, expand **Trust**, set **Code Signing** to **Always Trust**, and save the change. Only apply this to the certificate you just created for your own builds. Check the command again; the certificate also needs its corresponding private key in your Keychain.

### Use the same certificate for updates

Run every install with the same identity:

```sh
WLMOUSE_SIGN_IDENTITY='WLMouse Local Signing' just install
```

Or set it for your terminal session, then use the usual commands:

```sh
export WLMOUSE_SIGN_IDENTITY='WLMouse Local Signing'
just install
just open
```

Reuse the existing certificate rather than creating a new one for each build. Signing with the same certificate, bundle identifier, and install location is intended to keep the identity consistent across updates; macOS may still require reapproval. Switching from ad hoc signing can require one final `just repair-permissions` and approval of the newly signed app.

Create your own certificate for your own builds; keep its private key out of this repository. The installer does not automatically reset permissions for certificate-signed builds. The recovery command below remains available if an approval becomes stale.

## Permissions and troubleshooting

Input Monitoring is required to read mouse-class HID reports. macOS grants it to an app identity, so a checked entry in Settings can become stale after a differently signed build replaces the app. This can leave both automatic and manual refresh unable to read the battery.

If the dropdown says **Status: Input Monitoring required**, or the app stops updating after an install despite an enabled permission entry:

```sh
just repair-permissions
```

This quits WLMouse Menu Bar, resets only its Input Monitoring decision using `tccutil reset ListenEvent local.wlmouse-menu-bar`, and relaunches the installed app to request access again. Approve it in Settings, then quit and reopen if requested. See Apple's [permission reset documentation](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos).

If the stale entry persists, remove **WLMouse Menu Bar** from Input Monitoring, then relaunch `~/Applications/WLMouseMenuBar.app` to create a fresh entry. Keep using this installed location during testing; copies launched from `.build` can have a different permission state.

For a receiver that remains undetected, reconnect it and check the diagnostics below. A command run from your terminal may have different permission from the installed app, so a successful terminal read does not prove the app is authorized. If devices remain missing after correcting permissions and reconnecting, restart macOS with the receiver connected and try again.

## Device compatibility

Tested with a **Beast X 8K** setup, including wireless battery reads through the `0xA883` receiver. Other devices below have known protocol mappings in the app but have not all been verified on hardware. Compatibility reports are welcome.

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

## Roadmap

These are planned directions, not features available in the current app. Hardware support depends on what each device's protocol exposes.

- [ ] **Show battery-relevant settings:** mouse polling/report rate (Hz), DPI, and other available settings such as performance modes and sleep timers. Also display the app's current battery refresh interval, separately from the mouse polling rate.
- [ ] **Graph battery history:** record battery readings and settings over time so users can compare drain across configurations and see charging sessions.
- [ ] **Estimate time per charge:** summarize observed runtime across charge cycles, distinguishing elapsed time from active-use time where that can be measured. Show how much data an estimate is based on.
- [ ] **Linux support.**
- [ ] **Windows support.**
- [ ] **Other popular gaming mice:** expand beyond WLMouse, with device-specific protocol adapters and a clear tested-device list.

## Development and diagnostics

| Command | Purpose |
| --- | --- |
| `just build` | Build the Swift executable. |
| `just app` | Build and sign `.build/WLMouseMenuBar.app`. |
| `just install` | Install the app, handling running copies and stale ad hoc permissions. |
| `just open` | Open the installed app. |
| `just repair-permissions` | Reset this app's Input Monitoring decision and relaunch it. |
| `just run` | Run the executable through SwiftPM. |
| `just once` | Print a single battery reading. |
| `just devices` | List visible WLMouse HID collections. |
| `just probe` | Print raw feature-report probe results. |
| `just clean` | Clean SwiftPM build outputs. |

`just launch` opens the build-folder app for development. Prefer `just install` and `just open` when testing Input Monitoring permissions. `WLMOUSE_SIGN_IDENTITY` applies to `just app`, `just install`, and `just launch`; SwiftPM diagnostic commands run the executable directly.

For compatibility issues, [open an issue](https://github.com/djnawara/wlmouse-menu-bar/issues) with your macOS version, mouse model, wired/wireless connection, and output from `just devices` and `just once`. Note any permission errors. Review diagnostic output before posting it.

## Protocol notes and credits

This implementation follows the reverse-engineered WLMouse protocol documented by:

- [wlmouse-cli](https://github.com/mee7ya/wlmouse-cli)
- [wlmouse-battery-tray](https://github.com/minerva32/wlmouse-battery-tray)
- [WLPower](https://github.com/snems/WLPower)

Known feature-report devices use VID `0x36A7`, a 65-byte feature report, command `0x83` at offset 6, and battery percentage at offset 8. Some macOS collections use a 64-byte payload-only shape; the app tries both layouts. Older Beast X devices use an interrupt-style request with command `0x1A` at offset 3.

## License

Copyright (C) 2026 David Nawara.

WLMouse Menu Bar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version (`GPL-3.0-or-later`).

This program is distributed without any warranty, including the implied warranties of merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for the full terms.
