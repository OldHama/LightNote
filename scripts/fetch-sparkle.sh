#!/bin/zsh
set -eu
sparkle_version=2.10.1
sparkle_sha256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
cache_root="$HOME/Library/Caches/LightNote/Dependencies"
sparkle_dir="$cache_root/Sparkle-$sparkle_version"
if [[ ! -d "$sparkle_dir/Sparkle.framework" || ! -x "$sparkle_dir/bin/sign_update" ]]; then
    mkdir -p "$cache_root"
    archive="$cache_root/Sparkle-$sparkle_version.tar.xz"
    curl -fL --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" -o "$archive"
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$sparkle_sha256" ]]; then
        print -u2 'Sparkle download checksum mismatch.'
        exit 1
    fi
    mkdir -p "$sparkle_dir"
    tar -xf "$archive" -C "$sparkle_dir"
fi
print "$sparkle_dir"
