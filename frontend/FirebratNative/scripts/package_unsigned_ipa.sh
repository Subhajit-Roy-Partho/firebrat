#!/bin/bash
set -euo pipefail
archive_dir="$1"
output_file="$2"
app_dir="$archive_dir/Products/Applications/FirebratNative.app"
test -d "$app_dir"
package_dir="$(mktemp -d /tmp/firebrat-ipa.XXXXXX)"
trap 'rm -rf "$package_dir"' EXIT
mkdir -p "$package_dir/Payload"
ditto "$app_dir" "$package_dir/Payload/FirebratNative.app"
(cd "$package_dir" && /usr/bin/zip -qr "$output_file" Payload)
/usr/bin/unzip -tq "$output_file"
(cd "$(dirname "$output_file")" && shasum -a 256 "$(basename "$output_file")" > "$(basename "$output_file").sha256")
echo "Unsigned IPA created. Signing is required before installation: $output_file"
