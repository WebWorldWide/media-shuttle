#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${VERSION:-0.0.1}}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/media-shuttle-release"
ARTIFACTS="$ROOT/artifacts"
APP="$BUILD_ROOT/Media Shuttle.app"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/Resources/MediaShuttle.entitlements"

# Notarization runs when credentials are supplied, in either form notarytool accepts:
#   NOTARY_KEYCHAIN_PROFILE  a profile saved with `xcrun notarytool store-credentials`
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER  an App Store Connect API key (.p8)
# It needs a Developer ID Application identity in CODE_SIGN_IDENTITY; an ad-hoc build can't be
# notarized.
NOTARY_ARGS=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
fi
NOTARIZE=0
if (( ${#NOTARY_ARGS[@]} )); then
    if [[ "$IDENTITY" == "-" || "$IDENTITY" != *"Developer ID Application"* ]]; then
        print -u2 "Notarization needs CODE_SIGN_IDENTITY set to a 'Developer ID Application' identity."
        exit 1
    fi
    NOTARIZE=1
fi

# Developer ID signatures need a secure timestamp to be notarized, and the hardened runtime to be
# accepted at all. Ad-hoc builds skip the timestamp, which needs a network round trip to Apple.
SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
fi

# Submits a file, waits for Apple's verdict, and prints the notary log if it was not accepted.
notarize() {
    local file="$1"
    local result_json="$BUILD_ROOT/notary-$(basename "$file").json"
    print "Submitting $(basename "$file") for notarization…"
    xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" --wait --output-format json > "$result_json" || true
    local submission_status submission_id
    submission_status="$(plutil -extract status raw -o - "$result_json" 2>/dev/null || echo unknown)"
    submission_id="$(plutil -extract id raw -o - "$result_json" 2>/dev/null || echo)"
    if [[ "$submission_status" != "Accepted" ]]; then
        print -u2 "Notarization of $(basename "$file") finished with status: $submission_status"
        cat "$result_json" >&2
        if [[ -n "$submission_id" ]]; then
            xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" >&2 || true
        fi
        exit 1
    fi
    print "Notarization accepted ($submission_id)."
}

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$ARTIFACTS"

BUILD_ARGS=(
    --package-path "$ROOT"
    --scratch-path "$BUILD_ROOT/swift"
    --configuration release
    --arch arm64
    --arch x86_64
)

swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/MediaShuttle" "$APP/Contents/MacOS/MediaShuttle"

# Compile the Icon Composer document into the bundle. actool emits Assets.car, which
# CFBundleIconName resolves through and which is what makes this a native icon on
# macOS 26 and newer — the system draws the document's own layers and applies the
# material, dark and tinted treatments rather than scaling a flat bitmap. It also
# emits an icns from the same document as the fallback for older systems, so the two
# can never drift apart the way a separately generated one would.
ICON_DOC="$ROOT/Resources/MediaShuttle.icon"
ICON_PLIST="$BUILD_ROOT/icon-partial.plist"
xcrun actool \
    --output-format human-readable-text \
    --notices --warnings \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --app-icon MediaShuttle \
    --output-partial-info-plist "$ICON_PLIST" \
    --compile "$APP/Contents/Resources" \
    "$ICON_DOC"

if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    print -u2 "actool produced no Assets.car from $ICON_DOC. Xcode 26 or newer is required."
    exit 1
fi

sed \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

plutil -lint "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# The app is notarized and stapled on its own first, so it carries its ticket out of the disk
# image: Gatekeeper then accepts it offline after it is copied to Applications. The disk image is
# notarized separately below, because building it changes nothing inside the app but is itself a
# new file Apple has never seen.
if (( NOTARIZE )); then
    APP_ZIP="$BUILD_ROOT/MediaShuttle-notarize.zip"
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
    notarize "$APP_ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

DMG="$ARTIFACTS/MediaShuttle-v$VERSION-macOS-universal.dmg"
STAGING="$BUILD_ROOT/dmg-staging"
rm -f "$DMG" "$ARTIFACTS/SHA256SUMS-macos.txt"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Media Shuttle.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Media Shuttle" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"

DMG_SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    DMG_SIGN_ARGS+=(--timestamp)
fi
codesign "${DMG_SIGN_ARGS[@]}" "$DMG"
codesign --verify --verbose=2 "$DMG"

if (( NOTARIZE )); then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(
    cd "$ARTIFACTS"
    shasum -a 256 "$(basename "$DMG")" > SHA256SUMS-macos.txt
)

printf 'Created %s\n' "$DMG"
