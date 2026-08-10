#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_REPO="git@github.com:minejiarong/endfield-cloud-state.git"
readonly KEY_FILE="${RUNNER_TEMP}/endfield-state-deploy-key-save"
readonly CHECKOUT_DIR="${RUNNER_TEMP}/endfield-cloud-state-save"
readonly ARCHIVE="${RUNNER_TEMP}/avd-state.tar.zst"
readonly ENCRYPTED="${RUNNER_TEMP}/avd-state.tar.zst.enc"

if [[ -z "${STATE_REPO_SSH_KEY:-}" || -z "${STATE_ENCRYPTION_PASSWORD:-}" ]]; then
  echo "State repository secrets are not configured" >&2
  exit 50
fi

echo "Packaging Android virtual device state..."
tar --zstd -cf "$ARCHIVE" -C "$HOME" .android/avd
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
  -pass env:STATE_ENCRYPTION_PASSWORD -in "$ARCHIVE" -out "$ENCRYPTED"

install -m 600 /dev/null "$KEY_FILE"
printf '%s\n' "$STATE_REPO_SSH_KEY" > "$KEY_FILE"
mkdir -p "$HOME/.ssh"
ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o IdentitiesOnly=yes"
git clone --quiet "$STATE_REPO" "$CHECKOUT_DIR"
git -C "$CHECKOUT_DIR" config user.name "endfield-actions[bot]"
git -C "$CHECKOUT_DIR" config user.email "actions@users.noreply.github.com"

find "$CHECKOUT_DIR" -maxdepth 1 -name 'avd-state.part-*' -type f -delete
split -b 90M -d -a 3 "$ENCRYPTED" "$CHECKOUT_DIR/avd-state.part-"
sha256sum "$ENCRYPTED" | sed 's#  .*#  avd-state.tar.zst.enc#' > "$CHECKOUT_DIR/avd-state.sha256"
cat > "$CHECKOUT_DIR/STATUS.md" <<EOF
# Cloud Endfield login

Status: **encrypted Android state saved**

Workflow: https://github.com/minejiarong/endfield-cloud-actions/actions/runs/${GITHUB_RUN_ID}

Saved: $(date -u +%FT%TZ)
EOF

git -C "$CHECKOUT_DIR" add -A
git -C "$CHECKOUT_DIR" commit --quiet -m "save encrypted Android login state"
git -C "$CHECKOUT_DIR" push --quiet
echo "Encrypted Android state saved."
