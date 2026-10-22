# ReportMate for Mac wiki

ReportMate for Mac is the native SwiftUI counterpart of the ReportMate web dashboard. It reads the fleet API and renders the same dashboard, device, event, report and settings pages for operators. It does not collect anything: the per-device runner lives in [reportmate-client-mac](https://github.com/reportmate/reportmate-client-mac).

## Read first

- [Project overview, build and configuration](../README.md)
- [Contributor instructions](../AGENTS.md)
- [Native app reference: parity matrix, links, credentials and build notes](../docs/NATIVE-APP.md)
- [Swift package definition](../Package.swift)

## Architecture

The package has three targets. [ReportMateKit](../Sources/ReportMateKit) is the library with no UI: the API client in [ReportMateAPI.swift](../Sources/ReportMateKit/API/ReportMateAPI.swift), Keychain and Entra token sources, the JSON tree every reader walks, per-module readers and report aggregations, deep-link parsing, and the local report store.

[ReportMateUI](../Sources/ReportMateUI) holds the SwiftUI views, navigation, settings and the app's scenes. It is a library so another SwiftUI app can embed the dashboard through `ReportMateSession` and `ReportMateDashboard` in [Embedding.swift](../Sources/ReportMateUI/Embedding.swift). [ReportMateMac](../Sources/ReportMateMac) is the thin app target: `@main`, the `Info.plist` that registers the `reportmate://` scheme, and the icon.

The app authenticates with a per-client API key, the shared client passphrase, or a delegated Entra token minted from the local `az login` session. On a Mac whose runner already reports, it inherits the API URL from the runner's `com.github.reportmate` preferences. This Mac mode reads the runner's local cache through [LocalReportStore.swift](../Sources/ReportMateKit/Local/LocalReportStore.swift) and needs no API connection.

The app bundle carries the `reportmateutil` command line tool from [reportmate-cli](https://github.com/reportmate/reportmate-cli) at `Contents/Helpers/reportmateutil`. [build-app.sh](../scripts/build-app.sh) fetches it at build time and can pin or skip it.

## Development and verification

Use the [contributor instructions](../AGENTS.md) and the current README for setup and checks. The [Makefile](../Makefile) wraps the build script. Build the app bundle into `.build/app/ReportMate.app`:

```bash
make app
```

Run the Swift Testing suites for the kit:

```bash
swift test
```

Kit behaviour is tested in [ReportMateKitTests](../Tests/ReportMateKitTests); views are checked against the web app page by page using the parity matrix in [NATIVE-APP.md](../docs/NATIVE-APP.md). The [CI workflow](../.github/workflows/ci.yml) runs the tests and builds the app and installer package on every push and pull request, uploading unsigned artifacts. A version tag runs the [release workflow](../.github/workflows/release.yml), which publishes the unsigned app, package and disk image; signing and notarization happen downstream.

## Documentation ownership

Keep this wiki as the entry point and update the linked pages where the facts belong: build and configuration in the README, views, links and credentials in [NATIVE-APP.md](../docs/NATIVE-APP.md), and working rules in [AGENTS.md](../AGENTS.md). Examples use fictional data such as `SAMPLE1` serials. Deployment inventories, credentials, signing identities and organization-specific operations belong with their deployment owner.
