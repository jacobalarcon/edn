# EDN

EDN (pronounced “Eden”) is a fast, config-driven workspace manager for macOS. You choose which apps belong to a workspace, arrange their windows yourself, and EDN remembers and replays that layout when you return.

EDN uses app hiding and showing rather than Mission Control Spaces, so switching is immediate and animation-free. It does not calculate layouts, silently assign apps, or isolate individual windows of the same app.

## Install

The first public release will be available from [GitHub Releases](https://github.com/jacobalarcon/edn/releases). Download `EDN-<version>.zip`, move `EDN.app` to Applications, and open it. EDN will guide you to grant Accessibility access, which macOS requires for reading and positioning windows.

For a local development build:

```sh
scripts/build-app.sh
scripts/install-local.sh
```

The packaged CLI lives at `EDN.app/Contents/Helpers/edn`. A future Homebrew Cask will expose it automatically alongside the app.

## The model

- Workspace membership is explicit.
- Window positions are remembered automatically when you switch away.
- Config is plain JSON at `~/.config/edn/config.json`.
- Runtime layout state is kept separately at `~/.local/state/edn/state.json`.
- Workspaces are app-level. For complete isolation between two windows of the same app, use macOS Spaces.

## Build from source

EDN requires macOS 13 or newer and Swift 5.9 or newer. It has no third-party runtime dependencies.

```sh
swift test
scripts/build-app.sh
open dist/EDN.app
```

Set `EDN_UNIVERSAL=1` to build a universal Intel and Apple Silicon app. Set `EDN_CODE_SIGN_IDENTITY` to a Developer ID Application identity for distribution signing; local builds are ad-hoc signed.

## Release signing

GitHub’s release workflow expects these repository secrets:

- `APPLE_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`
- `RELEASE_KEYCHAIN_PASSWORD`

Pushing a `v*` tag builds a universal app, signs it with Developer ID, notarizes it with Apple, staples the ticket, and publishes the ZIP and SHA-256 checksum.

## License

MIT
