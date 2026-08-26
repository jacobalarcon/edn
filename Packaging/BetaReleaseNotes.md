## Technical preview

EDN is fast and usable, but this beta is ad-hoc signed and has not been notarized by Apple.

**[Download EDN for macOS (.dmg)](https://github.com/jacobalarcon/edn/releases/download/v{{VERSION}}/EDN-{{VERSION}}.dmg)**

Requires macOS 13 or newer. The download is universal for Apple Silicon and Intel Macs.

### What is ready

- Instant, animation-free switching between explicit app workspaces
- Automatic replay of the window layouts you arranged
- A native workspace editor and numbered menu-bar indicator
- Configurable app and window focus shortcuts
- Plain JSON configuration and a scriptable CLI with structured output

1. Open the downloaded disk image and drag EDN to Applications.
2. Open EDN from Applications. Dragging it installs the app but does not launch it.
3. Open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**, then confirm **Open**.
4. Follow EDN's prompt to grant Accessibility access.

This is [Apple's supported override for an unnotarized app](https://support.apple.com/guide/mac-help/apple-cant-check-app-for-malicious-software-mchleab3a043/mac). Do not disable Gatekeeper globally. Because beta builds use an ad-hoc signature, macOS may request Accessibility approval again after an update.

EDN workspaces are app-level and replay layouts you arrange yourself. They do not replace macOS Spaces or isolate individual windows of the same app.

Please report bugs through **EDN menu → Report an Issue…** and include your macOS and EDN versions. Do not attach private configuration or window titles unless they are relevant and safe to share.
