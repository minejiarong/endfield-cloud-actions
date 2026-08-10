#!/usr/bin/env bash
set -Eeuo pipefail

readonly MAA_VERSION="2.23.0"
readonly MAA_ARCHIVE="${RUNNER_TEMP}/MaaEnd-linux-x86_64-v${MAA_VERSION}.tar.gz"
readonly MAA_DIR="${RUNNER_TEMP}/maaend"
readonly MAA_URL="https://github.com/MaaEnd/MaaEnd/releases/download/v${MAA_VERSION}/MaaEnd-linux-x86_64-v${MAA_VERSION}.tar.gz"
readonly OUT_DIR="${GITHUB_WORKSPACE}/artifacts/maaend"

mkdir -p "$MAA_DIR" "$OUT_DIR"

echo "== Download MaaEnd v${MAA_VERSION} =="
curl --fail --location --show-error --silent \
  --retry 5 --retry-all-errors --connect-timeout 30 --max-time 900 \
  --output "$MAA_ARCHIVE" "$MAA_URL"
tar -xzf "$MAA_ARCHIVE" -C "$MAA_DIR"

# MaaPiCli resolves interface.json relative to the MaaFramework libraries.
# The MaaEnd release keeps those in maafw/ for its GUI, so flatten only the
# runtime files into the temporary package root for headless CLI execution.
cp -a "$MAA_DIR/maafw/." "$MAA_DIR/"
cp "$GITHUB_WORKSPACE/scripts/maaend-cli-interface.json" "$MAA_DIR/interface.json"
chmod +x "$MAA_DIR/MaaPiCli" "$MAA_DIR/agent/go-service" "$MAA_DIR/agent/cpp-algo"

adb_serial="${ANDROID_SERIAL:-emulator-5554}"
real_adb_path="$(command -v adb)"
adb -s "$adb_serial" get-state | grep -qx device

# MaaFramework 2.23 identifies Google AVDs from ro.product.model and enables
# AVDExtras. That fast path reads the Pixel profile's underlying 1080x2340
# portrait framebuffer, bypassing our logical 1280x720 display override. Give
# Maa a private adb wrapper that only masks that probe; every real operation is
# forwarded unchanged, which makes the ordinary lossless screencap methods use
# the correct landscape display.
adb_path="$MAA_DIR/adb"
cat > "$adb_path" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"shell getprop ro.product.model"* ]]; then
  echo "Endfield CI Android"
  exit 0
fi
exec "$real_adb_path" "\$@"
EOF
chmod +x "$adb_path"

mkdir -p "$MAA_DIR/config"
cat > "$MAA_DIR/config/maa_pi_config.json" <<EOF
{
  "adb": {
    "adb_path": "$adb_path",
    "address": "$adb_serial",
    "name": "${adb_serial}-${adb_path}"
  },
  "controller": {
    "name": "CloudADB"
  },
  "controller_option": [],
  "gamepad": {
    "_placeholder": 0,
    "gamepad_type": ""
  },
  "global_option": [],
  "lnx": {
    "input": "",
    "pw_screen_height": 0,
    "pw_screen_width": 0,
    "screencap": "",
    "use_win32_vk_code": false,
    "wlr_socket_path": ""
  },
  "macos": {
    "input": "",
    "screencap": "",
    "title": "",
    "window_id": 0
  },
  "playcover": {
    "address": "",
    "uuid": ""
  },
  "resource": "CN",
  "resource_option": [],
  "task": [
    {
      "name": "VisitFriends",
      "option": [
        {
          "inputs": {},
          "name": "VisitFriendsRemark",
          "value": "No",
          "values": []
        },
        {
          "inputs": {},
          "name": "ProductionAssistControl",
          "value": "",
          "values": [
            "ProductionAssistControlNexus",
            "ProductionAssistMFGCabin",
            "ProductionAssistGrowthChamber"
          ]
        }
      ]
    }
  ],
  "win32": {
    "_placeholder": 0
  }
}
EOF

