#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d Frameworks/swift/IDevice.xcframework ]]; then
  echo 'IDevice.xcframework is already present.'
  exit 0
fi
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
curl -fL --retry 2 \
  https://github.com/jkcoxson/idevice/releases/download/v0.1.68/idevice-xcframework-v0.1.68.zip \
  -o "$work_dir/idevice.zip"
actual=$(shasum -a 256 "$work_dir/idevice.zip" | cut -d ' ' -f 1)
expected=c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7
[[ "$actual" == "$expected" ]] || { echo 'IDevice checksum mismatch' >&2; exit 1; }
mkdir -p Frameworks
unzip -q "$work_dir/idevice.zip" -d Frameworks
