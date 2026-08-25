# Contributing to EDN

Thanks for helping improve EDN. Bug fixes, compatibility improvements, tests, and documentation are welcome.

Before implementing a new feature, open an issue to discuss the user problem first. EDN deliberately does not continuously calculate layouts, automatically assign apps, infer display profiles, or isolate individual windows across workspaces. Those boundaries keep switching fast and predictable.

EDN uses Swift and public macOS system frameworks only. Please do not add third-party runtime dependencies without prior discussion, and preserve backward compatibility for the plain JSON configuration whenever possible.

Run the checks before submitting a pull request:

```sh
swift test
scripts/test-cli-json.sh
```

For a local app build:

```sh
scripts/setup-local-signing.sh
scripts/build-app.sh
scripts/install-local.sh
```

Keep pull requests focused. Explain the observable behavior, include tests for logic changes, and call out anything that affects window state, permissions, configuration, or release packaging.
