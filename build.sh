#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Keep products outside Desktop/iCloud: File Provider metadata breaks codesigning.
flight_build_dir="${FLIGHT_NOTCH_BUILD_DIR:-$HOME/Library/Caches/FlightNotch/DerivedData}"
xcodebuild -project FlightNotch.xcodeproj -scheme FlightNotch \
  -configuration Release -derivedDataPath "$flight_build_dir" build "$@"
codesign --display --entitlements - --xml "$flight_build_dir/Build/Products/Release/Flight Notch.app" 2>/dev/null | \
  /usr/bin/python3 -c 'import plistlib, sys; assert plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.personal-information.location") is True, "Signed app is missing the location entitlement"'
printf '\nBuilt: %s\n' "$flight_build_dir/Build/Products/Release/Flight Notch.app"
