#!/usr/bin/env bash
set -Eeuo pipefail

readonly APK_URL="https://launcher.hypergryph.com/game/latest/EjOB8xSdBmtLnzCX/1/1"
readonly EXPECTED_PACKAGE="com.hypergryph.cloud.endfield"
readonly EXPECTED_ACTIVITY="com.hypergryph.cloud.endfield.splash.SplashActivity"
readonly OUT_DIR="${GITHUB_WORKSPACE:-$(pwd)}/artifacts"
readonly APK_PATH="${RUNNER_TEMP:-/tmp}/EndfieldCloud.apk"

mkdir -p "$OUT_DIR"

collect_diagnostics() {
  local exit_code=$?
  set +e

  {
    echo "exit_code=$exit_code"
    echo "collected_at=$(date -u +%FT%TZ)"
    echo "package=$EXPECTED_PACKAGE"
    echo "pid=$(adb shell pidof "$EXPECTED_PACKAGE" 2>/dev/null | tr -d '\r')"
  } > "$OUT_DIR/result.txt"

  adb devices -l > "$OUT_DIR/adb-devices.txt" 2>&1
  adb shell getprop > "$OUT_DIR/getprop.txt" 2>&1
  adb shell pm list packages -f > "$OUT_DIR/packages.txt" 2>&1
  adb shell dumpsys package "$EXPECTED_PACKAGE" > "$OUT_DIR/package.txt" 2>&1
  adb shell dumpsys activity activities > "$OUT_DIR/activities.txt" 2>&1
  adb shell dumpsys window windows > "$OUT_DIR/windows.txt" 2>&1
  adb shell dumpsys media.codec > "$OUT_DIR/media-codec.txt" 2>&1
  adb logcat -d -v threadtime > "$OUT_DIR/logcat.txt" 2>&1
  adb exec-out screencap -p > "$OUT_DIR/screenshot.png" 2>/dev/null

  if [[ ! -s "$OUT_DIR/screenshot.png" ]]; then
    rm -f "$OUT_DIR/screenshot.png"
  fi

  exit "$exit_code"
}
trap collect_diagnostics EXIT

echo "== Android device =="
adb wait-for-device
adb shell getprop ro.build.version.release
adb shell getprop ro.build.version.sdk
adb shell getprop ro.product.cpu.abilist
adb shell getprop ro.hardware

echo "== Download official latest Cloud Endfield APK =="
curl --fail --location --show-error --silent \
  --retry 5 --retry-all-errors --connect-timeout 30 --max-time 600 \
  --output "$APK_PATH" "$APK_URL"

file "$APK_PATH"
sha256sum "$APK_PATH" | tee "$OUT_DIR/apk-sha256.txt"
stat --format='size=%s bytes' "$APK_PATH" | tee "$OUT_DIR/apk-size.txt"
unzip -Z1 "$APK_PATH" \
  | awk -F/ '/^lib\/[^/]+\// {print $2}' \
  | sort -u \
  | tee "$OUT_DIR/apk-abis.txt"

if ! unzip -tq "$APK_PATH" > "$OUT_DIR/apk-integrity.txt" 2>&1; then
  echo "Downloaded file is not a valid APK/ZIP archive" >&2
  exit 10
fi

echo "== Install APK =="
adb logcat -c
adb install -r -g -t "$APK_PATH" 2>&1 | tee "$OUT_DIR/install.txt"

installed_path="$(adb shell pm path "$EXPECTED_PACKAGE" | tr -d '\r')"
if [[ "$installed_path" != package:* ]]; then
  echo "Expected package was not installed: $EXPECTED_PACKAGE" >&2
  exit 20
fi

echo "== Launch Cloud Endfield =="
adb shell am force-stop "$EXPECTED_PACKAGE"
adb shell am start -W -n "$EXPECTED_PACKAGE/$EXPECTED_ACTIVITY" \
  2>&1 | tee "$OUT_DIR/launch.txt"

capture_onboarding_stage() {
  local stage="$1"
  local stage_dir="$OUT_DIR/onboarding"
  mkdir -p "$stage_dir"
  adb shell uiautomator dump --compressed /sdcard/window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/window.xml "$stage_dir/${stage}.xml" >/dev/null 2>&1 || true
  adb exec-out screencap -p > "$stage_dir/${stage}.png" 2>/dev/null || true
}

tap_known_onboarding_button() {
  local xml_path="$1"
  python3 - "$xml_path" <<'PY'
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
targets = (
    "Got it",
    "同意并继续",
    "我知道了",
    "立即体验",
    "开始游戏",
    "进入游戏",
    "立即登录",
    "登录",
)

try:
    root = ET.parse(path).getroot()
except (FileNotFoundError, ET.ParseError):
    raise SystemExit(1)

for target in targets:
    for node in root.iter("node"):
        label = (node.get("text") or node.get("content-desc") or "").strip()
        if label != target:
            continue
        match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if not match:
            continue
        left, top, right, bottom = map(int, match.groups())
        subprocess.run(
            ["adb", "shell", "input", "tap", str((left + right) // 2), str((top + bottom) // 2)],
            check=True,
        )
        print(f"Tapped onboarding button: {label}")
        raise SystemExit(0)

raise SystemExit(1)
PY
}

if [[ "${ADVANCE_ONBOARDING:-false}" == "true" ]]; then
  echo "== Advance known onboarding screens =="
  sleep 5
  for stage in 00 01 02 03 04 05; do
    capture_onboarding_stage "$stage"
    if ! tap_known_onboarding_button "$OUT_DIR/onboarding/${stage}.xml"; then
      echo "No known onboarding button found at stage $stage"
      break
    fi
    sleep 5
  done
fi

# A successful am start only proves that Android accepted the Intent. Give the
# application enough time to initialize native libraries and its network stack.
sleep 45

pid="$(adb shell pidof "$EXPECTED_PACKAGE" | tr -d '\r')"
if [[ -z "$pid" ]]; then
  echo "Cloud Endfield exited during startup" >&2
  exit 30
fi

resumed="$(adb shell dumpsys activity activities \
  | grep -E 'mResumedActivity|topResumedActivity' \
  | grep "$EXPECTED_PACKAGE" || true)"

if [[ -z "$resumed" ]]; then
  echo "Cloud Endfield has a process but no resumed foreground activity" >&2
  exit 31
fi

echo "pid=$pid" | tee "$OUT_DIR/success.txt"
echo "resumed_activity=$resumed" | tee -a "$OUT_DIR/success.txt"
echo "Cloud Endfield stayed alive after launch. Smoke test passed."
