# ReportMate for Mac

The native macOS dashboard for [ReportMate](https://github.com/reportmate): the
same fleet views as the web app (`reportmate-app-web`), as a SwiftUI app that
talks straight to the ReportMate API.

- Dashboard, Devices and Events, plus every fleet report (Installs, Applications,
  System, Management, Identity, Hardware, Peripherals, Security, Network) and the
  full device detail with all of its tabs.
- `reportmate://` deep links to any view, with a web handoff (`/open/...`) that
  falls back to the browser when the app is not installed.
- A This Mac mode that reads the local runner's cache without an API.

## Build

```
make app
```

Produces `.build/app/ReportMate.app`. `make app-dmg` also writes a disk image, and
`make app-open` launches the build.

The bundle carries the `reportmateutil` command line tool from
[reportmate-cli](https://github.com/reportmate/reportmate-cli) at
`ReportMate.app/Contents/Helpers/reportmate`. `make app-pkg` writes an installer that
puts the app in `/Applications` and links the tool to `/usr/local/bin/reportmate`, so
it is on PATH in every shell.

## Configure

Settings takes the API endpoint and a read credential: a per-client API key, the
shared client passphrase, or a delegated Entra token from the local `az login`
session. On a Mac whose ReportMate runner already reports, the endpoint (and a
shared passphrase, when the runner uses one) is inherited from the runner's
`com.github.reportmate` preferences.

## Docs

`docs/NATIVE-APP.md` carries the page-by-page parity matrix against the web app,
the deep-link scheme, the credential options and the build notes.

The per-device collector is a separate project: `reportmate-client-mac`.
