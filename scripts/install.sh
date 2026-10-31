#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source_app="${1:-$HOME/Library/Caches/LightNote/Build/LightNote.app}"
install_dir="${LIGHTNOTE_INSTALL_DIR:-/Applications}"
if [[ ! -w "$install_dir" && -z "${LIGHTNOTE_INSTALL_DIR:-}" ]]; then
    install_dir="$HOME/Applications"
fi
mkdir -p "$install_dir"
installed_app="$install_dir/LightNote.app"
if [[ "$source_app" == "$installed_app" ]]; then
    print -u2 'Source and installed app must be different paths.'
    exit 1
fi
if [[ -e "$installed_app" ]]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")"
    if [[ "$bundle_id" != com.lightnote.app ]]; then
        print -u2 "A different application already exists at $installed_app"
        exit 1
    fi
fi
staging_dir="$(mktemp -d "$install_dir/.LightNote-install.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/LightNote.app"
ditto --norsrc --noextattr "$source_app" "$staged_app"
xattr -cr "$staged_app"
codesign --verify --deep --strict "$staged_app"
if [[ -e "$installed_app" ]]; then
    backup_dir="$HOME/Library/Caches/LightNote/Previous"
    mkdir -p "$backup_dir"
    mv "$installed_app" "$backup_dir/LightNote.$(date +%Y%m%d-%H%M%S).app"
fi
mv "$staged_app" "$installed_app"
registry=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$registry" -u "$source_app" || true
"$registry" -f "$installed_app"
# Preserve old workspace builds outside searchable project folders.
backup_dir="$HOME/Library/Caches/LightNote/Previous"
for legacy_app in build/LightNote.previous.*.app(N); do
    mkdir -p "$backup_dir"
    "$registry" -u "$PWD/$legacy_app" || true
    backup_app="$backup_dir/${legacy_app:t}"
    if [[ ! -e "$backup_app" ]]; then
        mv "$legacy_app" "$backup_app"
    fi
done
mdimport "$installed_app"
mkdir -p build
ln -sfn "$installed_app" build/LightNote.app
print "Installed and registered: $installed_app"
