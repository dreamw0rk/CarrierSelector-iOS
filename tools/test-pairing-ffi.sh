#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests build/ModuleCache
library_dir=Frameworks/swift/IDevice.xcframework/macos-arm64_x86_64
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path build/ModuleCache \
  -I "$library_dir/Headers" Tests/PairingFFISmoke.swift "$library_dir/idevice-macos.a" \
  -framework Security -framework SystemConfiguration -lresolv -lz -o build/tests/pairing-ffi-smoke
build/tests/pairing-ffi-smoke
