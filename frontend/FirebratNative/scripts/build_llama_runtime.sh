#!/bin/bash
set -euo pipefail
# Builds official source, including the simulator slice missing from b11797's prebuilt release.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /tmp/firebrat-llama.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
curl -fL https://github.com/ggml-org/llama.cpp/archive/refs/tags/b11797.tar.gz -o "$work_dir/source.tar.gz"
echo "7f4e54d8d2389c9b3d62624067cc4b51b2b1cf0d863be45a7dd83734b7e113ca  $work_dir/source.tar.gz" | shasum -a 256 -c -
tar -xzf "$work_dir/source.tar.gz" -C "$work_dir"
cd "$work_dir/llama.cpp-b11797"
bash build-xcframework.sh ios-sim ios-device
cp LICENSE build-apple/llama.xcframework/LICENSE
mkdir -p "$project_dir/Packages/LlamaIOS/Artifacts"
cp -R build-apple/llama.xcframework "$project_dir/Packages/LlamaIOS/Artifacts/"
ditto -c -k --sequesterRsrc --keepParent build-apple/llama.xcframework "$project_dir/firebrat-llama-b11797-ios.xcframework.zip"
shasum -a 256 "$project_dir/firebrat-llama-b11797-ios.xcframework.zip"
