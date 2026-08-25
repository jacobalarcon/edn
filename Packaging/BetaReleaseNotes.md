## Technical preview

EDN is fast and usable, but this beta is ad-hoc signed and has not been notarized by Apple.

1. Download and unzip EDN.
2. Move `EDN.app` to Applications and try to open it once.
3. Open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**, then confirm **Open**.
4. Follow EDN's prompt to grant Accessibility access.

This is [Apple's supported override for an unnotarized app](https://support.apple.com/guide/mac-help/apple-cant-check-app-for-malicious-software-mchleab3a043/mac). Do not disable Gatekeeper globally. Because beta builds use an ad-hoc signature, macOS may request Accessibility approval again after an update.

EDN workspaces are app-level and replay layouts you arrange yourself. They do not replace macOS Spaces or isolate individual windows of the same app.
