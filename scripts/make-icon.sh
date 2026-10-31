#!/bin/zsh
set -eu
cd "${0:A:h:h}"
icon_dir="${LIGHTNOTE_BUILD_DIR:-$HOME/Library/Caches/LightNote/Build}/AppIcon.iconset"
mkdir -p "$icon_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/AppIcon.png --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$icon_dir" --output Resources/AppIcon.icns
print 'Created Resources/AppIcon.icns'
