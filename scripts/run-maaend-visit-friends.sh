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
adb_path="$(command -v adb)"
adb -s "$adb_serial" get-state | grep -qx device

mkdir -p "$MAA_DIR/config"
cat > "$MAA_DIR/config/maa_pi_config.json" <<EOF
{
  "adb": {
    "adb_path": "$adb_path",
    "address": "$adb_serial",
    "name": "GitHub Actions Android emulator"
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

echo "== Run MaaEnd VisitFriends =="
set +e
(
  cd "$MAA_DIR"
  printf '6\n7\n' | timeout 1200 env LD_LIBRARY_PATH="$MAA_DIR" ./MaaPiCli
) 2>&1 | tee "$OUT_DIR/console.log"
maa_status=${PIPESTATUS[0]}
set -e

if [[ -d "$MAA_DIR/debug" ]]; then
  cp -a "$MAA_DIR/debug/." "$OUT_DIR/"
fi
adb -s "$adb_serial" exec-out screencap -p > "$OUT_DIR/final.png" 2>/dev/null || true
echo "$maa_status" > "$OUT_DIR/exit-code.txt"

if (( maa_status != 0 )); then
  echo "MaaEnd VisitFriends failed with exit code $maa_status" >&2
  exit "$maa_status"
fi

echo "MaaEnd VisitFriends finished."
