#!/bin/bash
set -euo pipefail
capture_scripts="$(cd -- "$(dirname -- "$0")" && pwd)"
capture_tools="$capture_scripts/native-screenshots"
capture_root="${TEGNAL_CAPTURE_ASSETS:-$capture_scripts/../user_data/marketing/generated}"
capture_python="${MARKETING_PYTHON:-python3}"
if ! "$capture_python" -c 'import PIL' >/dev/null 2>&1; then
  capture_python="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
  "$capture_python" -c 'import PIL' >/dev/null 2>&1 || { echo 'Set MARKETING_PYTHON to a Python with Pillow.' >&2; exit 2; }
fi
capture_kind="${1:-all}"
if [ "$capture_kind" = all ] && [ -n "${2:-}" ]; then
  echo 'Specify a single device kind when overriding its simulator UDID.' >&2; exit 2
fi
case "$capture_kind" in
  all) capture_kinds=(iphone ipad-13 iphone-duo) ;;
  iphone|ipad-13|iphone-duo) capture_kinds=("$capture_kind") ;;
  *) echo 'Usage: ./run_capture.sh [all|iphone|ipad-13|iphone-duo] [existing simulator UDID]' >&2; exit 2 ;;
esac
"$capture_python" "$capture_tools/prepare.py" --assets-root "$capture_root"
capture_stage="$("$capture_python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["fixture_project"])' "$capture_root/capture-profile.json")"
capture_run="$(cat "$capture_root/current-capture-run.txt")"
capture_build="$capture_run/DerivedData"
# The same arm64 simulator products run on all three existing simulator sizes.
xcodebuild -project "$capture_stage/TEGNAL.xcodeproj" -scheme MarketingCapture \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$capture_build" -parallel-testing-enabled NO -enableCodeCoverage NO \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing > "$capture_run/build-for-testing.log" 2>&1
for capture_kind in "${capture_kinds[@]}"; do
  capture_device="${2:-}"
  if [ -z "$capture_device" ]; then
    capture_device="$("$capture_python" - "$capture_root/capture-profile.json" "$capture_kind" <<'ENDPY'
import json,subprocess,sys
profile=json.load(open(sys.argv[1]));udid=profile['capture_devices'][sys.argv[2]]
items=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))
assert any(d['udid']==udid and d['isAvailable'] for group in items['devices'].values() for d in group),'Existing capture simulator missing; no devices are created.'
print(udid)
ENDPY
)"
  fi
  xcodebuild -project "$capture_stage/TEGNAL.xcodeproj" -scheme MarketingCapture \
    -configuration Debug -destination "platform=iOS Simulator,id=$capture_device" \
    -derivedDataPath "$capture_build" -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 -enableCodeCoverage NO -collect-test-diagnostics never \
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building \
    -only-testing:TEGNALUITests/MarketingScreenshotsTests/testScreenshots \
    -resultBundlePath "$capture_run/$capture_kind-Capture.xcresult" > "$capture_run/$capture_kind-test.log" 2>&1
  "$capture_python" "$capture_tools/export.py" "$capture_run/$capture_kind-Capture.xcresult" --device "$capture_kind" --assets-root "$capture_root"
done
