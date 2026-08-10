#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCREEN_DIR="$1"
readonly STATE_REPO="git@github.com:minejiarong/endfield-cloud-state.git"
readonly KEY_FILE="${RUNNER_TEMP}/endfield-state-deploy-key"
readonly CHECKOUT_DIR="${RUNNER_TEMP}/endfield-cloud-state"

if [[ -z "${STATE_REPO_SSH_KEY:-}" ]]; then
  echo "STATE_REPO_SSH_KEY is not configured" >&2
  exit 40
fi

install -m 600 /dev/null "$KEY_FILE"
printf '%s\n' "$STATE_REPO_SSH_KEY" > "$KEY_FILE"
mkdir -p "$HOME/.ssh"
ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o IdentitiesOnly=yes"

git clone --quiet "$STATE_REPO" "$CHECKOUT_DIR"
git -C "$CHECKOUT_DIR" config user.name "endfield-actions[bot]"
git -C "$CHECKOUT_DIR" config user.email "actions@users.noreply.github.com"

latest_qr="$(find "$SCREEN_DIR" -maxdepth 1 -name '*.png' -type f | sort | tail -n 1)"
if [[ -z "$latest_qr" ]]; then
  echo "QR screenshot was not captured" >&2
  exit 41
fi

publish_qr() {
  local source="$1"
  cp "$source" "$CHECKOUT_DIR/login-qr.png"
  cat > "$CHECKOUT_DIR/STATUS.md" <<EOF
# Cloud Endfield login

Status: **waiting for scan**

Workflow: https://github.com/minejiarong/endfield-cloud-actions/actions/runs/${GITHUB_RUN_ID}

Updated: $(date -u +%FT%TZ)
EOF
  git -C "$CHECKOUT_DIR" add login-qr.png STATUS.md
  if ! git -C "$CHECKOUT_DIR" diff --cached --quiet; then
    git -C "$CHECKOUT_DIR" commit --quiet -m "update live login QR"
    git -C "$CHECKOUT_DIR" push --quiet
  fi
}

publish_qr "$latest_qr"
echo "Live QR published to the private state repository. Waiting for login."

absent_count=0
for attempt in $(seq 1 120); do
  adb shell uiautomator dump --compressed /sdcard/login-window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/login-window.xml "${RUNNER_TEMP}/login-window.xml" >/dev/null 2>&1 || true

  if grep -q '支持App' "${RUNNER_TEMP}/login-window.xml" 2>/dev/null; then
    absent_count=0
  else
    absent_count=$((absent_count + 1))
  fi

  if (( absent_count >= 3 )); then
    cat > "$CHECKOUT_DIR/STATUS.md" <<EOF
# Cloud Endfield login

Status: **login detected; saving Android state**

Workflow: https://github.com/minejiarong/endfield-cloud-actions/actions/runs/${GITHUB_RUN_ID}

Updated: $(date -u +%FT%TZ)
EOF
    git -C "$CHECKOUT_DIR" add STATUS.md
    git -C "$CHECKOUT_DIR" commit --quiet -m "record successful login"
    git -C "$CHECKOUT_DIR" push --quiet
    echo "Login detected."
    exit 0
  fi

  if (( attempt % 6 == 0 )); then
    adb exec-out screencap -p > "${RUNNER_TEMP}/live-qr.png"
    publish_qr "${RUNNER_TEMP}/live-qr.png"
  fi
  sleep 5
done

echo "Timed out waiting for QR login" >&2
exit 42

