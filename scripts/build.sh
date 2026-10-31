#!/bin/zsh
set -eu
cd "${0:A:h:h}"
configuration="${1:-debug}"
# iCloud can reattach FinderInfo after signing. Keep executable bundles outside the synced tree.
output_dir="${LIGHTNOTE_BUILD_DIR:-$HOME/Library/Caches/LightNote/Build}"
app="$output_dir/LightNote.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon.png -nt Resources/AppIcon.icns ]]; then
    ./scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp ThirdPartyNotices/Sparkle-LICENSE "$app/Contents/Resources/Sparkle-LICENSE"
opt=-Onone
if [[ "$configuration" == release ]]; then opt=-O; fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
sparkle_dir="$(./scripts/fetch-sparkle.sh)"
mkdir -p "$app/Contents/Frameworks"
# Keep upstream helper signatures intact inside the outer ad-hoc app signature.
if [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]]; then
    rm -rf "$app/Contents/Frameworks/Sparkle.framework"
fi
ditto --norsrc --noextattr "$sparkle_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
architecture_list="${LIGHTNOTE_ARCHS:-$(uname -m)}"
binaries=()
for build_arch in ${=architecture_list}; do
    binary="$output_dir/LightNote-$build_arch"
    xcrun swiftc -swift-version 6 "$opt" -g -target "$build_arch-apple-macosx15.0" -sdk "$sdk" \
        -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
        Sources/LightNoteCore/*.swift Sources/LightNote/*.swift -o "$binary"
    binaries+=("$binary")
done
if (( ${#binaries[@]} > 1 )); then
    lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/LightNote"
else
    cp "${binaries[1]}" "$app/Contents/MacOS/LightNote"
fi
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
