# ReportMate for Mac

> Canonical, cross-tool. `CLAUDE.md` is a one-line `@AGENTS.md` import.

`ReportMate.app` is the native SwiftUI counterpart of the ReportMate web dashboard
(`reportmate/reportmate-app-web`). It reads the fleet API; it does not collect
anything. The per-device runner lives in `reportmate/reportmate-client-mac`, and the
Windows dashboard app in `reportmate/reportmate-app-csharp`.

## Layout

- `Sources/ReportMateKit` — the library: API client, JSON readers, report
  aggregations, deep links, the This Mac local report store. Everything testable.
- `Sources/ReportMateUI` — the views, navigation, settings and the app's scenes, as a
  library so the dashboard can also be embedded in another SwiftUI app
  (`ReportMateSession` + `ReportMateDashboard` in `Embedding.swift`).
- `Sources/ReportMateMac` — the app target: `@main`, `Info.plist` (registers the
  `reportmate://` scheme) and `Resources` (the icon). Keep it this thin.
- `Tests/ReportMateKitTests` — Swift Testing suites for the kit.
- `scripts/build-app.sh` — builds `.build/app/ReportMate.app` (`--dmg`, `--pkg`, `--sign`, `--open`).
  It bundles the `reportmateutil` CLI from `reportmate/reportmate-cli` at
  `Contents/Helpers/reportmateutil` (`--no-cli` to skip, `--cli-version=` to pin); the pkg's
  postinstall links it to `/usr/local/bin/reportmateutil`.
- `docs/NATIVE-APP.md` — the page-by-page parity matrix against the web app, the
  link scheme, credentials and build notes. Keep it current.
- `DesignSeeds/` — design references carried over from other apps; not compiled.

## Build and test

```
make app
```

```
swift test
```

If `swift build` fails with a missing `SwiftUIMacros` plugin, point `SDKROOT` at a
Command Line Tools SDK that carries it; the build script does this on its own.

## Rules

- Keep the app page-for-page with the web app. New views the web does not have are
  a decision for Rod, not a default.
- Kit code goes in `ReportMateKit` with tests; views go in `ReportMateUI`. Keep `Embedding.swift` working: the
  embedded dashboard draws its controls in a header row instead of the window toolbar.
- Never commit real device identifiers in fixtures or sample text; use `SAMPLE1`-style
  values. Scratch probes against the live API print kinds and counts only.
- No Python. Swift, bash and jq only.
- Any non-trivial change starts in a worktree at `./.worktrees/<name>` off
  `origin/main` and finishes as a PR. `main` is never pushed directly.
- Commit subjects stay plain prose: no bracketed tags, no `Co-Authored-By`, and no
  session links in commits or PR bodies.