cat > "$MAA_DIR/config/maa_option.json" <<'EOF'
{
  "draw_quality": 85,
  "logging": true,
  "save_draw": true,
  "save_on_error": true,
  "stdout_level": 2
}
EOF

watch_runtime_prompts() {
  local ui_xml="$MAA_DIR/runtime-window.xml"
  local maafw_log="$MAA_DIR/debug/maafw.log"
  local first_visit_tutorial_handled=false

  while true; do
    # Unity does not expose the first-visit tutorial through uiautomator. Maa's
    # own log gives us a reliable transition: after leaving the visitor
    # terminal, the friend's ship is shown and the one-time overlay appears.
    if [[ "$first_visit_tutorial_handled" == "false" ]] \
      && [[ -f "$maafw_log" ]] \
      && grep -Fq '"name":"VisitFriendsMenuTerminalExitToWorldShip","success":true' "$maafw_log"; then
      first_visit_tutorial_handled=true
      sleep 6
      echo "Runtime prompt watcher: dismissing first-visit ship tutorial"
      adb -s "$adb_serial" shell input tap 640 610 >/dev/null
    fi

    if adb -s "$adb_serial" shell uiautomator dump --compressed /sdcard/maa-runtime-window.xml >/dev/null 2>&1 \
      && adb -s "$adb_serial" pull /sdcard/maa-runtime-window.xml "$ui_xml" >/dev/null 2>&1; then
      if grep -Eq '点击任意处继续|点击任意位置继续' "$ui_xml"; then
        echo "Runtime prompt watcher: dismissing first-visit tutorial"
        adb -s "$adb_serial" shell input tap 640 610 >/dev/null
      elif grep -Eq '测速失败，请稍后再试\(6116\)|text="知道了"' "$ui_xml"; then
        echo "Runtime prompt watcher: dismissing speed-test prompt"
        adb -s "$adb_serial" shell input tap 640 420 >/dev/null
      fi
    fi
    sleep 3
  done
}

echo "== Run MaaEnd VisitFriends =="
watch_runtime_prompts > "$OUT_DIR/prompt-watcher.log" 2>&1 &
prompt_watcher_pid=$!
set +e
(
  cd "$MAA_DIR"
  timeout 1200 env \
    TERM=dumb \
    PATH="$MAA_DIR:$PATH" \
    LD_LIBRARY_PATH="$MAA_DIR" \
    ./MaaPiCli -d
) 2>&1 | tee "$OUT_DIR/console.log"
maa_status=${PIPESTATUS[0]}
set -e
kill "$prompt_watcher_pid" >/dev/null 2>&1 || true
wait "$prompt_watcher_pid" 2>/dev/null || true

if [[ -d "$MAA_DIR/debug" ]]; then
  cp -a "$MAA_DIR/debug/." "$OUT_DIR/"
fi
adb -s "$adb_serial" exec-out screencap -p > "$OUT_DIR/final.png" 2>/dev/null || true
echo "$maa_status" > "$OUT_DIR/exit-code.txt"

if (( maa_status != 0 )); then
  echo "MaaEnd VisitFriends failed with exit code $maa_status" >&2
  exit "$maa_status"
fi

if grep -Eiq \
  'signal [0-9]+ received|Failed to create control unit|Failed to connect controller|Parse config failed|### Failed to run tasks ###' \
  "$OUT_DIR/console.log"; then
  echo "MaaEnd reported a controller crash or task failure despite exit code 0." >&2
  exit 1
fi

if ! grep -Fq '### All tasks have been completed ###' "$OUT_DIR/console.log"; then
  echo "MaaEnd exited without confirming task completion." >&2
  exit 1
fi

if grep -Eq 'Tasker\.Task\.Failed|task end: .*\[ret=false\]' "$OUT_DIR/maafw.log"; then
  echo "MaaEnd's framework log reports a failed task." >&2
  exit 1
fi

if ! grep -Eq 'task end: .*VisitFriends.*\[ret=true\]' "$OUT_DIR/maafw.log"; then
  echo "MaaEnd did not record a successful VisitFriends task." >&2
  exit 1
fi

echo "MaaEnd VisitFriends finished."
