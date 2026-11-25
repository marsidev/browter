#!/bin/bash
# Builds build/Browter.app (ad-hoc signed by default).
# Usage:
#   ./build.sh                  # Build for host arch + install to ~/Applications
#   ./build.sh --no-install     # Build only (output: build/Browter.app)
#   ./build.sh --universal      # Build arm64 + x86_64 universal binary
#   ./build.sh --version 1.2.0  # Stamp CFBundleShortVersionString in Info.plist
#   ./build.sh --sign "-"       # Codesign identity (default: "-" ad-hoc)
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=1
UNIVERSAL=0
VERSION=""
SIGN_IDENTITY="-"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-install) INSTALL=0; shift ;;
        --universal)  UNIVERSAL=1; shift ;;
        --version)    VERSION="$2"; shift 2 ;;
        --sign)       SIGN_IDENTITY="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,8p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

APP="build/Browter.app"
DEST="$HOME/Applications/Browter.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/chromium-tab.applescript "$APP/Contents/Resources/chromium-tab.applescript"

if [[ -n "$VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

ICONSET="build/AppIcon.iconset"
swift make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

SOURCES=(Sources/BrowterCore/Config.swift Sources/BrowterCore/RouterEngine.swift Sources/Browter/main.swift)

if [[ "$UNIVERSAL" -eq 1 ]]; then
    swiftc -O -swift-version 6 -target arm64-apple-macos13.0 -o "build/Browter-arm64" "${SOURCES[@]}"
    swiftc -O -swift-version 6 -target x86_64-apple-macos13.0 -o "build/Browter-x86_64" "${SOURCES[@]}"
    lipo -create "build/Browter-arm64" "build/Browter-x86_64" -output "$APP/Contents/MacOS/Browter"
    rm -f "build/Browter-arm64" "build/Browter-x86_64"
else
    swiftc -O -swift-version 6 -target "$(uname -m)-apple-macos13.0" -o "$APP/Contents/MacOS/Browter" "${SOURCES[@]}"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force -s - "$APP"
else
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
fi

echo "Built $APP"

if [[ "$INSTALL" -eq 1 ]]; then
    pkill -x Browter 2>/dev/null || true   # the next click starts the new build
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    "$LSREGISTER" -f "$DEST"
    if [[ -d "$HOME/.local/bin" ]]; then
        ln -sf "$DEST/Contents/MacOS/Browter" "$HOME/.local/bin/browter"
    fi
    echo "Installed $DEST"
fi
