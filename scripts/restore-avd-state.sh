#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_REPO="git@github.com:minejiarong/endfield-cloud-state.git"
readonly KEY_FILE="${RUNNER_TEMP}/endfield-state-deploy-key-restore"
readonly CHECKOUT_DIR="${RUNNER_TEMP}/endfield-cloud-state-restore"
readonly ENCRYPTED="${RUNNER_TEMP}/avd-state.tar.zst.enc"

if [[ -z "${STATE_REPO_SSH_KEY:-}" || -z "${STATE_ENCRYPTION_PASSWORD:-}" ]]; then
  echo "State repository secrets are not configured" >&2
  exit 50
fi

echo "Downloading encrypted Android state..."
install -m 600 /dev/null "$KEY_FILE"
printf '%s\n' "$STATE_REPO_SSH_KEY" > "$KEY_FILE"
install -d -m 700 "$HOME/.ssh"
ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o IdentitiesOnly=yes"
git clone --quiet --depth 1 "$STATE_REPO" "$CHECKOUT_DIR"

mapfile -t parts < <(find "$CHECKOUT_DIR" -maxdepth 1 -name 'avd-state.part-*' -type f | sort)
if (( ${#parts[@]} == 0 )); then
  echo "No encrypted Android state parts were found" >&2
  exit 51
fi

cat "${parts[@]}" > "$ENCRYPTED"
(
  cd "${RUNNER_TEMP}"
  sha256sum --check "$CHECKOUT_DIR/avd-state.sha256"
)

echo "Decrypting and restoring Android virtual device..."
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -pass env:STATE_ENCRYPTION_PASSWORD -in "$ENCRYPTED" \
  | tar --zstd -xf - -C "$HOME"

test -f "$HOME/.android/avd/test.ini"
test -d "$HOME/.android/avd/test.avd"
rm -f "$KEY_FILE" "$ENCRYPTED"
echo "Android state restored."
