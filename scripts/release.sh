#!/bin/zsh
set -eu
cd "${0:A:h:h}"
sparkle_dir="$(./scripts/fetch-sparkle.sh)"
account="${LIGHTNOTE_SIGNING_ACCOUNT:-com.lightnote.app}"
public_key="$("$sparkle_dir/bin/generate_keys" --account "$account" -p)"
expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Info.plist)"
if [[ "$public_key" != "$expected_key" ]]; then
    print -u2 'Signing key does not match the public key embedded in Info.plist.'
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
release_tag="v$version"
if [[ "${1:-}" == --publish ]] && gh release view "$release_tag" --repo OldHama/LightNote >/dev/null 2>&1; then
    print -u2 "Release $release_tag already exists. Increase the version and build number first."
    exit 1
fi
LIGHTNOTE_ARCHS='arm64 x86_64' ./scripts/build.sh release
app="${LIGHTNOTE_BUILD_DIR:-$HOME/Library/Caches/LightNote/Build}/LightNote.app"
release_dir="$HOME/Library/Caches/LightNote/Releases/$version"
mkdir -p "$release_dir"
archive_name="LightNote-$version-macos-universal.zip"
archive="$release_dir/$archive_name"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
signature="$("$sparkle_dir/bin/sign_update" --account "$account" -p "$archive")"
"$sparkle_dir/bin/sign_update" --account "$account" --verify "$archive" "$signature"
python3 - "$version" "$build_number" "$archive" "$signature" <<'PY'
import sys, pathlib, email.utils, xml.etree.ElementTree as ET
version, build, archive_path, signature = sys.argv[1:]
archive = pathlib.Path(archive_path)
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
root = ET.Element('rss', version='2.0')
channel = ET.SubElement(root, 'channel')
ET.SubElement(channel, 'title').text = 'LightNote Updates'
ET.SubElement(channel, 'link').text = 'https://github.com/OldHama/LightNote/releases'
ET.SubElement(channel, 'description').text = 'Signed LightNote macOS releases'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = f'LightNote {version}'
ET.SubElement(item, 'pubDate').text = email.utils.formatdate(usegmt=True)
ET.SubElement(item, f'{{{ns}}}minimumSystemVersion').text = '15.0'
ET.SubElement(item, 'description').text = 'LightNote 업데이트. 노트 자동 저장 및 마지막 문서 복원을 유지합니다.'
ET.SubElement(item, 'enclosure', {
    'url': f'https://github.com/OldHama/LightNote/releases/download/v{version}/{archive.name}',
    f'{{{ns}}}version': build, f'{{{ns}}}shortVersionString': version,
    f'{{{ns}}}edSignature': signature, 'length': str(archive.stat().st_size),
    'type': 'application/octet-stream'
})
ET.indent(root)
ET.ElementTree(root).write(archive.parent / 'appcast.xml', encoding='utf-8', xml_declaration=True)
PY
"$sparkle_dir/bin/sign_update" --account "$account" "$release_dir/appcast.xml"
"$sparkle_dir/bin/sign_update" --account "$account" --verify "$release_dir/appcast.xml"
shasum -a 256 "$archive" > "$release_dir/SHA256SUMS.txt"
# Do not put the builder's local path in the public checksum file.
python3 - "$release_dir/SHA256SUMS.txt" "$archive_name" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); digest = p.read_text().split()[0]
p.write_text(f'{digest}  {sys.argv[2]}\n')
PY
if [[ "${1:-}" == --publish ]]; then
    gh release create "$release_tag" --repo OldHama/LightNote --target "$(git rev-parse HEAD)" \
        --title "LightNote $version" --generate-notes \
        "$archive" "$release_dir/appcast.xml" "$release_dir/SHA256SUMS.txt"
fi
print "Signed release files: $release_dir"
