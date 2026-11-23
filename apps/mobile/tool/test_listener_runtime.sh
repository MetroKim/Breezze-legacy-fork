#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
device=${1:?pass the emulator or simulator ID}
# Keep the generated test audio/video out of the shipping bundle.
saved_manifest=$(mktemp)
cp pubspec.yaml "$saved_manifest"
trap 'cp "$saved_manifest" pubspec.yaml; rm -f "$saved_manifest"' EXIT
sed '/^  assets:/a\
    - integration_test/fixtures/
' "$saved_manifest" > pubspec.yaml
flutter pub get
dart run build_runner build --delete-conflicting-outputs
# Exercise the handoff race policy on both hosted platforms before launching native tests.
flutter test test/features/video/video_handoff_policy_test.dart --reporter expanded
live_args=()
if [[ -n "${QA_PREVIEW_API_ORIGIN:-}" ]]; then
  live_args+=(--dart-define=QA_LIVE_PREVIEW=true "--dart-define=BREEZZE_API_URL=$QA_PREVIEW_API_ORIGIN")
fi
if [[ "$device" != emulator-* ]]; then
  flutter test -d "$device" integration_test/listener_runtime_test.dart --reporter expanded "${live_args[@]}"
  exit
fi

log=$(mktemp)
wait_for_marker() {
  for ((i=0; i<900; i++)); do
    if grep -q "$1" "$log"; then return; fi
    if ! kill -0 "$test_pid" 2>/dev/null; then return 1; fi
    sleep 1
  done
  return 1
}
flutter test -d "$device" integration_test/listener_runtime_test.dart --reporter expanded "${live_args[@]}" --dart-define=QA_ANDROID_MEDIA_KEYS=true >"$log" 2>&1 &
test_pid=$!
if wait_for_marker QA_ANDROID_MEDIA_KEYS_READY; then
  adb -s "$device" shell input keyevent KEYCODE_HOME
  sleep 1
  adb -s "$device" shell dumpsys media_session | grep -F 'com.breezze.breezze'
  adb -s "$device" shell cmd media_session dispatch pause
  sleep 1
  adb -s "$device" shell am start -n com.breezze.breezze/.MainActivity
  if wait_for_marker QA_ANDROID_OS_PAUSED; then adb -s "$device" shell cmd media_session dispatch play; fi
fi
result=0
wait "$test_pid" || result=$?
cat "$log"
exit "$result"
