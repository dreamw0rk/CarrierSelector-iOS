#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash tools/bootstrap.sh
xcodegen generate
xcodebuild -project CarrierSelector.xcodeproj -scheme CarrierSelector -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" SWIFT_MODULE_CACHE_PATH="$PWD/build/ModuleCache" \
  CODE_SIGNING_ALLOWED=NO build
app_path=build/DerivedData/Build/Products/Release-iphoneos/CarrierSelector.app
test -f "$app_path/profiles.json"
test -f "$app_path/models.json"
test -d "$app_path/Library.momd"
package_dir=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$package_dir"' EXIT
mkdir -p "$package_dir/Payload"
ditto --norsrc --noextattr "$app_path" "$package_dir/Payload/CarrierSelector.app"
ditto -c -k --norsrc --noextattr --keepParent "$package_dir/Payload" build/CarrierSelector-unsigned.ipa
python3 tools/verify_ipa.py build/CarrierSelector-unsigned.ipa
echo 'Built build/CarrierSelector-unsigned.ipa — sign with your sideload tool before installation.'
