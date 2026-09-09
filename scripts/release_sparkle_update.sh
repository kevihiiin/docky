#!/bin/zsh
set -euo pipefail
setopt null_glob

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$PROJECT_ROOT/Docky.xcodeproj"
SCHEME="Docky"
CONFIGURATION="Release"
APP_NAME="Docky"
APPCAST_BASE_URL="${APPCAST_BASE_URL:-https://getdocky.com/releases}"
APPCAST_FILENAME="${APPCAST_FILENAME:-appcast.xml}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.1}"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M)}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"

# Releases need a real Developer ID team, but Config/Signing.xcconfig defaults
# to ad-hoc so contributors can build without an Apple account. Take the team
# from the environment, else from the maintainer's gitignored
# Config/Signing.local.xcconfig.
#
# Ask xcodebuild to resolve it rather than parsing the xcconfig here: it is the
# evaluator the build itself uses, so the #include? chain, trailing comments,
# [sdk=*] conditionals and $(inherited) all resolve the way the build sees them
# instead of the way a regex guesses.
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    DEVELOPMENT_TEAM=$(xcodebuild -showBuildSettings -json \
        -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" 2>/dev/null \
        | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((e["buildSettings"].get("DEVELOPMENT_TEAM","") for e in d if e.get("target")=="Docky"), ""))')
fi

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    print -u2 "No signing team configured."
    print -u2 "Set DEVELOPMENT_TEAM=<team id>, or add DEVELOPMENT_TEAM to Config/Signing.local.xcconfig."
    exit 1
fi

# Catch a malformed value here rather than several minutes into the archive,
# where it surfaces as an opaque provisioning error.
if [[ ! "$DEVELOPMENT_TEAM" =~ '^[A-Z0-9]{10}$' ]]; then
    print -u2 "Not a valid Team ID: '$DEVELOPMENT_TEAM'"
    print -u2 "Expected 10 uppercase alphanumerics (e.g. ABCDE12345)."
    exit 1
fi

BUILD_ROOT="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_ROOT/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export"
UPDATES_PATH="$BUILD_ROOT/updates"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
ZIP_NAME="$APP_NAME-$MARKETING_VERSION-$BUILD_VERSION.zip"
ZIP_PATH="$UPDATES_PATH/$ZIP_NAME"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"

if [[ -z "$SPARKLE_BIN_DIR" ]]; then
    candidates=("$HOME/Library/Developer/Xcode/DerivedData"/Docky-*/SourcePackages/artifacts/sparkle/Sparkle/bin)
    if (( ${#candidates[@]} > 0 )); then
        SPARKLE_BIN_DIR="$candidates[1]"
    fi
fi

GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"

if [[ ! -x "$GENERATE_APPCAST" ]]; then
    print -u2 "Sparkle generate_appcast tool not found at: $GENERATE_APPCAST"
    print -u2 "Build the app once in Xcode or override SPARKLE_BIN_DIR before running this script."
    exit 1
fi

mkdir -p "$BUILD_ROOT" "$UPDATES_PATH"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

cat > "$BUILD_ROOT/ExportOptions-DeveloperID.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
EOF

xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGN_STYLE=Automatic

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_ROOT/ExportOptions-DeveloperID.plist"

if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "Exported app not found at: $APP_PATH"
    exit 1
fi

if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    xcrun notarytool submit "$APP_PATH" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait
    xcrun stapler staple "$APP_PATH"
else
    print "Skipping notarization because NOTARYTOOL_PROFILE is not set."
fi

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -n "$RELEASE_NOTES_FILE" ]]; then
    cp "$RELEASE_NOTES_FILE" "$UPDATES_PATH/${ZIP_NAME:r}.md"
fi

"$GENERATE_APPCAST" "$UPDATES_PATH"

print
print "Update artifacts generated in: $UPDATES_PATH"
print "Upload the contents of this folder to: $APPCAST_BASE_URL/"
print "Expected appcast URL: $APPCAST_BASE_URL/$APPCAST_FILENAME"
