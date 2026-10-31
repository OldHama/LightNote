#!/bin/zsh
set -eu
cd "${0:A:h:h}"
# Build a separate optimized diagnostic executable; leave the installed app untouched.
benchmark_dir="$HOME/Library/Caches/LightNote/SaveBenchmark"
mkdir -p "$benchmark_dir"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
sparkle_dir="$(./scripts/fetch-sparkle.sh)"
xcrun swiftc -swift-version 6 -O -target "$(uname -m)-apple-macosx15.0" -sdk "$sdk" \
    -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker "$sparkle_dir" \
    Sources/LightNoteCore/*.swift Sources/LightNote/*.swift -o "$benchmark_dir/LightNote-save-benchmark"
# --self-test isolates preferences and prevents changing the last-opened document.
"$benchmark_dir/LightNote-save-benchmark" --save-benchmark --self-test
