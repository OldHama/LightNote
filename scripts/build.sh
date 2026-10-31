#!/bin/zsh
set -eu
cd "${0:A:h:h}"
configuration="${1:-debug}"
# iCloud can reattach FinderInfo after signing. Keep executable bundles outside the synced tree.
output_dir="${LIGHTNOTE_BUILD_DIR:-$HOME/Library/Caches/LightNote/Build}"
app="$output_dir/LightNote.app"
mkdir -p "$app/Contents/MacOS" build
opt=-Onone
if [[ "$configuration" == release ]]; then opt=-O; fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
arch="$(uname -m)"
xcrun swiftc -swift-version 6 "$opt" -g -target "$arch-apple-macosx15.0" -sdk "$sdk" \
    Sources/LightNoteCore/*.swift Sources/LightNote/*.swift \
    -o "$output_dir/LightNote"
mv "$output_dir/LightNote" "$app/Contents/MacOS/LightNote"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable LightNote' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.lightnote.app' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 15.0' "$app/Contents/Info.plist"
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
# Preserve a previous in-workspace build during the one-time migration.
if [[ -e build/LightNote.app && ! -L build/LightNote.app ]]; then
    mv build/LightNote.app "build/LightNote.previous.$(date +%s).app"
fi
ln -sfn "$app" build/LightNote.app
print "Built: $app"
print "Workspace link: $PWD/build/LightNote.app"

# Keep the searchable installed application up to date on every build.
./scripts/install.sh "$app"
