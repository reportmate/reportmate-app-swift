#!/bin/bash
set -euo pipefail

# Builds the ReportMate fleet app (the SwiftUI counterpart of the web
# dashboard) into a .app bundle at .build/app/ReportMate.app.
#
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --debug    debug build
#   scripts/build-app.sh --open     build, then launch
#   scripts/build-app.sh --sign     codesign with SIGNING_IDENTITY_APP from .env
#   scripts/build-app.sh --dmg      also write .build/app/ReportMate-<version>.dmg
#   scripts/build-app.sh --pkg      also write .build/app/ReportMate-<version>.pkg (installs to /Applications
#                                   and links the bundled CLI into /usr/local/bin)
#   scripts/build-app.sh --no-cli   skip bundling reportmateutil
#   scripts/build-app.sh --cli-version=vYYYY.MM.DD.HHMM  pin the CLI release (default: latest)
#
# The reportmateutil CLI (reportmate/reportmate-cli) rides inside the bundle at
# Contents/Helpers/reportmateutil, the way Managed Reports Runner.app carries
# managedreportsrunner; the pkg postinstall puts it on PATH. It cannot sit in
# Contents/MacOS beside the app's own executable; Contents/Helpers is the
# place for a bundled tool.
#
# The Managed Reports Runner (the per-device client) is built by build.sh;
# this script only produces the operator app.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Command Line Tools on a macOS beta can ship an SDK whose SwiftUI macros
# plugin is missing; the previous SDK still builds the app. When the Command
# Line Tools are the selected toolchain and no SDKROOT is set, prefer the
# newest of its SDKs known to carry the plugin. Never touch SDKROOT under a
# full Xcode: pairing Xcode's compiler with the Command Line Tools' older SDK
# breaks the Observable macro ("shouldNotifyObservers is not covered").
if [ -z "${SDKROOT:-}" ]; then
    case "$(xcode-select -p 2>/dev/null || true)" in
        /Library/Developer/CommandLineTools*)
            for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk; do
                if [ -d "$sdk" ]; then export SDKROOT="$sdk"; break; fi
            done
            ;;
    esac
fi

CONFIG="release"
OPEN=0
SIGN=0
DMG=0
PKG=0
CLI=1
CLI_VERSION="${REPORTMATE_CLI_VERSION:-}"
VERSION="${VERSION:-$(date +%Y.%m.%d.%H%M)}"
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --open) OPEN=1 ;;
        --sign) SIGN=1 ;;
        --dmg) DMG=1 ;;
        --pkg) PKG=1 ;;
        --no-cli) CLI=0 ;;
        --cli-version=*) CLI_VERSION="${arg#--cli-version=}" ;;
        --version=*) VERSION="${arg#--version=}" ;;
    esac
done

swift build -c "$CONFIG" --product ReportMateMac

BIN=".build/$CONFIG/ReportMateMac"
if [ ! -f "$BIN" ]; then
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/ReportMateMac"
fi
[ -f "$BIN" ] || { echo "ReportMateMac binary not found"; exit 1; }

