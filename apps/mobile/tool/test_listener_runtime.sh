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
  # iOS simulator launch can hang after Xcode says "build done".
  # Bound the actual test process and report a diagnostic rather than
  # consuming the entire macOS runner allocation without useful logs.
  set +e
  python3 - "$device" "${live_args[@]}" <<'PY'
import os
import signal
import subprocess
import sys

device, *extra = sys.argv[1:]
command = [
    'flutter', 'test', '-d', device,
    'integration_test/listener_runtime_test.dart',
    '--reporter', 'expanded', *extra,
]
print('QA_IOS_SIMULATOR_START ' + device, flush=True)
proc = subprocess.Popen(command, start_new_session=True)
try:
    code = proc.wait(timeout=14 * 60)
except subprocess.TimeoutExpired:
    print('QA_IOS_SIMULATOR_TIMEOUT: flutter test did not finish in 14 minutes',
          flush=True)
    os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    sys.exit(124)
sys.exit(code)
PY
  result=$?
  set -e
  if (( result != 0 )); then
    echo "QA_IOS_SIMULATOR_FAILED with exit code $result"
    xcrun simctl list devices booted || true
  fi
  exit "$result"
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
# A hosted Android emulator occasionally fails to attach the Flutter Dart
# Development Service after the APK has built and installed. Retry only that
# infrastructure startup condition once; never retry/obscure app test failures.
run_android_once() {
  : > "$log"
  flutter test -d "$device" integration_test/listener_runtime_test.dart --reporter expanded "${live_args[@]}" --dart-define=QA_ANDROID_MEDIA_KEYS=true >"$log" 2>&1 &
  test_pid=$!
  if wait_for_marker QA_ANDROID_MEDIA_KEYS_READY; then
    adb -s "$device" shell input keyevent KEYCODE_HOME
    sleep 1
    adb -s "$device" shell dumpsys media_session | grep -F 'com.breezze.breezze'
    adb -s "$device" shell cmd media_session dispatch pause
    sleep 1
    adb -s "$device" shell am start -n com.breezze.breezze/.MainActivity
    if wait_for_marker QA_ANDROID_OS_PAUSED; then
      adb -s "$device" shell cmd media_session dispatch play
    fi
  fi
  local status=0
  wait "$test_pid" || status=$?
  cat "$log"
  if (( status != 0 )) && grep -q 'Failed to start Dart Development Service' "$log"; then
    return 75
  fi
  return "$status"
}
result=0
run_android_once || result=$?
if (( result == 75 )); then
  echo "QA_ANDROID_DDS_STARTUP_RETRY: emulator was running but Flutter's debug service failed to attach."
  adb -s "$device" wait-for-device
  sleep 5
  result=0
  run_android_once || result=$?
fi
rm -f "$log"
exit "$result"
