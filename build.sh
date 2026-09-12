#!/bin/bash
# Builds Ward.app — a self-contained bundle with no dependencies to fetch.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Ward.app"
CONF=release

echo "==> Compiling"
if swift build -c $CONF --arch arm64 --arch x86_64 2>/dev/null; then
    BIN=$(swift build -c $CONF --arch arm64 --arch x86_64 --show-bin-path)
    echo "    universal (Apple silicon + Intel)"
else
    swift build -c $CONF
    BIN=$(swift build -c $CONF --show-bin-path)
    echo "    native only"
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Ward" "$APP/Contents/MacOS/Ward"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Ward</string>
    <key>CFBundleDisplayName</key>           <string>Ward</string>
    <key>CFBundleIdentifier</key>            <string>app.ward.Ward</string>
    <key>CFBundleExecutable</key>            <string>Ward</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>LSUIElement</key>                   <false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Ward reads the address and title of the page you are looking at so it can tell study from distraction, and sends the tab elsewhere when you have asked it to.</string>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

echo "==> Signing"
# An ad-hoc signature's designated requirement is the cdhash, so every rebuild looks
# like a different application to macOS and permissions have to be granted again.
# ./setup-signing.sh creates a certificate that avoids this; use it when it's there.
IDENTITY="Ward Local Signing"
STABLE=no
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    if codesign --force --sign "$IDENTITY" --identifier app.ward.Ward \
                --timestamp=none "$APP" 2>/dev/null; then
        STABLE=yes
        echo "    signed with $IDENTITY (permissions survive rebuilds)"
    fi
fi
if [[ "$STABLE" == no ]]; then
    codesign --force --sign - --identifier app.ward.Ward --timestamp=none "$APP" 2>/dev/null \
        || codesign --force --sign - "$APP"
    echo "    signed ad-hoc"
fi

echo "==> Done: $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    AGENT="$HOME/Library/LaunchAgents/app.ward.agent.plist"
    if [[ -f "$AGENT" ]]; then
        # Let launchd own the restart, or `open` adds a second copy alongside it.
        launchctl bootout "gui/$UID/app.ward.agent" 2>/dev/null || true
    fi
    pkill -x Ward 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Ward.app
    cp -R "$APP" /Applications/Ward.app
    xattr -cr /Applications/Ward.app 2>/dev/null || true
    if [[ -f "$AGENT" ]]; then
        launchctl bootstrap "gui/$UID" "$AGENT" 2>/dev/null || true
    else
        open /Applications/Ward.app
    fi
    echo "==> Ward is running — look for the shield in your menu bar"
    if [[ "$STABLE" == no ]]; then
        cat <<'NOTE'

    Note: this build is ad-hoc signed, so macOS sees it as a new application and
    Accessibility has to be granted again. System Settings may still show an old
    "Ward" entry switched on — that one belongs to the previous build.

      System Settings > Privacy & Security > Accessibility
        1. select Ward and press the minus button
        2. press plus and choose /Applications/Ward.app

    Run ./setup-signing.sh once to stop this happening on every rebuild.
NOTE
    fi
fi
