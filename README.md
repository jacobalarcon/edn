# EDN

**Virtual workspaces for macOS that put your windows back where you left them.**

Choose the apps, arrange the windows, and give the workspace a shortcut. EDN brings it back instantly, with no Mission Control animation.

Workspaces are editable from the menu bar, plain JSON, or the `edn` CLI. EDN restores layouts; it does not calculate them for you.

**[Download EDN for macOS →](https://github.com/jacobalarcon/edn/releases/download/v0.1.0-beta.3/EDN-0.1.0-beta.3.dmg)** · macOS 13+ · Apple Silicon and Intel

**[Watch the 11-second demo →](docs/assets/demo.mp4)**

EDN is pronounced “Eden.”

## The flow

**1. Start empty.** Create a workspace without inheriting whatever happens to be open.

<img src="docs/assets/workspace-empty.jpg" alt="A new empty EDN workspace" width="100%">

**2. Choose the apps.** Membership is explicit and searchable.

<img src="docs/assets/app-picker.jpg" alt="EDN's application picker" width="100%">

**3. Give it a shortcut and arrange it.** The numbered menu-bar indicator shows where you are. Switch away and EDN remembers the layout exactly as you left it.

<img src="docs/assets/workspace-ready.jpg" alt="A populated EDN workspace with its shortcut and active numbered indicator" width="100%">

## Install

**[Download EDN for macOS (.dmg)](https://github.com/jacobalarcon/edn/releases/download/v0.1.0-beta.3/EDN-0.1.0-beta.3.dmg)**

Requires macOS 13 or newer. The download is universal for Apple Silicon and Intel Macs.

1. Open the downloaded disk image and drag EDN to Applications.
2. Open EDN from Applications. The copy is the installation; dragging it does not launch it automatically.
3. macOS will block this technical preview because it is not yet notarized. Open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**, then confirm **Open**.
4. Follow EDN's prompt to grant Accessibility access, which macOS requires to read and position windows.

Step 3 is [Apple's supported override](https://support.apple.com/guide/mac-help/apple-cant-check-app-for-malicious-software-mchleab3a043/mac); never disable Gatekeeper globally. Beta builds use an ad-hoc signature, so macOS may request Accessibility approval again after an update. Developer ID signing and notarization will remove this friction from stable releases.

[View all releases and checksums →](https://github.com/jacobalarcon/edn/releases)

For a local development build:

```sh
scripts/setup-local-signing.sh
scripts/build-app.sh
scripts/install-local.sh
```

The one-time local signing setup gives rebuilds a persistent macOS identity, so Accessibility approval survives development updates. It creates a self-signed certificate in your login keychain trusted only for code signing; it does not make the app suitable for public distribution.

The packaged CLI lives at `EDN.app/Contents/Helpers/edn`. A future Homebrew Cask will expose it automatically alongside the app.

## Command line and agents

Every finite command supports `--json`, so people, scripts, and agents use the same interface. Human-readable output remains the default.

```sh
edn list --json
edn windows --json
edn inspect coding --json
edn switch coding --json
edn focus next --json
edn focus next --window --json
```

`windows` reports the live desktop; `inspect` separates configured, remembered, and effective frames. Together they let an agent understand both what EDN was asked to do and what is actually on screen.

With `--json`, successful results go to standard output. Failures are emitted as a stable object on standard error and return a nonzero exit status:

```json
{"error":{"code":"workspace_not_found","message":"workspace not found: coding","command":"inspect"}}
```

`edn daemon --json` is the one long-running exception: it emits one compact JSON event per line as hotkeys are registered and switches occur.

## The model

- Workspace membership is explicit.
- Window positions are remembered automatically when you switch away.
- Focus shortcuts cycle only through running members and live windows of the active workspace.
- Config is plain JSON at `~/.config/edn/config.json`.
- Runtime layout state is kept separately at `~/.local/state/edn/state.json`.
- Workspaces are app-level. For complete isolation between two windows of the same app, use macOS Spaces.

## Build from source

[![CI](https://github.com/jacobalarcon/edn/actions/workflows/ci.yml/badge.svg)](https://github.com/jacobalarcon/edn/actions/workflows/ci.yml)

EDN requires macOS 13 or newer and Swift 5.9 or newer. It has no third-party runtime dependencies.

```sh
swift test
scripts/build-app.sh
open dist/EDN.app
```

Set `EDN_UNIVERSAL=1` to build a universal Intel and Apple Silicon app. Set `EDN_CODE_SIGN_IDENTITY` to a Developer ID Application identity for distribution signing; local builds are ad-hoc signed.

## Feedback and security

Found a bug or have a focused improvement? [Open an issue](https://github.com/jacobalarcon/edn/issues/new/choose). Please use [GitHub's private vulnerability reporting](https://github.com/jacobalarcon/edn/security/advisories/new) for security-sensitive reports.

Contributions are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) before proposing a new feature so EDN's deliberately small scope stays coherent.

## Acknowledgements

EDN is inspired by [FlashSpace](https://github.com/wojciech-kulik/FlashSpace)'s instant workspace switching and [AeroSpace](https://github.com/nikitabobko/AeroSpace)'s config-first macOS tooling. EDN is an independent implementation centered on replaying layouts that users arrange themselves.

## Release signing

GitHub’s release workflow expects these repository secrets:

- `APPLE_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`
- `RELEASE_KEYCHAIN_PASSWORD`

A beta tag builds and publishes an ad-hoc-signed universal app. A stable `v*` tag requires Developer ID credentials, notarizes the app and disk image with Apple, staples the tickets, and publishes the DMG, ZIP, and SHA-256 checksums.

## License

MIT