APP=".build/app/ReportMate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReportMate"
chmod +x "$APP/Contents/MacOS/ReportMate"
sed -e "s|<string>0.1.0</string>|<string>$VERSION</string>|" Sources/ReportMateMac/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ "$CLI" = "1" ]; then
    # The tool was renamed from reportmate to reportmateutil; releases on either
    # side of that rename are accepted (new asset first) and the result is always
    # staged under the new name, so a build never depends on which one it meets.
    if [ -n "$CLI_VERSION" ]; then
        CLI_BASE="https://github.com/reportmate/reportmate-cli/releases/download/$CLI_VERSION"
    else
        CLI_BASE="https://github.com/reportmate/reportmate-cli/releases/latest/download"
    fi
    CLI_TMP="$(mktemp -d)"
    ASSET=""
    for candidate in reportmateutil-universal-apple-darwin.tar.gz reportmate-universal-apple-darwin.tar.gz; do
        if curl -fsSL --retry 3 -o "$CLI_TMP/$candidate" "$CLI_BASE/$candidate" 2>/dev/null; then ASSET="$candidate"; break; fi
    done
    [ -n "$ASSET" ] || { echo "No reportmateutil release asset found under $CLI_BASE"; exit 1; }
    tar -xzf "$CLI_TMP/$ASSET" -C "$CLI_TMP"
    CLI_BIN="$(find "$CLI_TMP" -type f \( -name reportmateutil -o -name reportmate \) | head -1)"
    [ -n "$CLI_BIN" ] || { echo "reportmateutil binary not found in $ASSET"; exit 1; }
    mkdir -p "$APP/Contents/Helpers"
    cp "$CLI_BIN" "$APP/Contents/Helpers/reportmateutil"
    chmod 755 "$APP/Contents/Helpers/reportmateutil"
    rm -rf "$CLI_TMP"
    echo "Bundled reportmateutil: $("$APP/Contents/Helpers/reportmateutil" --version 2>/dev/null | head -1 || echo unknown)"
fi
if [ ! -f "Sources/ReportMateMac/Resources/AppIcon.icns" ] && command -v iconutil >/dev/null; then
    swift scripts/make-app-icon.swift "Sources/ReportMateMac/Resources/AppIcon.icns" >/dev/null || true
fi
if [ -f "Sources/ReportMateMac/Resources/AppIcon.icns" ]; then
    cp "Sources/ReportMateMac/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

if [ "$SIGN" = "1" ]; then
    if [ -f .env ]; then
        set -a; . ./.env; set +a
    fi
    : "${SIGNING_IDENTITY_APP:?SIGNING_IDENTITY_APP is not set (put it in .env)}"
    if [ -f "$APP/Contents/Helpers/reportmateutil" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY_APP" "$APP/Contents/Helpers/reportmateutil"
    fi
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY_APP" "$APP"
    codesign --verify --verbose=2 "$APP"
else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

if [ "$DMG" = "1" ] && command -v hdiutil >/dev/null; then
    STAGE=".build/app/dmg"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    DMG_PATH=".build/app/ReportMate-$VERSION.dmg"
    rm -f "$DMG_PATH"
    hdiutil create -volname "ReportMate $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
    rm -rf "$STAGE"
    echo "Wrote $DMG_PATH"
fi

if [ "$PKG" = "1" ]; then
    SCRIPTS=".build/app/pkg-scripts"
    rm -rf "$SCRIPTS"
    mkdir -p "$SCRIPTS"
    cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
# Put the bundled reportmateutil CLI on PATH, the way the runner pkg links managedreportsrunner.
CLI="/Applications/ReportMate.app/Contents/Helpers/reportmateutil"
if [ -x "$CLI" ]; then
    mkdir -p /usr/local/bin
    ln -sf "$CLI" /usr/local/bin/reportmateutil
fi
exit 0
POSTINSTALL
    chmod 755 "$SCRIPTS/postinstall"
    PKG_PATH=".build/app/ReportMate-$VERSION.pkg"
    rm -f "$PKG_PATH"
    pkgbuild --component "$APP" --install-location /Applications --scripts "$SCRIPTS" \
        --identifier com.github.reportmate.app --version "$VERSION" "$PKG_PATH.unsigned" >/dev/null
    if [ "$SIGN" = "1" ] && [ -n "${SIGNING_IDENTITY_INSTALLER:-}" ]; then
        productsign --sign "$SIGNING_IDENTITY_INSTALLER" "$PKG_PATH.unsigned" "$PKG_PATH" >/dev/null
        rm -f "$PKG_PATH.unsigned"
    else
        mv "$PKG_PATH.unsigned" "$PKG_PATH"
    fi
    rm -rf "$SCRIPTS"
    echo "Wrote $PKG_PATH"
fi

echo "Built $APP ($CONFIG, $VERSION)"
if [ "$OPEN" = "1" ]; then
    open "$APP"
fi
