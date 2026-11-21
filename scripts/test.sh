#!/usr/bin/env bash
# Reproducible test entry point.
#
#   scripts/test.sh core   # RideCore package tests (works with Command Line Tools only)
#   scripts/test.sh app    # iOS app tests on a simulator (needs full Xcode)
#   scripts/test.sh smoke  # one short simulator flow; separates runner failures from app failures
#   scripts/test.sh all
#
# Env for `app`: SIMULATOR_UDID (default: first available iPhone simulator),
#                RESULT_BUNDLE (default: fresh path under the evidence root).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="${EVIDENCE_DIR:-$ROOT/.omo/evidence/n250-ios-navigation}"
CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIBS=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

# Prefer an installed, licence-accepted Xcode without needing `sudo xcode-select`.
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]] \
  && DEVELOPER_DIR="$XCODE_DEV" xcodebuild -showsdks > /dev/null 2>&1; then
  export DEVELOPER_DIR="$XCODE_DEV"
fi

has_xcode() {
  xcodebuild -showsdks > /dev/null 2>&1
}

core() {
  if has_xcode; then
    swift test --package-path "$ROOT/Packages/RideCore"
  else
    # Command Line Tools ship Swift Testing but SwiftPM does not find it on its own,
    # and the default build system cannot initialise without Xcode.
    swift test --package-path "$ROOT/Packages/RideCore" --build-system native \
      -Xswiftc -F"$CLT_FRAMEWORKS" -Xlinker -F"$CLT_FRAMEWORKS" \
      -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" -Xlinker -rpath -Xlinker "$CLT_LIBS"
  fi
}

app() {
  if ! has_xcode; then
    echo "BLOCKED: full Xcode is not installed/selected (xcode-select -p: $(xcode-select -p))." >&2
    echo "Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 2
  fi
  command -v xcodegen > /dev/null || { echo "BLOCKED: xcodegen missing (brew install xcodegen)" >&2; exit 2; }
  (cd "$ROOT" && xcodegen generate --quiet)
  local udid="${SIMULATOR_UDID:-$(xcrun simctl list devices available -j \
    | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for r in d for x in d[r] if x["name"].startswith("iPhone")))')}"
  local bundle="${RESULT_BUNDLE:-$EVIDENCE/app-tests-$(date +%Y%m%d-%H%M%S).xcresult}"
  # A granted location permission makes the map's live position dot animate
  # nonstop, and XCUITest then waits ~60 s for the app to go idle before every tap.
  xcrun simctl privacy "$udid" reset location > /dev/null 2>&1 || true
  echo "simulator: $udid"
  echo "result bundle: $bundle"
  xcodebuild test -project "$ROOT/ClusterNav.xcodeproj" -scheme ClusterNav \
    -destination "platform=iOS Simulator,id=$udid" -resultBundlePath "$bundle"
}

# One short simulator flow on its own. Exit 0: passed. Exit 1: the app failed an
# assertion. Exit 3: the test runner never reached the test (a runner problem, not
# evidence about the app); retried once before it is reported.
smoke() {
  if ! has_xcode; then
    echo "BLOCKED: full Xcode is not installed/selected (xcode-select -p: $(xcode-select -p))." >&2
    exit 2
  fi
  command -v xcodegen > /dev/null || { echo "BLOCKED: xcodegen missing (brew install xcodegen)" >&2; exit 2; }
  (cd "$ROOT" && xcodegen generate --quiet)
  local udid="${SIMULATOR_UDID:-$(xcrun simctl list devices available -j \
    | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for r in d for x in d[r] if x["name"].startswith("iPhone")))')}"
  xcrun simctl privacy "$udid" reset location > /dev/null 2>&1 || true
  local log attempt
  log="$(mktemp -t clusternav-smoke)"
  for attempt in 1 2; do
    if xcodebuild test -project "$ROOT/ClusterNav.xcodeproj" -scheme ClusterNav \
      -destination "platform=iOS Simulator,id=$udid" -parallel-testing-enabled NO \
      -only-testing:ClusterNavUITests/SmokeUITests > "$log" 2>&1; then
      echo "SMOKE PASSED"
      rm -f "$log"
      return 0
    fi
    if grep -q "BUILD FAILED\|\.swift:[0-9]*:[0-9]*: error:" "$log"; then
      echo "SMOKE FAILED: the app did not build" >&2
      grep -E "\.swift:[0-9]+:[0-9]+: error:" "$log" | head -5 >&2 || true
      echo "log: $log" >&2
      return 1
    fi
    if grep -q "Test Case '.*SmokeUITests.*' failed" "$log" && ! grep -q "is not running\|Lost connection\|Unable to monitor" "$log"; then
      echo "SMOKE FAILED: the app failed an assertion" >&2
      grep -E "SmokeUITests.swift:[0-9]+: error" "$log" >&2 || true
      echo "log: $log" >&2
      return 1
    fi
    echo "smoke attempt $attempt: the test runner did not complete the flow; retrying" >&2
  done
  echo "SMOKE INCONCLUSIVE: the test runner never completed the flow (not an app assertion)" >&2
  grep -E "error:|Testing failed|BUILD FAILED" "$log" | head -5 >&2 || true
  echo "log: $log" >&2
  return 3
}

case "${1:-core}" in
  core) core ;;
  app) app ;;
  smoke) smoke ;;
  all) core && app ;;
  *) echo "usage: $0 [core|app|smoke|all]" >&2; exit 64 ;;
esac
