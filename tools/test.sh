#!/bin/bash
set -Eeuo pipefail
trap 'echo "Test command failed at line $LINENO: $BASH_COMMAND" >&2' ERR
cd "$(dirname "$0")/.."
mkdir -p build/tests build/ModuleCache
python3 -m unittest discover -s Tests -p 'test_*.py'
xcrun clang -fobjc-arc -fblocks -DCS_TELEPHONY_TESTING=1 -I App \
  App/TelephonyProbe.m Tests/TelephonyProbeTests.m -framework Foundation -o build/tests/telephony-probe-tests
build/tests/telephony-probe-tests
xcrun clang -fobjc-arc -fblocks -c App/TelephonyProbe.m -o build/tests/telephony-probe.o
xcrun momc Resources/Library.xcdatamodeld build/tests/Library.momd
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path build/ModuleCache \
  -import-objc-header App/CarrierSelector-Bridging-Header.h build/tests/telephony-probe.o \
  Core/*.swift App/LibraryStore.swift App/DirectTelephonyModel.swift \
  Tests/TestRunner.swift Tests/DiagnosticsTests.swift Tests/DirectTelephonyModelTests.swift Tests/WorkflowTests.swift Tests/ProfileToolsTests.swift -o build/tests/carrier-tests
fixture_file=$(mktemp "$PWD/build/tests/download-url.XXXXXX")
python3 Tests/download_fixture.py "$fixture_file" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; rm -f "$fixture_file"' EXIT
for attempt in {1..300}; do
  [[ -s "$fixture_file" ]] && break
  if ! kill -0 "$fixture_pid" 2>/dev/null; then
    echo 'Download fixture exited before publishing its address.' >&2
    exit 1
  fi
  sleep 0.1
done
if [[ ! -s "$fixture_file" ]]; then
  echo 'Download fixture did not start within 30 seconds.' >&2
  exit 1
fi
build/tests/carrier-tests "$PWD/Resources" "$PWD/build/tests" "$(cat "$fixture_file")"
