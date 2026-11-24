#!/bin/bash
# Compiles Whisper via SwiftPM, signs it with the hardened runtime, installs
# to /Applications. `./build.sh --ship` also zips it, checks it the way
# Gatekeeper will, notarizes when it can, and uploads it to the GitHub release.
set -e
cd "$(dirname "$0")"

APP="Whisper.app"
VERSION="$(cat VERSION)"
BIN="$APP/Contents/MacOS/Whisper"
REPO="MaxOLeary/whisper"
SHIP=0
[ "${1:-}" = "--ship" ] && SHIP=1

# Drop only this target's object files: incremental release builds have linked
# stale .o files more than once. Removing the whole Whisper.build folder breaks
# SwiftPM (it loses output-file-map.json), so delete just the .o files.
# FluidAudio's objects stay cached.
find .build/arm64-apple-macosx/release/Whisper.build -name '*.o' -delete 2>/dev/null || true

swift build -c release --product Whisper --arch arm64
REL="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$REL/Whisper" "$BIN"

mkdir -p "$APP/Contents/Resources/Fonts"
cp icon/Whisper.icns "$APP/Contents/Resources/"
cp fonts/*.ttf fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Whisper</string>
    <key>CFBundleDisplayName</key>     <string>Whisper</string>
    <key>CFBundleIdentifier</key>      <string>com.maxoleary.whisper</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Whisper</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
    <key>CFBundleIconFile</key>         <string>Whisper</string>
    <key>ATSApplicationFontsPath</key>  <string>Fonts</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Whisper records your voice while you hold the hotkey so it can transcribe it locally.</string>
</dict>
</plist>
PLIST
echo "Built $APP $VERSION"

# Identity: Developer ID if this Mac has one, else the self-signed Postit Dev
# cert, else ad-hoc. macOS keys the mic and accessibility grants to the
# signature, so a stable cert keeps them across rebuilds; ad-hoc resets them
# every build and Gatekeeper treats it as malware, so it must never ship.
ID="$(security find-identity -v -p codesigning 2>/dev/null \
      | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
if [ -z "$ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Postit Dev"'; then
    ID="Postit Dev"
fi
if [ -z "$ID" ]; then
    ID="-"
    echo "WARNING: no signing identity found, signing ad-hoc. Fine for local use." >&2
    echo "WARNING: an ad-hoc build must never be shipped (macOS shows Malware Blocked)." >&2
    if [ "$SHIP" = 1 ]; then
        echo "Refusing --ship with an ad-hoc signature." >&2
        exit 1
    fi
fi
echo "Signing identity: $ID"

# A trusted timestamp only makes sense on a Developer ID signature; Apple's
# timestamp server rejects self-signed certs.
TS="--timestamp=none"
case "$ID" in "Developer ID"*) TS="--timestamp" ;; esac

# Sign a copy in a temp dir so the repo's Whisper.app stays unsigned and no
# Finder metadata sneaks into the seal.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/$APP"
xattr -cr "$STAGE/$APP"

# Hardened runtime is required for notarization, and the entitlement keeps the
# microphone reachable under it.
codesign --force --options runtime $TS --entitlements entitlements.plist -s "$ID" "$STAGE/$APP"

install_app() {
    pkill -x Whisper 2>/dev/null || true
    pkill -x whisper-server 2>/dev/null || true
    rm -rf "/Applications/$APP"
    cp -R "$1" "/Applications/$APP"
    echo "Installed to /Applications/$APP"
    # Silent on success. A broken seal here is a broken seal for everyone.
    codesign --verify --deep --strict "/Applications/$APP"
    echo "codesign verify: OK"
    codesign -dv --verbose=2 "/Applications/$APP" 2>&1 | grep -E '^Authority=|flags=' || true
    # Always `open -a`: exec'ing the binary breaks the menu bar icon for the session.
    open -a "/Applications/$APP"
}
install_app "$STAGE/$APP"

[ "$SHIP" = 1 ] || exit 0

# ---- ship ------------------------------------------------------------------

make_zip() {
    rm -f "$STAGE/Whisper.zip"
    ditto -c -k --keepParent --norsrc --noextattr "$STAGE/$APP" "$STAGE/Whisper.zip"
}
make_zip

# Gatekeeper dry run: a quarantined copy is what a Safari download looks like.
# `rejected, origin=<identity>` is the ordinary Open Anyway case; `accepted`
# means notarized. `revoked` means Malware Blocked, which nobody can click
# past, so it is fatal.
SIM="$(mktemp -d)"
ditto "$STAGE/$APP" "$SIM/$APP"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$SIM/$APP"
set +e
VERDICT="$(spctl -a -vv -t exec "$SIM/$APP" 2>&1)"
SPCTL_EXIT=$?
set -e
rm -rf "$SIM"
echo "spctl verdict (exit $SPCTL_EXIT):"
echo "$VERDICT" | sed 's/^/    /'
if echo "$VERDICT" | grep -qi 'revoked'; then
    echo "Gatekeeper says revoked. Do not ship this build." >&2
    exit 1
fi

# Notarize when there is a Developer ID and stored credentials
# (`xcrun notarytool store-credentials notary`). Staple so the app passes
# Gatekeeper offline, then re-zip because the ticket lives inside the bundle.
case "$ID" in
"Developer ID"*)
    if xcrun notarytool history --keychain-profile notary >/dev/null 2>&1; then
        xcrun notarytool submit "$STAGE/Whisper.zip" --keychain-profile notary --wait
        xcrun stapler staple "$STAGE/$APP"
        xcrun stapler validate "$STAGE/$APP"
        make_zip
        install_app "$STAGE/$APP"
    else
        echo "Developer ID present but no 'notary' keychain profile; skipping notarization."
    fi
    ;;
*)
    echo "Not notarized: no Developer ID on this Mac."
    ;;
esac

# One rolling release named `latest`; the download URL never changes.
if gh release view latest -R "$REPO" >/dev/null 2>&1; then
    gh release upload latest "$STAGE/Whisper.zip" -R "$REPO" --clobber
else
    gh release create latest "$STAGE/Whisper.zip" -R "$REPO" --title Whisper \
        --notes "Unzip, double-click Whisper. Always the newest build."
fi

trap - EXIT   # keep the zip around
echo "Zip:      $STAGE/Whisper.zip"
echo "Download: https://github.com/$REPO/releases/latest/download/Whisper.zip"
