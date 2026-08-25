## Technical preview

EDN is fast and usable, but this beta is ad-hoc signed and has not been notarized by Apple.

1. Download the ZIP and checksum below.
2. Verify the download with `shasum -a 256 -c EDN-<version>.zip.sha256`.
3. Move `EDN.app` to Applications and try to open it once.
4. Open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**, then confirm **Open**.
5. Follow EDN's prompt to grant Accessibility access.

This is [Apple's supported override for an unnotarized app](https://support.apple.com/guide/mac-help/apple-cant-check-app-for-malicious-software-mchleab3a043/mac). Do not disable Gatekeeper globally. Because beta builds use an ad-hoc signature, macOS may request Accessibility approval again after an update.

EDN workspaces are app-level and replay layouts you arrange yourself. They do not replace macOS Spaces or isolate individual windows of the same app.
